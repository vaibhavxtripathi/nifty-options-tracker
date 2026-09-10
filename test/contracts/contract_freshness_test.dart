import 'package:flutter_test/flutter_test.dart';
import 'package:nifty_options_tracker/data/contracts/contract_freshness.dart';

/// The cache invalidation rule: a boundary crossing, not an age.
///
/// The interesting cases are the two an "older than 24 hours" rule gets
/// backwards, so both are asserted explicitly.
void main() {
  /// Builds a UTC instant from an IST wall-clock time.
  DateTime ist(int year, int month, int day, int hour, int minute) =>
      DateTime.utc(year, month, day, hour, minute).subtract(istOffset);

  group('the 08:30 IST publication boundary', () {
    test('a cache written just after publication is fresh', () {
      expect(
        isStale(
          fetchedAt: ist(2026, 9, 10, 8, 31),
          now: ist(2026, 9, 10, 15, 0),
        ),
        isFalse,
      );
    });

    test('a cache written just before publication is stale after it', () {
      expect(
        isStale(
          fetchedAt: ist(2026, 9, 10, 8, 29),
          now: ist(2026, 9, 10, 8, 31),
        ),
        isTrue,
      );
    });

    test('exactly at the boundary counts as published', () {
      expect(
        isStale(
          fetchedAt: ist(2026, 9, 10, 8, 29),
          now: ist(2026, 9, 10, 8, 30),
        ),
        isTrue,
      );
    });
  });

  group('the cases an age-based rule gets wrong', () {
    test('a 31-minute-old cache written before 08:30 is stale', () {
      // Written at 08:00 it holds *yesterday's* file. "Older than 24 hours"
      // would call this fresh and serve stale contracts all day.
      expect(
        isStale(
          fetchedAt: ist(2026, 9, 10, 8, 0),
          now: ist(2026, 9, 10, 8, 31),
        ),
        isTrue,
      );
    });

    test('a 14-hour-old cache written after 08:30 is still fresh', () {
      // Written at 09:00 it holds today's file and stays correct until
      // tomorrow's publication. Refetching 32.5 MB at 23:00 would buy nothing.
      expect(
        isStale(
          fetchedAt: ist(2026, 9, 10, 9, 0),
          now: ist(2026, 9, 10, 23, 0),
        ),
        isFalse,
      );
    });

    test('but the same cache is stale the next morning', () {
      expect(
        isStale(
          fetchedAt: ist(2026, 9, 10, 9, 0),
          now: ist(2026, 9, 11, 8, 31),
        ),
        isTrue,
      );
    });

    test('and is still fresh before that next publication', () {
      expect(
        isStale(
          fetchedAt: ist(2026, 9, 10, 9, 0),
          now: ist(2026, 9, 11, 8, 0),
        ),
        isFalse,
      );
    });
  });

  test('the comparison is by instant, not by local wall clock', () {
    // A device in another zone must reach the same verdict.
    final fetched = ist(2026, 9, 10, 9, 0);
    expect(
      isStale(fetchedAt: fetched.toLocal(), now: ist(2026, 9, 10, 23, 0)),
      isFalse,
    );
  });

  test('lastRefreshBoundary rolls back before the morning publication', () {
    expect(
      lastRefreshBoundary(ist(2026, 9, 10, 8, 0)),
      ist(2026, 9, 9, 8, 30),
    );
    expect(
      lastRefreshBoundary(ist(2026, 9, 10, 9, 0)),
      ist(2026, 9, 10, 8, 30),
    );
  });
}
