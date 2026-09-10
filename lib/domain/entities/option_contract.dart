/// Which side of the contract this is.
///
/// The instrument master carries no such field — it is derived from the
/// symbol's `CE`/`PE` suffix at the mapping boundary (§3.2 hazard 4). Modelling
/// it as an enum rather than a two-character string means the derivation
/// happens exactly once and cannot be re-litigated by a caller comparing
/// strings.
enum OptionType {
  call('CE'),
  put('PE');

  const OptionType(this.code);

  /// The suffix as it appears in a broker symbol. Present so the mapper can
  /// round-trip through the cache without a second lookup table.
  final String code;
}

/// One tradable Nifty option contract.
///
/// Every §3.2 parsing hazard is already resolved by the time an instance
/// exists: [strike] is rupees rather than paise, [expiry] is a real
/// [DateTime] rather than `DDMMMYYYY`, and the numeric fields are numbers
/// rather than the quoted strings the broker sends. That is the point of the
/// type — above the mapping boundary the hazards are not merely handled, they
/// are unrepresentable.
final class OptionContract {
  const OptionContract({
    required this.token,
    required this.symbol,
    required this.strike,
    required this.expiry,
    required this.optionType,
    required this.lotSize,
    required this.tickSize,
  });

  /// The broker's instrument identifier, e.g. `"47163"`. Kept as a string
  /// because it is an opaque key — Phase 3 sends it back verbatim in a
  /// subscription frame, and reformatting an identifier is how a leading zero
  /// gets lost.
  final String token;

  /// The broker's tradable symbol, e.g. `"NIFTY15SEP2621900CE"`.
  final String symbol;

  /// Strike price in **rupees**. The broker sends paise as a decimal string
  /// (`"2190000.000000"` is ₹21,900); the ÷100 happens at the mapping
  /// boundary and nowhere else.
  final double strike;

  /// Expiry date at midnight local time. Only the date is meaningful — the
  /// broker publishes no expiry *time* in the instrument master.
  final DateTime expiry;

  final OptionType optionType;

  /// Contract multiplier: one lot is this many units of the underlying.
  final int lotSize;

  /// Minimum price increment, in rupees. Also ÷100 from the broker's paise.
  final double tickSize;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OptionContract &&
          other.token == token &&
          other.symbol == symbol &&
          other.strike == strike &&
          other.expiry == expiry &&
          other.optionType == optionType &&
          other.lotSize == lotSize &&
          other.tickSize == tickSize;

  @override
  int get hashCode => Object.hash(
    token,
    symbol,
    strike,
    expiry,
    optionType,
    lotSize,
    tickSize,
  );

  /// Names the contract rather than dumping its fields, because this reaches
  /// the logger and a field dump there is noise.
  @override
  String toString() => 'OptionContract($symbol)';
}
