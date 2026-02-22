import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lauschi/core/ard/ard_api.dart';
import 'package:lauschi/core/ard/ard_models.dart';

/// All kids shows (programSets in "Für Kinder" category).
final ardKidsShowsProvider = FutureProvider.autoDispose<List<ArdProgramSet>>(
  (ref) => ref.watch(ardApiProvider).getKidsShows(),
);

/// Single programSet by ID.
final ardShowDetailProvider = FutureProvider.autoDispose
    .family<ArdProgramSet?, String>(
      (ref, showId) => ref.watch(ardApiProvider).getProgramSet(showId),
    );

/// Episodes for a show (first page).
final ardShowEpisodesProvider = FutureProvider.autoDispose
    .family<ArdItemPage, String>(
      (ref, showId) => ref.watch(ardApiProvider).getItems(programSetId: showId),
    );
