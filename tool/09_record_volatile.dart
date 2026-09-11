// Phase 0, step 7c — capture a violently-moving strike. MARKET HOURS ONLY.
//
// `feed_session.bin` is a good general fixture but its liquid strike only
// moves about -20% from the previous close. §3.5 trap 4 says options routinely
// move ±200% in a day, and §6 Phase 4 makes "three-digit percentages do not
// break the layout" an acceptance criterion.
//
// A synthetic three-digit move would be easy to fabricate and worth nothing:
// the point is to prove the *real* feed produces numbers that wide, and that
// the layout survives them. So this records cheap near-expiry out-of-the-money
// calls, which are where the largest percentage swings actually happen — a
// contract trading at ₹2 against a ₹1 previous close is +100% and entirely
// ordinary four days before expiry.
//
// Writes test/fixtures/feed_volatile.bin in the same container format as
// step 7. Requires tool/.session.json from step 1.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '_shared.dart';

const _magic = 'ANGLFEED';
const _formatVersion = 1;

/// Near-expiry OTM calls: cheap enough that a small absolute move is a huge
/// percentage one, and liquid enough to actually tick.
const _candidates = <String, String>{
  '47423': 'NIFTY15SEP2625950CE',
  '47429': 'NIFTY15SEP2626000CE',
  '47435': 'NIFTY15SEP2626050CE',
  '47437': 'NIFTY15SEP2626100CE',
  '47439': 'NIFTY15SEP2626150CE',
  '47441': 'NIFTY15SEP2626200CE',
};

Future<void> main(List<String> args) async {
  heading('PHASE 0 / STEP 7c — capture a violently-moving strike');

  if (!marketIsOpen()) {
    fail('Market is CLOSED (${nowIst()} IST).');
    exit(1);
  }
  info('IST now: ${nowIst()}  |  market OPEN');

  final seconds = args.isNotEmpty ? int.tryParse(args.first) ?? 120 : 120;

  step('Subscribing to ${_candidates.length} near-expiry OTM calls');
  for (final e in _candidates.entries) {
    info('  ${e.key.padRight(8)} ${e.value}');
  }

  final session = loadSession();
  final ws = await WebSocket.connect(wsUrl, headers: {
    'Authorization': 'Bearer ${session["jwtToken"]}',
    'x-api-key': session['apiKey'] as String,
    'x-client-code': session['clientCode'] as String,
    'x-feed-token': session['feedToken'] as String,
  }).timeout(const Duration(seconds: 15));
  pass('Connected');

  final out = File('test/fixtures/feed_volatile.bin');
  final sink = out.openWrite();
  sink.add(ascii.encode(_magic));
  final head = ByteData(4)
    ..setUint16(0, _formatVersion, Endian.little)
    ..setUint16(2, 0, Endian.little);
  sink.add(head.buffer.asUint8List());

  var records = 0;
  final extremes = <String, double>{};

  ws.listen(
    (data) {
      if (data is! List<int>) return;
      final payload = Uint8List.fromList(data);
      if (payload.length < 379) return;

      final rec = ByteData(12)
        ..setInt64(0, DateTime.now().millisecondsSinceEpoch, Endian.little)
        ..setUint32(8, payload.length, Endian.little);
      sink
        ..add(rec.buffer.asUint8List())
        ..add(payload);
      records++;

      final view = ByteData.view(payload.buffer, payload.offsetInBytes);
      final token = _tokenOf(payload);
      final ltp = view.getInt64(43, Endian.little) / 100;
      final close = view.getInt64(115, Endian.little) / 100;
      if (close > 0) {
        final change = (ltp - close) / close * 100;
        final best = extremes[token];
        if (best == null || change.abs() > best.abs()) {
          extremes[token] = change;
        }
      }
    },
    onError: (Object e) => fail('stream error: $e'),
    cancelOnError: false,
  );

  ws.add(jsonEncode({
    'correlationID': 'phase0_step7c',
    'action': 1,
    'params': {
      'mode': 3,
      'tokenList': [
        {'exchangeType': 2, 'tokens': _candidates.keys.toList()},
      ],
    },
  }));

  final pinger =
      Timer.periodic(const Duration(seconds: 10), (_) => ws.add('ping'));
  final ticker = Timer.periodic(const Duration(seconds: 20), (_) {
    info('  $records records; widest so far: '
        '${_widest(extremes).toStringAsFixed(1)}%');
  });

  step('Recording for ${seconds}s...');
  await Future<void>.delayed(Duration(seconds: seconds));
  pinger.cancel();
  ticker.cancel();
  await ws.close();
  await sink.flush();
  await sink.close();

  step('Result');
  info('records $records  (${(out.lengthSync() / 1024).toStringAsFixed(1)} KB)');
  info('');
  info('widest percent change seen per token:');
  for (final e in extremes.entries) {
    final label = _candidates[e.key] ?? e.key;
    info('  ${label.padRight(26)} ${e.value.toStringAsFixed(1)}%');
  }

  if (records == 0) {
    out.deleteSync();
    fail('Recorded nothing — do not commit an empty fixture.');
    exit(1);
  }

  final widest = _widest(extremes);
  info('');
  if (widest.abs() >= 100) {
    pass('A three-digit percentage was captured (${widest.toStringAsFixed(1)}%) '
        '— §6 Phase 4 can assert the layout against real data.');
  } else {
    info('Widest was ${widest.toStringAsFixed(1)}%, under three digits. That is '
        'a real observation about today rather than a failure: the layout test '
        'will have to state that its three-digit case is synthetic.');
  }

  heading('STEP 7c COMPLETE');
  exit(0);
}

double _widest(Map<String, double> extremes) {
  if (extremes.isEmpty) return 0;
  return extremes.values.reduce((a, b) => a.abs() > b.abs() ? a : b);
}

String _tokenOf(Uint8List p) {
  final t = p.sublist(2, 27);
  final nul = t.indexOf(0);
  return utf8.decode(nul == -1 ? t : t.sublist(0, nul), allowMalformed: true);
}
