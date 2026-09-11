import 'market_status.dart';

/// Where market data comes from right now.
///
/// Sealed so the banner and the repository both `switch` over the same closed
/// set, and adding a source later is a compile error at each site rather than
/// a screen that silently shows the wrong provenance.
sealed class FeedSource {
  const FeedSource();
}

/// The live Angel One socket.
final class LiveFeed extends FeedSource {
  const LiveFeed();
}

/// A recorded session, replayed with its original timing.
///
/// Carries [recordedAt] because the UI must say *when* the data is from. A
/// banner reading "replay" is ambiguous; one reading "recorded 11 Sep 13:55"
/// cannot be mistaken for live.
final class ReplayFeed extends FeedSource {
  const ReplayFeed({required this.recordedAt});

  final DateTime recordedAt;
}

/// The broker is not set up, during hours when it should be.
///
/// **Deliberately not a fallback to [ReplayFeed].** The distinction is the
/// whole point of this type: a closed market is an expected condition nobody
/// can fix, so replay is the right answer. Absent credentials are a *defect*,
/// and routing them to replay would hide a broken integration behind something
/// that looks like it works — the reviewer would never learn the live path was
/// misconfigured.
final class FeedUnavailable extends FeedSource {
  const FeedUnavailable({required this.missingKeys});

  /// Which `ANGEL_*` values are absent. Names only, never values.
  final List<String> missingKeys;
}

/// Decides the source from the clock and the configuration.
///
/// ```
/// market open   + credentials    -> live
/// market open   + no credentials -> unavailable (a setup error, not replay)
/// market closed                  -> replay
/// ```
///
/// Pure, so both the Saturday case and the misconfigured case are unit-tested
/// without a clock or a socket — and so "why am I seeing replay?" has exactly
/// one place to read the answer.
FeedSource resolveFeedSource({
  required MarketStatus status,
  required bool brokerConfigured,
  required List<String> missingKeys,
  required DateTime fixtureRecordedAt,
}) {
  if (status != MarketStatus.open) {
    // Nothing is streaming anywhere, so a recording is the most honest thing
    // that can be shown — provided it is labelled as one.
    return ReplayFeed(recordedAt: fixtureRecordedAt);
  }
  if (!brokerConfigured) {
    return FeedUnavailable(missingKeys: missingKeys);
  }
  return const LiveFeed();
}
