/// When a cached contract list stops being trustworthy.
///
/// Pure functions with the clock passed in, so both sides of the boundary are
/// testable without waiting for a real 08:30 to come around.
library;

/// IST is UTC+05:30 and observes no daylight saving, so a fixed offset is
/// correct year-round. This is why the app needs no timezone database.
const Duration istOffset = Duration(hours: 5, minutes: 30);

/// Angel One republishes the instrument master daily at ~08:30 IST (§3.2).
const int _refreshHourIst = 8;
const int _refreshMinuteIst = 30;

/// Whether a cache written at [fetchedAt] should be refetched as of [now].
///
/// **The rule is a boundary crossing, not an age.** The cache is stale exactly
/// when a publication has happened since it was written — that is, when the
/// most recent 08:30 IST boundary at or before [now] falls after [fetchedAt].
///
/// "Older than 24 hours" would be wrong in both directions, which is why it is
/// not what this does:
///
/// - A cache written at 08:00 IST holds *yesterday's* file. It is stale at
///   08:31 the same morning, thirty-one minutes old.
/// - A cache written at 09:00 IST holds today's file. It is still good at
///   23:00 that night, fourteen hours old, and refetching 32.5 MB would buy
///   nothing.
///
/// Both timestamps may be in any zone; they are compared as instants.
bool isStale({required DateTime fetchedAt, required DateTime now}) =>
    fetchedAt.toUtc().isBefore(lastRefreshBoundary(now));

/// The most recent instrument-master publication at or before [now], as UTC.
DateTime lastRefreshBoundary(DateTime now) {
  final nowIst = now.toUtc().add(istOffset);
  var boundaryIst = DateTime.utc(
    nowIst.year,
    nowIst.month,
    nowIst.day,
    _refreshHourIst,
    _refreshMinuteIst,
  );
  // Before this morning's publication, the newest file is still yesterday's.
  if (boundaryIst.isAfter(nowIst)) {
    boundaryIst = boundaryIst.subtract(const Duration(days: 1));
  }
  return boundaryIst.subtract(istOffset);
}
