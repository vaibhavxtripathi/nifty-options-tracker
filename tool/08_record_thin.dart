// Phase 0, step 7b — capture a genuinely one-sided book. MARKET HOURS ONLY.
//
// Step 7 recorded the normal path: a liquid near-ATM strike with a full
// five-deep book on both sides. Its "illiquid" pick produced a 4-buy/5-sell
// book, which is uneven but not the case §3.5 trap 5 actually warns about —
// an illiquid strike with **no resting orders on one side at all**.
//
// A decoder that assumes an entry exists reads garbage there rather than
// throwing, so this path needs a real fixture and not a synthetic one. This
// script subscribes to several deep strikes at once and keeps whichever
// packets have an empty side, writing test/fixtures/feed_thin_book.bin in the
// same container format as step 7.
//
// Requires tool/.session.json from step 1.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '_shared.dart';

const _magic = 'ANGLFEED';
const _formatVersion = 1;

/// Deep strikes, chosen to maximise the chance of a dead side: far-OTM calls
/// at the top of the chain and far-OTM puts at the bottom, where premiums
/// round to a few paise and market makers often quote only one side.
const _candidateTokens = <String, String>{
  '55290': 'NIFTY29SEP2631500CE',
  '55292': 'NIFTY29SEP2634500CE',
  '65882': 'NIFTY29SEP2615000PE',
  '55281': 'NIFTY29SEP2616500PE',
  '65888': 'NIFTY29SEP2618000PE',
};

Future<void> main(List<String> args) async {
  heading('PHASE 0 / STEP 7b — capture a one-sided book');

  if (!marketIsOpen()) {
    fail('Market is CLOSED (${nowIst()} IST).');
    exit(1);
  }
  info('IST now: ${nowIst()}  |  market OPEN');

  final seconds = args.isNotEmpty
      ? int.tryParse(args.first) ?? 120
      : 120;

  step('Subscribing to ${_candidateTokens.length} deep strikes');
  for (final e in _candidateTokens.entries) {
    info('  ${e.key.padRight(8)} ${e.value}');
  }
  info('duration: ${seconds}s');

  final session = loadSession();
  final ws = await WebSocket.connect(wsUrl, headers: {
    'Authorization': 'Bearer ${session["jwtToken"]}',
    'x-api-key': session['apiKey'] as String,
    'x-client-code': session['clientCode'] as String,
    'x-feed-token': session['feedToken'] as String,
  }).timeout(const Duration(seconds: 15));
  pass('Connected');

  final out = File('test/fixtures/feed_thin_book.bin');
  final sink = out.openWrite();
  sink.add(ascii.encode(_magic));
  final head = ByteData(4)
    ..setUint16(0, _formatVersion, Endian.little)
    ..setUint16(2, 0, Endian.little);
  sink.add(head.buffer.asUint8List());

  var seen = 0;
  var kept = 0;
  final keptShapes = <String>{};
  final perToken = <String, String>{};

  ws.listen(
    (data) {
      if (data is! List<int>) return;
      final payload = Uint8List.fromList(data);
      seen++;
      if (payload.length < 379) return;

      final shape = _bookShape(payload);
      final token = _tokenOf(payload);
      perToken[token] = '${shape.buys} buy / ${shape.sells} sell';

      // Keep only what step 7 could not provide: a side that is genuinely
      // empty. Everything else is already covered by the main fixture.
      if (shape.buys == 0 || shape.sells == 0) {
        final rec = ByteData(12)
          ..setInt64(0, DateTime.now().millisecondsSinceEpoch, Endian.little)
          ..setUint32(8, payload.length, Endian.little);
        sink
          ..add(rec.buffer.asUint8List())
          ..add(payload);
        kept++;
        keptShapes.add('$token: ${shape.buys} buy / ${shape.sells} sell');
      }
    },
    onError: (Object e) => fail('stream error: $e'),
    cancelOnError: false,
  );

  ws.add(jsonEncode({
    'correlationID': 'phase0_step7b',
    'action': 1,
    'params': {
      'mode': 3,
      'tokenList': [
        {'exchangeType': 2, 'tokens': _candidateTokens.keys.toList()},
      ],
    },
  }));

  final pinger =
      Timer.periodic(const Duration(seconds: 10), (_) => ws.add('ping'));
  final ticker = Timer.periodic(const Duration(seconds: 20), (_) {
    info('  seen $seen packets, kept $kept one-sided');
  });

  await Future<void>.delayed(Duration(seconds: seconds));
  pinger.cancel();
  ticker.cancel();
  await ws.close();
  await sink.flush();
  await sink.close();

  step('Book shape observed per token');
  for (final e in perToken.entries) {
    info('  ${e.key.padRight(8)} ${e.value}');
  }

  step('Result');
  info('seen   $seen packets');
  info('kept   $kept with an empty side');
  for (final s in keptShapes) {
    info('  $s');
  }

  if (kept == 0) {
    out.deleteSync();
    info('');
    info('No fully one-sided book appeared in this window. That is a real');
    info('finding, not a failure: even deep strikes were quoted both sides');
    info('today. The decoder must still handle the empty case — it will be');
    info('covered by a synthetic packet, and this result recorded as the');
    info('reason why that is the best available evidence.');
    exit(2);
  }

  pass('Fixture written: ${out.path} '
      '(${(out.lengthSync() / 1024).toStringAsFixed(1)} KB)');
  heading('STEP 7b COMPLETE');
  exit(0);
}

String _tokenOf(Uint8List p) {
  final t = p.sublist(2, 27);
  final nul = t.indexOf(0);
  return utf8.decode(nul == -1 ? t : t.sublist(0, nul), allowMalformed: true);
}

({int buys, int sells}) _bookShape(Uint8List p) {
  final view = ByteData.view(p.buffer, p.offsetInBytes, p.length);
  var buys = 0;
  var sells = 0;
  for (var i = 0; i < 10; i++) {
    final base = 147 + i * 20;
    final flag = view.getUint16(base, Endian.little);
    final price = view.getInt64(base + 10, Endian.little);
    if (price == 0) continue;
    if (flag == 1) {
      buys++;
    } else {
      sells++;
    }
  }
  return (buys: buys, sells: sells);
}
