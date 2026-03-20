import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lauschi/core/apple_music/apple_music_api.dart';
import 'package:lauschi/core/apple_music/apple_music_config.dart';
import 'package:lauschi/core/log.dart';
import 'package:music_kit/music_kit.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'apple_music_session.g.dart';

const _tag = 'AppleMusicSession';

// ---------------------------------------------------------------------------
// Session state
// ---------------------------------------------------------------------------

sealed class AppleMusicState {}

class AppleMusicLoading extends AppleMusicState {}

class AppleMusicUnauthenticated extends AppleMusicState {}

class AppleMusicAuthenticated extends AppleMusicState {
  AppleMusicAuthenticated({this.canPlayCatalog = false});

  /// Whether the user has an active subscription that can play catalog content.
  final bool canPlayCatalog;
}

// ---------------------------------------------------------------------------
// AppleMusicSession provider
// ---------------------------------------------------------------------------

/// Central provider for everything Apple Music.
///
/// Owns auth state and the MusicKit instance. Same pattern as
/// SpotifySession: keepAlive, sealed state, single entry point for
/// connect/disconnect.
@Riverpod(keepAlive: true)
class AppleMusicSession extends _$AppleMusicSession {
  final MusicKit _musicKit = MusicKit();
  late final AppleMusicApi _api = AppleMusicApi(_musicKit);
  bool _sdkInitialized = false;
  static const _storage = FlutterSecureStorage();
  static const _userTokenKey = 'apple_music_user_token';

  @override
  AppleMusicState build() {
    unawaited(_init());
    return AppleMusicLoading();
  }

  // ---------------------------------------------------------------------------
  // Public accessors
  // ---------------------------------------------------------------------------

  MusicKit get musicKit => _musicKit;

  /// The Apple Music REST API client. Lifecycle managed by session.
  AppleMusicApi get api => _api;

  bool get isAuthenticated => state is AppleMusicAuthenticated;

  // ---------------------------------------------------------------------------
  // Init
  // ---------------------------------------------------------------------------

  Future<void> _init() async {
    try {
      await _initSdk();
      if (!_sdkInitialized) {
        Log.warn(_tag, 'SDK init failed silently, marking unauthenticated');
        state = AppleMusicUnauthenticated();
        return;
      }
      final status = await _musicKit.authorizationStatus;
      Log.info(
        _tag,
        'Auth check on init',
        data: {'status': status.runtimeType.toString()},
      );
      if (status is MusicAuthorizationStatusAuthorized) {
        await _initApi();
        state = AppleMusicAuthenticated(
          canPlayCatalog: await _checkSubscription(),
        );
      } else {
        state = AppleMusicUnauthenticated();
      }
    } on Exception catch (e) {
      Log.error(_tag, 'Init failed', exception: e);
      state = AppleMusicUnauthenticated();
    }
  }

  Future<void> _initSdk() async {
    if (_sdkInitialized) return;
    if (Platform.isAndroid) {
      const devToken = AppleMusicConfig.developerToken;
      if (devToken.isEmpty) {
        Log.warn(_tag, 'No developer token, Apple Music unavailable');
        return;
      }
      // Restore saved user token so auth persists across restarts.
      String? savedUserToken;
      try {
        savedUserToken = await _storage.read(key: _userTokenKey);
      } on Exception catch (e) {
        Log.warn(_tag, 'Could not read saved token', data: {'error': '$e'});
      }
      await _musicKit.initialize(
        devToken,
        musicUserToken: savedUserToken,
      );
      Log.info(
        _tag,
        'SDK initialized',
        data: {
          'platform': 'Android',
          'hasUserToken': '${savedUserToken != null}',
        },
      );
    } else {
      Log.info(_tag, 'SDK initialized', data: {'platform': 'iOS'});
    }
    _sdkInitialized = true;
  }

  // ---------------------------------------------------------------------------
  // Auth flow
  // ---------------------------------------------------------------------------

  /// Prompt the user to authorize Apple Music access.
  ///
  /// On Android, MusicKit may open the Play Store to install Apple Music
  /// if it's not present.
  Future<void> connect() async {
    state = AppleMusicLoading();
    try {
      await _initSdk();
      await _musicKit.requestAuthorizationStatus(
        startScreenMessage:
            'lauschi braucht Zugriff auf Apple Music, um '
            'Hörspiele abspielen zu können.',
      );

      // On Android, fetch and persist the user token.
      if (Platform.isAndroid) {
        const devToken = AppleMusicConfig.developerToken;
        final userToken = await _musicKit.requestUserToken(devToken);
        if (userToken.isNotEmpty) {
          try {
            await _storage.write(key: _userTokenKey, value: userToken);
            Log.info(_tag, 'User token saved');
          } on Exception catch (e) {
            Log.warn(_tag, 'Could not save token', data: {'error': '$e'});
          }
        }
      }
    } on Exception catch (e) {
      Log.warn(_tag, 'Auth flow error', data: {'error': '$e'});
      // Must exit Loading state so the UI can retry and recheckAuth
      // doesn't early-return.
      state = AppleMusicUnauthenticated();
      return;
    }

    // Check final auth state regardless of how we got here.
    await recheckAuth(fromConnect: true);
  }

  /// Initialize the API client so it's ready for catalog requests.
  /// Called eagerly after successful auth rather than lazily on first use,
  /// because MusicKit's requestUserToken may time out if called later.
  Future<void> _initApi() async {
    try {
      await _api.init();
    } on Exception catch (e) {
      Log.warn(
        _tag,
        'API init failed (will retry on use)',
        data: {'error': '$e'},
      );
    }
  }

  /// Clear local auth state.
  Future<void> disconnect() async {
    try {
      await _storage.delete(key: _userTokenKey);
    } on Exception catch (e) {
      Log.warn(_tag, 'Could not delete token', data: {'error': '$e'});
    }
    state = AppleMusicUnauthenticated();
    Log.info(_tag, 'Disconnected (token cleared)');
  }

  /// Re-check auth status. Called after connect() and on app resume.
  ///
  /// When [fromConnect] is true, the Loading guard is skipped because
  /// connect() itself set the Loading state and needs the recheck to
  /// transition out of it.
  Future<void> recheckAuth({bool fromConnect = false}) async {
    if (!fromConnect && state is AppleMusicLoading) {
      // Don't interrupt an in-progress connect(). It calls recheckAuth()
      // at the end when it completes.
      return;
    }
    try {
      final status = await _musicKit.authorizationStatus;
      final authorized = status is MusicAuthorizationStatusAuthorized;
      if (authorized) {
        await _initApi();
        state = AppleMusicAuthenticated(
          canPlayCatalog: await _checkSubscription(),
        );
        Log.info(_tag, 'Authorized');
      } else if (state is! AppleMusicUnauthenticated) {
        state = AppleMusicUnauthenticated();
      }
    } on Exception catch (e) {
      Log.warn(_tag, 'Auth recheck failed', data: {'error': '$e'});
    }
  }

  /// Cancel an in-progress connect attempt.
  void cancelConnect() {
    if (state is AppleMusicLoading) {
      state = AppleMusicUnauthenticated();
      Log.info(_tag, 'Connect cancelled by user');
    }
  }

  // ---------------------------------------------------------------------------
  // Subscription check
  // ---------------------------------------------------------------------------

  Future<bool> _checkSubscription() async {
    try {
      final sub = await _musicKit.onSubscriptionUpdated.first.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          Log.warn(_tag, 'Subscription check timed out');
          return const MusicSubscription();
        },
      );
      Log.info(
        _tag,
        'Subscription',
        data: {
          'canPlay': '${sub.canPlayCatalogContent}',
          'canBecome': '${sub.canBecomeSubscriber}',
        },
      );
      return sub.canPlayCatalogContent ?? false;
    } on Exception catch (e) {
      // MissingPluginException on Android: subscription stream not
      // implemented in the music_kit plugin. Assume authorized users
      // can play (they went through the auth flow).
      Log.warn(_tag, 'Subscription check unavailable', data: {'error': '$e'});
      return true;
    }
  }
}
