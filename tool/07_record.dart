// Phase 0, step 7 — record a live session. MARKET HOURS ONLY.
//
// Writes assets/demo/feed_session.bin: raw binary frames plus arrival
// timestamps. Per SPEC §6 this is the single most important artifact in the
// project — it is what makes every later phase buildable at any hour, against
// real exchange data rather than invented numbers.
//
// Two tokens in one session:
//   - a liquid near-ATM strike, for the normal path
//   - an illiquid far-OTM strike, so §3.5 trap 5 (one-sided or empty book) has
//     a REAL fixture instead of a synthetic one
//
// Container format (little-endian), documented here and in DECISIONS.md
// because nothing in the spec pins it down:
//
//   file   := header record*
//   header := magic "ANGLFEED" (8B) | version uint16 | reserved uint16
//   record := epochMillis int64 | length uint32 | payload[length]
//
// A replay connection reads records in order and re-emits each payload after
// the inter-arrival gap, reproducing original timing including bursts and idle.
//
// Requires tool/.session.json from step 1.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '_shared.dart';

const _magic = 'ANGLFEED';
const _formatVersion = 1;

/// Default capture length. Long enough to catch bursts and quiet stretches.
const _defaultSeconds = 120;

Future<void> main(List<String> args) async {
  heading('PHASE 0 / STEP 7 — record a live feed session');

  if (!marketIsOpen()) {
    fail('Market is CLOSED (${nowIst()} IST).');
    info('Recording outside 09:15-15:30 IST would capture an empty file, which');
    info('is worse than none: later phases would replay silence and appear to');
    info('work. Re-run in-window.');
    exit(1);
  }
  info('IST now: ${nowIst()}  |  market OPEN');

  final seconds =
      args.isNotEmpty ? int.tryParse(args.first) ?? _defaultSeconds : _defaultSeconds;

  final fixture = File('test/fixtures/nifty_options.json');
  if (!fixture.existsSync()) {
    fail('Missing ${fixture.path}. Run tool/02_instruments.dart first.');
    exit(1);
  }
  final contracts =
      (jsonDecode(fixture.readAsStringSync()) as List).cast<Map<String, dynamic>>();

  final picks = _pickTokens(contracts);
  step('Tokens to record');
  info('liquid  (near ATM) : ${picks.liquid["token"]}  ${picks.liquid["symbol"]}');
  info('illiquid (far OTM) : ${picks.illiquid["token"]}  ${picks.illiquid["symbol"]}');
  info('duration           : ${seconds}s');

  final session = loadSession();
  final ws = await WebSocket.connect(wsUrl, headers: {
    'Authorization': 'Bearer ${session["jwtToken"]}',
    'x-api-key': session['apiKey'] as String,
    'x-client-code': session['clientCode'] as String,
    'x-feed-token': session['feedToken'] as String,
  }).timeout(const Duration(seconds: 15));
  pass('Connected');

  final out = File('assets/demo/feed_session.bin');
  final sink = out.openWrite();
  sink.add(ascii.encode(_magic));
  final head = ByteData(4)
    ..setUint16(0, _formatVersion, Endian.little)
    ..setUint16(2, 0, Endian.little);
  sink.add(head.buffer.asUint8List());

  var records = 0;
  var bytes = 0;
  var textFrames = 0;
  final perToken = <String, int>{};
  final started = DateTime.now();

  ws.listen(
    (data) {
      if (data is! List<int>) {
        // "pong" replies are not market data; count them but do not record.
        textFrames++;
        return;
      }
      final payload = Uint8List.fromList(data);
      final rec = ByteData(12)
        ..setInt64(0, DateTime.now().millisecondsSinceEpoch, Endian.little)
        ..setUint32(8, payload.length, Endian.little);
      sink
        ..add(rec.buffer.asUint8List())
        ..add(payload);
      records++;
      bytes += payload.length;

      // Track which token each packet belongs to, so the summary can prove the
      // illiquid strike actually produced data.
      if (payload.length >= 27) {
        final t = payload.sublist(2, 27);
        final nul = t.indexOf(0);
        final tok = utf8.decode(nul == -1 ? t : t.sublist(0, nul),
            allowMalformed: true);
        perToken[tok] = (perToken[tok] ?? 0) + 1;
      }
    },
    onError: (Object e) => fail('stream error: $e'),
    onDone: () => info('socket closed by server'),
    cancelOnError: false,
  );

  ws.add(jsonEncode({
    'correlationID': 'phase0_step7',
    'action': 1,
    'params': {
      'mode': 3,
      'tokenList': [
        {
          'exchangeType': 2,
          'tokens': [picks.liquid['token'], picks.illiquid['token']],
        },
      ],
    },
  }));
  info('subscribed both tokens in SNAP_QUOTE mode');

  // §3.3: mandatory, and a recording is exactly where forgetting it would
  // silently truncate the capture.
  final pinger =
      Timer.periodic(const Duration(seconds: 10), (_) => ws.add('ping'));

  step('Recording for ${seconds}s...');
  final ticker = Timer.periodic(const Duration(seconds: 15), (_) {
    final elapsed = DateTime.now().difference(started).inSeconds;
    info('  t+${elapsed}s: $records records, ${(bytes / 1024).toStringAsFixed(1)} KB');
  });

  await Future<void>.delayed(Duration(seconds: seconds));
  pinger.cancel();
  ticker.cancel();
  await ws.close();
  await sink.flush();
  await sink.close();

  step('Result');
  final kb = out.lengthSync() / 1024;
  info('file      ${out.path}');
  info('records   $records  (${kb.toStringAsFixed(1)} KB)');
  info('pongs     $textFrames text frames, not recorded');
  info('rate      ${(records / seconds).toStringAsFixed(1)} packets/sec');
  info('');
  info('packets per token:');
  for (final e in perToken.entries) {
    final which = e.key == picks.liquid['token']
        ? 'liquid'
        : e.key == picks.illiquid['token']
            ? 'illiquid'
            : 'unknown';
    info('  ${e.key.padRight(10)} ${e.value.toString().padLeft(5)}  ($which)');
  }

  if (records == 0) {
    fail('Recorded NOTHING. The fixture is useless — do not commit it.');
    exit(1);
  }
  pass('Fixture written');

  final gotIlliquid = perToken.containsKey(picks.illiquid['token']);
  if (!gotIlliquid) {
    info('');
    info('NOTE: the illiquid strike produced no packets. That is realistic —');
    info('a far-OTM option may simply not trade — but it means the one-sided');
    info('book path (§3.5 trap 5) has no fixture yet. Re-run against a');
    info('moderately-OTM strike to capture it.');
  }

  step('Verifying the file reads back');
  final verify = out.readAsBytesSync();
  final magic = ascii.decode(verify.sublist(0, 8));
  if (magic != _magic) {
    fail('Bad magic "$magic"');
    exit(1);
  }
  var offset = 12;
  var replayed = 0;
  int? firstTs;
  int? lastTs;
  while (offset + 12 <= verify.length) {
    final d = ByteData.view(verify.buffer, offset, 12);
    final ts = d.getInt64(0, Endian.little);
    final len = d.getUint32(8, Endian.little);
    offset += 12;
    if (offset + len > verify.length) {
      fail('Truncated record at offset $offset');
      break;
    }
    offset += len;
    replayed++;
    firstTs ??= ts;
    lastTs = ts;
  }
  (replayed == records ? pass : fail)(
      'Read back $replayed of $records records');
  if (firstTs != null && lastTs != null) {
    info('timespan ${((lastTs - firstTs) / 1000).toStringAsFixed(1)}s of '
        'wall-clock, preserved for replay');
  }

  heading('STEP 7 COMPLETE');
  exit(0);
}

/// Near-ATM proxy: middle strike of the nearest expiry. Far-OTM proxy: the
/// highest-strike call, which is the least likely to have resting orders.
({Map<String, dynamic> liquid, Map<String, dynamic> illiquid}) _pickTokens(
    List<Map<String, dynamic>> contracts) {
  final calls = contracts
      .where((c) => (c['symbol'] as String).endsWith('CE'))
      .toList()
    ..sort((a, b) => double.parse(a['strike'] as String)
        .compareTo(double.parse(b['strike'] as String)));
  return (liquid: calls[calls.length ~/ 2], illiquid: calls.last);
}
