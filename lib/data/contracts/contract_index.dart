import '../../domain/entities/option_contract.dart';

/// In-memory search over the day's contract universe (§5.3 item 6).
///
/// Built once per load and then queried synchronously. There is **no
/// debounce** and no `async` anywhere in this file, deliberately: debouncing
/// exists to avoid firing a request per keystroke, and there is no request
/// here to fire. Filtering ~1,600 records is microseconds, so the results can
/// simply keep up with the keyboard.
final class ContractIndex {
  ContractIndex(List<OptionContract> contracts)
    : _contracts = List.unmodifiable(_sorted(contracts)),
      _nearestExpiry = _earliestExpiryOf(contracts);

  /// Held in display order, so a query only has to filter — never re-sort.
  final List<OptionContract> _contracts;

  final DateTime? _nearestExpiry;

  /// The soonest expiry present. The UI marks contracts on this date because
  /// someone searching a strike wants this week's contract first, not one four
  /// months out (§5.3).
  ///
  /// Null only when the index is empty.
  DateTime? get nearestExpiry => _nearestExpiry;

  int get length => _contracts.length;

  bool get isEmpty => _contracts.isEmpty;

  /// Whether [contract] expires on the nearest available date.
  bool isNearestExpiry(OptionContract contract) =>
      _nearestExpiry != null && contract.expiry == _nearestExpiry;

  /// Contracts matching [query], in expiry-then-strike order.
  ///
  /// A blank query returns everything, so the screen has something to show
  /// before the user types. Matching is case-insensitive and covers both the
  /// strike digits ("21900") and any part of the symbol ("21900CE", "SEP").
  List<OptionContract> search(String query) {
    final needle = query.trim().toUpperCase();
    if (needle.isEmpty) return _contracts;
    return _contracts.where((c) => _matches(c, needle)).toList();
  }

  static bool _matches(OptionContract contract, String needle) {
    if (contract.symbol.toUpperCase().contains(needle)) return true;
    // Strikes are whole rupees in practice, so "21900" should match ₹21,900
    // without the user typing a decimal point.
    return _strikeDigits(contract.strike).contains(needle);
  }

  static String _strikeDigits(double strike) =>
      strike == strike.roundToDouble()
      ? strike.toStringAsFixed(0)
      : strike.toString();

  /// §5.3: expiry ascending, then strike. Sorted once at construction rather
  /// than per keystroke — the order never depends on the query.
  static List<OptionContract> _sorted(List<OptionContract> contracts) {
    return [...contracts]..sort((a, b) {
      final byExpiry = a.expiry.compareTo(b.expiry);
      if (byExpiry != 0) return byExpiry;
      final byStrike = a.strike.compareTo(b.strike);
      if (byStrike != 0) return byStrike;
      // Calls before puts at the same strike, so a pair reads in a stable
      // order rather than shuffling between loads.
      return a.optionType.index.compareTo(b.optionType.index);
    });
  }

  static DateTime? _earliestExpiryOf(List<OptionContract> contracts) {
    DateTime? earliest;
    for (final contract in contracts) {
      if (earliest == null || contract.expiry.isBefore(earliest)) {
        earliest = contract.expiry;
      }
    }
    return earliest;
  }
}
