/// **The mapping boundary.** Broker JSON in, domain objects out.
///
/// Everything in this file is a pure function: no I/O, no state, no Flutter
/// import. That is load-bearing twice over — it is what lets
/// [parseNiftyOptions] be handed to `compute()` and run on a background
/// isolate, and it is what makes the four §3.2 parsing hazards testable
/// against the recorded fixture without a network or a device.
///
/// All four hazards are resolved here and **nowhere else**:
///
/// 1. `strike` is paise as a decimal string — `"2190000.000000"` is ₹21,900.
/// 2. `expiry` is `DDMMMYYYY` — `DateTime.parse` genuinely throws on it.
/// 3. Every numeric field arrives quoted.
/// 4. There is no CE/PE field; it comes from the symbol's last two characters.
library;

import 'dart:convert';

import '../../domain/entities/option_contract.dart';

/// Uppercase English month abbreviations, per §3.2 hazard 2.
const Map<String, int> _months = {
  'JAN': 1,
  'FEB': 2,
  'MAR': 3,
  'APR': 4,
  'MAY': 5,
  'JUN': 6,
  'JUL': 7,
  'AUG': 8,
  'SEP': 9,
  'OCT': 10,
  'NOV': 11,
  'DEC': 12,
};

/// Broker prices and strikes are integer paise; the app is denominated in
/// rupees. Named rather than inlined so the divisor appears once.
const double _paisePerRupee = 100;

/// Parses the broker's `DDMMMYYYY` expiry, e.g. `"06OCT2026"`.
///
/// Hand-rolled because `DateTime.parse` throws on this format — verified
/// against live data in Phase 0, not assumed.
DateTime parseAngelExpiry(String raw) {
  if (raw.length != 9) {
    throw FormatException('Expected DDMMMYYYY (9 chars), got "$raw"');
  }
  final day = int.tryParse(raw.substring(0, 2));
  final month = _months[raw.substring(2, 5).toUpperCase()];
  final year = int.tryParse(raw.substring(5));
  if (day == null || month == null || year == null) {
    throw FormatException('Unparseable expiry "$raw"');
  }
  return DateTime(year, month, day);
}

/// Derives call/put from the symbol suffix, per §3.2 hazard 4.
OptionType optionTypeOf(String symbol) {
  if (symbol.length < 2) {
    throw FormatException('Symbol "$symbol" is too short to carry a suffix');
  }
  final suffix = symbol.substring(symbol.length - 2).toUpperCase();
  return switch (suffix) {
    'CE' => OptionType.call,
    'PE' => OptionType.put,
    _ => throw FormatException('Symbol "$symbol" ends in neither CE nor PE'),
  };
}

/// Decodes the instrument master and returns only the Nifty options in it.
///
/// **This is the function handed to `compute()`**, which is why it takes the
/// raw JSON string and returns finished domain objects. The 32.5 MB payload
/// and the 145k intermediate maps stay inside the background isolate; only the
/// ~1,600 surviving contracts are copied back to the UI isolate. Filtering
/// after the isolate boundary would defeat the entire exercise.
///
/// A row that fails to parse is skipped rather than fatal. One malformed
/// contract out of 145,599 must not empty the search screen — and the broker
/// adds instrument types without notice.
List<OptionContract> parseNiftyOptions(String rawJson) {
  final decoded = jsonDecode(rawJson);
  if (decoded is! List) {
    throw const FormatException('Instrument master is not a JSON array');
  }

  final contracts = <OptionContract>[];
  for (final row in decoded) {
    if (row is! Map<String, dynamic>) continue;
    if (!_isNiftyOption(row)) continue;
    final contract = _toContract(row);
    if (contract != null) contracts.add(contract);
  }
  return contracts;
}

/// §3.2's filter, verified live in Phase 0: 1,588 of 145,599 instruments.
bool _isNiftyOption(Map<String, dynamic> row) =>
    row['instrumenttype'] == 'OPTIDX' &&
    row['name'] == 'NIFTY' &&
    row['exch_seg'] == 'NFO';

/// Returns null for a row that cannot be mapped, so one bad record is skipped
/// rather than throwing away the other 1,587.
OptionContract? _toContract(Map<String, dynamic> row) {
  try {
    final token = row['token'];
    final symbol = row['symbol'];
    final expiry = row['expiry'];
    if (token is! String || symbol is! String || expiry is! String) return null;

    return OptionContract(
      token: token,
      symbol: symbol,
      // Hazards 1 and 3 together: a quoted decimal string, in paise.
      strike: _rupeesFrom(row['strike']),
      expiry: parseAngelExpiry(expiry),
      optionType: optionTypeOf(symbol),
      lotSize: _intFrom(row['lotsize']),
      tickSize: _rupeesFrom(row['tick_size']),
    );
  } on FormatException {
    return null;
  }
}

/// Hazard 3: numeric fields arrive quoted, so accept either shape rather than
/// trusting the field to stay a string forever.
double _rupeesFrom(Object? value) => switch (value) {
  final String s => double.parse(s) / _paisePerRupee,
  final num n => n / _paisePerRupee,
  _ => throw FormatException('Expected a numeric value, got $value'),
};

int _intFrom(Object? value) => switch (value) {
  final String s => int.parse(s),
  final int n => n,
  _ => throw FormatException('Expected an integer value, got $value'),
};
