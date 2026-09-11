import 'book_level.dart';

/// One complete market-data snapshot for one instrument.
///
/// **A snapshot, not a delta.** Every SNAP_QUOTE packet carries the full
/// picture, which is what makes the conflation in §5.7 lossless: the newest
/// tick contains everything a dropped one did. Nothing downstream needs to
/// accumulate state across ticks, and nothing may assume it received them all.
///
/// Rupee-denominated and null-guarded by the time an instance exists. The
/// decoder is the only place paise become rupees, and the only place an absent
/// book level becomes null.
final class MarketTick {
  const MarketTick({
    required this.token,
    required this.lastTradedPrice,
    required this.previousClose,
    required this.volume,
    required this.openInterest,
    required this.exchangeTimestamp,
    this.bestBid,
    this.bestAsk,
    this.open = 0,
    this.high = 0,
    this.low = 0,
    this.lastTradedQuantity = 0,
    this.averageTradedPrice = 0,
    this.totalBuyQuantity = 0,
    this.totalSellQuantity = 0,
    this.openInterestChangePercent = 0,
    this.upperCircuit = 0,
    this.lowerCircuit = 0,
    this.fiftyTwoWeekHigh = 0,
    this.fiftyTwoWeekLow = 0,
  });

  /// The broker's instrument identifier, matching `OptionContract.token`.
  final String token;

  /// Rupees.
  final double lastTradedPrice;

  /// Rupees. The denominator for [changePercent], and **may legitimately be
  /// zero** — a newly listed strike has no previous close.
  final double previousClose;

  /// Contracts traded today. Not scaled.
  final int volume;

  /// Open contracts. Not scaled.
  final int openInterest;

  final DateTime exchangeTimestamp;

  /// Null when nothing is resting on that side of the book (§3.5 trap 5).
  final BookLevel? bestBid;
  final BookLevel? bestAsk;

  final double open;
  final double high;
  final double low;
  final int lastTradedQuantity;
  final double averageTradedPrice;
  final double totalBuyQuantity;
  final double totalSellQuantity;

  /// Arrives in the same packet at no extra cost (§3.4 bonus).
  final double openInterestChangePercent;
  final double upperCircuit;
  final double lowerCircuit;
  final double fiftyTwoWeekHigh;
  final double fiftyTwoWeekLow;

  /// Change from the previous close, as a percentage — **null when there is no
  /// previous close to compare against**.
  ///
  /// §3.5 trap 3: a newly listed strike, and a deep-OTM option that settled at
  /// zero, both have `previousClose == 0`. The arithmetic then yields
  /// `Infinity` or `NaN`, neither of which is a number a UI can render. The
  /// nullable return type is what forces every render site to decide what to
  /// show instead — the UI renders an em dash.
  double? get changePercent {
    if (previousClose == 0) return null;
    return (lastTradedPrice - previousClose) / previousClose * 100;
  }

  /// Rupees between the best bid and the best ask, or null if either side is
  /// empty. Enormous on far-OTM strikes (§3.5 trap 6) — bid 0.05, ask 0.60 is
  /// normal, so no layout may assume a tight spread.
  double? get spread {
    final bid = bestBid;
    final ask = bestAsk;
    if (bid == null || ask == null) return null;
    return ask.price - bid.price;
  }

  /// Midpoint of the book, or null if either side is empty.
  double? get mid {
    final bid = bestBid;
    final ask = bestAsk;
    if (bid == null || ask == null) return null;
    return (bid.price + ask.price) / 2;
  }

  /// Names the instrument and its price. Deliberately terse: this reaches the
  /// logger, and a full field dump per tick would bury everything else.
  @override
  String toString() => 'MarketTick($token @ $lastTradedPrice)';
}
