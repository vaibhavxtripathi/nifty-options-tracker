// Phase 0, step 2 — prove SPEC §3.2 and produce test/fixtures/nifty_options.json
//
// Unauthenticated: this endpoint needs no session, so it runs even while the
// login in step 1 is blocked.
//
// Proves the four parsing hazards in §3.2 against real rows:
//   1. strike is paise-as-decimal-string      -> divide by 100
//   2. expiry is DDMMMYYYY, and DateTime.parse genuinely throws on it
//   3. every numeric field arrives quoted
//   4. there is no CE/PE field; it comes from the symbol suffix
import 'dart:convert';
import 'dart:io';

import '_shared.dart';

/// §3.2 hazard 2: uppercase English month abbreviations, not ISO.
const _months = {
  'JAN': 1, 'FEB': 2, 'MAR': 3, 'APR': 4, 'MAY': 5, 'JUN': 6,
  'JUL': 7, 'AUG': 8, 'SEP': 9, 'OCT': 10, 'NOV': 11, 'DEC': 12,
};

DateTime parseAngelExpiry(String raw) {
  if (raw.length != 9) {
    throw FormatException('Expected DDMMMYYYY (9 chars), got "$raw"');
  }
  final day = int.parse(raw.substring(0, 2));
  final month = _months[raw.substring(2, 5).toUpperCase()];
  if (month == null) throw FormatException('Unknown month in "$raw"');
  return DateTime(int.parse(raw.substring(5)), month, day);
}

/// §3.2 hazard 4: the last two characters of the symbol.
String optionTypeOf(String symbol) {
  final suffix = symbol.substring(symbol.length - 2).toUpperCase();
  if (suffix != 'CE' && suffix != 'PE') {
    throw FormatException('Symbol "$symbol" ends in neither CE nor PE');
  }
  return suffix;
}

Future<void> main() async {
  heading('PHASE 0 / STEP 2 — instrument master + §3.2 field shapes');
  info('This step is unauthenticated and independent of step 1.');

  step('GET $instrumentMasterUrl');
  final sw = Stopwatch()..start();
  final client = HttpClient();
  late final String raw;
  try {
    final req = await client.getUrl(Uri.parse(instrumentMasterUrl));
    final res = await req.close();
    if (res.statusCode != 200) {
      fail('HTTP ${res.statusCode}');
      exit(1);
    }
    raw = await res.transform(utf8.decoder).join();
  } finally {
    client.close();
  }
  final downloadMs = sw.elapsedMilliseconds;
  info('${(raw.length / 1024 / 1024).toStringAsFixed(1)} MB in ${downloadMs}ms');

  sw.reset();
  final all = jsonDecode(raw) as List<dynamic>;
  info('jsonDecode of ${all.length} rows took ${sw.elapsedMilliseconds}ms '
      'on the VM');
  info('-> §3.2 is right that this must not run on the UI isolate.');

  step('Filter: instrumenttype==OPTIDX && name==NIFTY && exch_seg==NFO');
  final nifty = all
      .cast<Map<String, dynamic>>()
      .where((r) =>
          r['instrumenttype'] == 'OPTIDX' &&
          r['name'] == 'NIFTY' &&
          r['exch_seg'] == 'NFO')
      .toList();
  info('total instruments : ${all.length}   (spec said 145,599)');
  info('nifty options     : ${nifty.length}   (spec said 1,588)');
  if (nifty.isEmpty) {
    fail('Filter matched nothing — the schema must have changed.');
    exit(1);
  }
  pass('Filter returns a non-empty contract set');

  step('Sample row, verbatim');
  info(const JsonEncoder.withIndent('  ').convert(nifty.first));

  // -- hazard 3: everything is a string --------------------------------------
  step('Hazard 3 — are numeric fields really quoted strings?');
  final sample = nifty.first;
  for (final key in ['token', 'strike', 'lotsize', 'tick_size']) {
    final v = sample[key];
    final isString = v is String;
    (isString ? pass : fail)('$key is ${v.runtimeType}'
        '${isString ? " (quoted, as §3.2 says)" : " — SPEC WRONG"}');
  }

  // -- hazard 1: strike is paise ---------------------------------------------
  step('Hazard 1 — strike is paise; divide by 100');
  final strikes = nifty
      .map((r) => double.parse(r['strike'] as String) / 100)
      .toList()
    ..sort();
  info('raw "${sample['strike']}" -> ₹'
      '${(double.parse(sample['strike'] as String) / 100).toStringAsFixed(2)}');
  info('range after ÷100: ₹${strikes.first.toStringAsFixed(0)} '
      '.. ₹${strikes.last.toStringAsFixed(0)}');
  final plausible = strikes.first > 100 && strikes.last < 100000;
  (plausible ? pass : fail)(plausible
      ? 'Range is plausible for Nifty — the ÷100 is confirmed'
      : 'Range is NOT plausible; re-check the divisor');

  // -- hazard 2: DDMMMYYYY ----------------------------------------------------
  step('Hazard 2 — expiry is DDMMMYYYY and DateTime.parse throws on it');
  final rawExpiry = sample['expiry'] as String;
  info('raw expiry: "$rawExpiry"');
  try {
    DateTime.parse(rawExpiry);
    fail('DateTime.parse ACCEPTED it — §3.2 is wrong about this');
  } on FormatException {
    pass('DateTime.parse throws, as §3.2 warns — manual parsing required');
  }
  final parsed = parseAngelExpiry(rawExpiry);
  pass('parseAngelExpiry -> ${parsed.toIso8601String().substring(0, 10)}');

  info('');
  info('Parsing every expiry in the set to be sure the format never varies:');
  final failures = <String>[];
  final expiries = <DateTime>{};
  for (final r in nifty) {
    try {
      expiries.add(parseAngelExpiry(r['expiry'] as String));
    } on FormatException {
      failures.add(r['expiry'] as String);
    }
  }
  (failures.isEmpty ? pass : fail)(failures.isEmpty
      ? 'All ${nifty.length} expiries parsed; ${expiries.length} distinct dates'
      : '${failures.length} failed, e.g. ${failures.take(3).join(", ")}');

  // -- hazard 4: no CE/PE field ----------------------------------------------
  step('Hazard 4 — no CE/PE field; derive from the symbol suffix');
  final hasTypeField = sample.keys.any(
      (k) => k.toLowerCase().contains('option') || k.toLowerCase() == 'type');
  (hasTypeField ? fail : pass)(hasTypeField
      ? 'A type-like field EXISTS — §3.2 may be wrong'
      : 'No CE/PE field present, exactly as §3.2 says');
  info('keys: ${sample.keys.join(", ")}');
  var ce = 0, pe = 0;
  final badSuffix = <String>[];
  for (final r in nifty) {
    try {
      optionTypeOf(r['symbol'] as String) == 'CE' ? ce++ : pe++;
    } on FormatException {
      badSuffix.add(r['symbol'] as String);
    }
  }
  (badSuffix.isEmpty ? pass : fail)(
      'CE $ce / PE $pe, ${badSuffix.length} unparseable');

  // -- fixture ---------------------------------------------------------------
  //
  // Trimmed to the three nearest expiries, per the approved plan: enough to
  // exercise search, sorting and nearest-expiry logic without committing
  // megabytes of JSON.
  step('Writing test/fixtures/nifty_options.json');
  final today = DateTime(nowIst().year, nowIst().month, nowIst().day);
  final upcoming = expiries.where((d) => !d.isBefore(today)).toList()..sort();
  final keep = upcoming.take(3).toSet();
  info('nearest 3 expiries: '
      '${keep.map((d) => d.toIso8601String().substring(0, 10)).join(", ")}');

  final fixture = nifty
      .where((r) => keep.contains(parseAngelExpiry(r['expiry'] as String)))
      .toList()
    ..sort((a, b) => (a['symbol'] as String).compareTo(b['symbol'] as String));

  final outFile = File('test/fixtures/nifty_options.json');
  outFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(fixture));
  final kb = outFile.lengthSync() / 1024;
  pass('${fixture.length} contracts, ${kb.toStringAsFixed(0)} KB');

  step('Nearest-expiry ATM candidates for steps 6-7 (market hours)');
  final nearest = upcoming.isEmpty ? null : upcoming.first;
  if (nearest != null) {
    final atm = fixture
        .where((r) => parseAngelExpiry(r['expiry'] as String) == nearest)
        .toList()
      ..sort((a, b) => double.parse(a['strike'] as String)
          .compareTo(double.parse(b['strike'] as String)));
    info('Expiry ${nearest.toIso8601String().substring(0, 10)}: '
        '${atm.length} contracts');
    info('lowest  strike ₹'
        '${(double.parse(atm.first['strike'] as String) / 100).toStringAsFixed(0)}'
        '  token ${atm.first['token']}');
    info('highest strike ₹'
        '${(double.parse(atm.last['strike'] as String) / 100).toStringAsFixed(0)}'
        '  token ${atm.last['token']}');
  }

  heading('STEP 2 COMPLETE');
}
