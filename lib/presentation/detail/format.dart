/// Display formatting for market values.
///
/// Pure functions, kept out of the widgets so the cases that actually break —
/// a null percent change, a three-digit move, an empty book side — are
/// unit-testable without pumping a widget tree (§7 rules out widget tests).
///
/// Every function here answers one question: what does the user see when the
/// value is absent? The answer is always an em dash, never a zero. `₹0.00`
/// reads as a real quote at zero; `—` reads as "there isn't one", which is
/// what an empty book side actually means.
library;

/// The placeholder for anything absent. One constant so no screen invents
/// its own.
const String emDash = '—';

/// Rupees, two decimals, with Indian digit grouping.
///
/// Options routinely trade in paise (₹0.40) and occasionally in hundreds
/// (₹483.90), so the decimals are never dropped.
String formatRupees(double? value) {
  if (value == null) return emDash;
  final negative = value < 0;
  final absolute = value.abs();
  final whole = absolute.floor();
  final paise = ((absolute - whole) * 100).round();
  // Rounding can carry into the rupee part: 0.999 -> 1.00, not 0.100.
  final carried = paise == 100;
  final rupees = carried ? whole + 1 : whole;
  final fraction = carried ? 0 : paise;
  final sign = negative ? '-' : '';
  return '$sign₹${_groupIndian(rupees)}.${fraction.toString().padLeft(2, '0')}';
}

/// A signed percentage, or [emDash] when there is nothing to compare against.
///
/// §3.5 trap 4: options move ±200% in a day and that is normal, so this must
/// not assume equity-sized numbers. The sign is explicit because "+112.5%" and
/// "112.5%" read differently at a glance on a price screen.
String formatPercent(double? value) {
  if (value == null) return emDash;
  final sign = value > 0 ? '+' : '';
  return '$sign${value.toStringAsFixed(2)}%';
}

/// Contracts. Never scaled — §3.5 trap 1 divides prices only.
String formatQuantity(int? value) =>
    value == null ? emDash : _groupIndian(value);

/// Indian digit grouping: the last three digits, then pairs.
///
/// 710190 renders as 7,10,190 rather than 710,190. This app shows Indian
/// market data to a reader who thinks in lakhs, and western grouping of a
/// six-figure open-interest number reads as foreign.
String _groupIndian(int value) {
  final digits = value.abs().toString();
  if (digits.length <= 3) return value < 0 ? '-$digits' : digits;

  final last3 = digits.substring(digits.length - 3);
  var rest = digits.substring(0, digits.length - 3);

  final groups = <String>[];
  while (rest.length > 2) {
    groups.insert(0, rest.substring(rest.length - 2));
    rest = rest.substring(0, rest.length - 2);
  }
  if (rest.isNotEmpty) groups.insert(0, rest);

  final grouped = '${groups.join(',')},$last3';
  return value < 0 ? '-$grouped' : grouped;
}

/// A date and time for the replay banner, in the reader's own timezone sense.
String formatRecordedAt(DateTime value) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final hh = value.hour.toString().padLeft(2, '0');
  final mm = value.minute.toString().padLeft(2, '0');
  return '${value.day} ${months[value.month - 1]} $hh:$mm';
}
