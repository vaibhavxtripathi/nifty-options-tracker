/// Whether the exchange is trading.
///
/// **Derived from the clock, not from the feed.** Angel One sends no
/// segment-status frame — the Upstox design got this for free from a
/// `market_info` message on connect, and losing it is one of the real costs of
/// the broker switch recorded in `docs/DECISIONS.md`.
///
/// The consequence is that this is a weaker signal than it looks: a trading
/// holiday reads as [open] with a silent socket. That is precisely why
/// [unknown] exists as a third case rather than this being a boolean — and why
/// the staleness watchdog in §5.4 gates on it rather than trusting it.
enum MarketStatus {
  open,
  closed,

  /// Cannot be determined — for example a holiday, which the clock alone
  /// cannot distinguish from a trading day.
  unknown,
}

/// IST is UTC+05:30 with no daylight saving, so a fixed offset is correct
/// year-round. Duplicated from `contract_freshness.dart` deliberately: that
/// constant belongs to the contract cache's publication boundary and this one
/// to market hours. They are equal today by coincidence of geography, not
/// because either depends on the other.
const Duration istOffset = Duration(hours: 5, minutes: 30);

const int _openMinutes = 9 * 60 + 15;
const int _closeMinutes = 15 * 60 + 30;

/// Whether the exchange is trading at [instant].
///
/// Weekends are [closed]; weekday sessions run 09:15–15:30 IST. Holidays are
/// indistinguishable from trading days by clock alone, so this deliberately
/// never returns [MarketStatus.unknown] — a caller that needs to express
/// "a holiday, probably" derives it from silence on an open market, which is
/// exactly what the §5.4 watchdog does.
MarketStatus marketStatusAt(DateTime instant) {
  final ist = instant.toUtc().add(istOffset);
  if (ist.weekday > DateTime.friday) return MarketStatus.closed;
  final minutes = ist.hour * 60 + ist.minute;
  return minutes >= _openMinutes && minutes <= _closeMinutes
      ? MarketStatus.open
      : MarketStatus.closed;
}
