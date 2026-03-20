sealed class MusicAuthorizationStatus {}

class MusicAuthorizationStatusAuthorized extends MusicAuthorizationStatus {
  final String? musicUserToken;

  MusicAuthorizationStatusAuthorized(this.musicUserToken);
}

class MusicAuthorizationStatusDenied extends MusicAuthorizationStatus {}

class MusicAuthorizationStatusNotDetermined extends MusicAuthorizationStatus {}

class MusicAuthorizationStatusRestricted extends MusicAuthorizationStatus {}

class MusicAuthorizationStatusExpired extends MusicAuthorizationStatus {}
