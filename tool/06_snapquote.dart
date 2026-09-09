// Phase 0, step 6 — prove SPEC §3.4 field mapping. MARKET HOURS ONLY.
//
// Subscribes to one liquid near-ATM option in SNAP_QUOTE mode, decodes a packet
// at the documented offsets, and prints every field in §3.4's mapping table as
// raw value AND converted value, side by side, so the ÷100 divisor can be
// eyeballed against any Angel One client. A decimal-place error here is silent
// and poisons everything downstream, which is why it gets its own step.
//
// Requires tool/.session.json from step 1.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '_shared.dart';

/// §3.4: SNAP_QUOTE is 379 bytes. Trap 7 says validate before reading offsets.
const snapQuoteLength = 379;

/// One side of the best-five book.
typedef BookLevel = ({int quantity, double price, int orders});

/// Decode a SNAP_QUOTE packet. Pure: bytes in, values out, no I/O and no state
/// — this is the shape §5.5 will take in the real app.
({
  int mode,
  int exchangeType,
  String token,
  int sequence,
  DateTime exchangeTimestamp,
  double lastTradedPrice,
  int lastTradedQuantity,
  double averageTradedPrice,
  int volumeTradedToday,
  double totalBuyQuantity,
  double totalSellQuantity,
  double open,
  double high,
  double low,
  double close,
  int openInterest,
  double upperCircuit,
  double lowerCircuit,
  double fiftyTwoWeekHigh,
  double fiftyTwoWeekLow,
  List<BookLevel> buy,
  List<BookLevel> sell,
}) decodeSnapQuote(Uint8List bytes) {
  if (bytes.length < snapQuoteLength) {
    throw FormatException(
        'Short packet: ${bytes.length}B, need $snapQuoteLength (§3.5 trap 7)');
  }
  final d = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);

  // §3.4: token is 25 bytes of null-padded utf8 at offset 2.
  final tokenBytes = bytes.sublist(2, 27);
  final nul = tokenBytes.indexOf(0);
  final token =
      utf8.decode(nul == -1 ? tokenBytes : tokenBytes.sublist(0, nul));

  // §3.5 trap 1: prices are integer paise. Quantities/volume/OI are NOT scaled.
  double paise(int offset) => d.getInt64(offset, Endian.little) / 100.0;

  final buy = <BookLevel>[];
  final sell = <BookLevel>[];
  for (var i = 0; i < 10; i++) {
    final base = 147 + i * 20;
    // §3.4: read the FLAG, do not trust position. §3.5 trap 5: a side can be
    // absent entirely on an illiquid strike.
    final isBuy = d.getUint16(base, Endian.little) == 1;
    final level = (
      quantity: d.getInt64(base + 2, Endian.little),
      price: d.getInt64(base + 10, Endian.little) / 100.0,
      orders: d.getUint16(base + 18, Endian.little),
    );
    if (level.quantity == 0 && level.price == 0) continue;
    (isBuy ? buy : sell).add(level);
  }

  return (
    mode: d.getUint8(0),
    exchangeType: d.getUint8(1),
    token: token,
    sequence: d.getInt64(27, Endian.little),
    exchangeTimestamp: DateTime.fromMillisecondsSinceEpoch(
        d.getInt64(35, Endian.little)),
    lastTradedPrice: paise(43),
    lastTradedQuantity: d.getInt64(51, Endian.little),
    averageTradedPrice: paise(59),
    volumeTradedToday: d.getInt64(67, Endian.little),
    totalBuyQuantity: d.getFloat64(75, Endian.little),
    totalSellQuantity: d.getFloat64(83, Endian.little),
    open: paise(91),
    high: paise(99),
    low: paise(107),
    close: paise(115),
    openInterest: d.getInt64(131, Endian.little),
    upperCircuit: paise(347),
    lowerCircuit: paise(355),
    fiftyTwoWeekHigh: paise(363),
    fiftyTwoWeekLow: paise(371),
    buy: buy,
    sell: sell,
  );
}

/// §3.5 trap 3: close can be zero, and the percentage must then be null rather
/// than Infinity or NaN.
double? percentChange({required double ltp, required double close}) =>
    close == 0 ? null : (ltp - close) / close * 100;

Future<void> main(List<String> args) async {
  heading('PHASE 0 / STEP 6 — SNAP_QUOTE decode against §3.4');

  if (!marketIsOpen()) {
    fail('Market is CLOSED (${nowIst()} IST).');
    info('This step needs 09:15-15:30 IST on a weekday: outside the window no');
    info('ticks arrive and an empty result would prove nothing. Re-run in-window.');
    exit(1);
  }
  info('IST now: ${nowIst()}  |  market OPEN');

  // Pick a near-ATM strike from the step-2 fixture unless one is passed in.
  final fixture = File('test/fixtures/nifty_options.json');
  if (!fixture.existsSync()) {
    fail('Missing ${fixture.path}. Run tool/02_instruments.dart first.');
    exit(1);
  }
  final contracts =
      (jsonDecode(fixture.readAsStringSync()) as List).cast<Map<String, dynamic>>();

  final token = args.isNotEmpty ? args.first : _nearAtmToken(contracts);
  final contract = contracts.firstWhere((c) => c['token'] == token,
      orElse: () => <String, dynamic>{});
  info('Subscribing to token $token '
      '${contract.isEmpty ? "(not in fixture)" : contract["symbol"]}');

  final session = loadSession();
  final ws = await WebSocket.connect(wsUrl, headers: {
    'Authorization': 'Bearer ${session["jwtToken"]}',
    'x-api-key': session['apiKey'] as String,
    'x-client-code': session['clientCode'] as String,
    'x-feed-token': session['feedToken'] as String,
  }).timeout(const Duration(seconds: 15));
  pass('Connected');

  final firstPacket = Completer<Uint8List>();
  ws.listen(
    (data) {
      if (data is List<int> && data.length >= snapQuoteLength) {
        if (!firstPacket.isCompleted) {
          firstPacket.complete(Uint8List.fromList(data));
        }
      }
    },
    onError: (Object e) {
      if (!firstPacket.isCompleted) firstPacket.completeError(e);
    },
  );

  ws.add(jsonEncode({
    'correlationID': 'phase0_step6',
    'action': 1,
    'params': {
      'mode': 3,
      'tokenList': [
        {'exchangeType': 2, 'tokens': [token]},
      ],
    },
  }));

  final pinger = Timer.periodic(
      const Duration(seconds: 10), (_) => ws.add('ping'));

  step('Waiting for the first SNAP_QUOTE packet...');
  final Uint8List packet;
  try {
    packet = await firstPacket.future.timeout(const Duration(seconds: 45));
  } on TimeoutException {
    fail('No packet in 45s. An illiquid strike can be genuinely silent — try a '
        'nearer-ATM token, or pass one as an argument.');
    pinger.cancel();
    await ws.close();
    exit(1);
  }
  pinger.cancel();

  step('Packet length (§3.5 trap 7)');
  info('received ${packet.length} bytes, expected $snapQuoteLength');
  (packet.length == snapQuoteLength ? pass : fail)(
      packet.length == snapQuoteLength
          ? 'Length matches §3.4 exactly'
          : 'LENGTH MISMATCH — §3.4 offsets may be wrong');

  final q = decodeSnapQuote(packet);

  step('Header');
  info('mode          ${q.mode}   (expect 3 = SNAP_QUOTE)');
  info('exchangeType  ${q.exchangeType}   (expect 2 = NSE_FO)');
  info('token         "${q.token}"   (expect "$token")');
  (q.token == token ? pass : fail)(q.token == token
      ? 'Token round-trips — the 25-byte null-padded field decodes correctly'
      : 'TOKEN MISMATCH — offset 2..27 is wrong');
  info('sequence      ${q.sequence}');
  info('exch time     ${q.exchangeTimestamp.toIso8601String()}');

  step('§3.4 REQUIRED MAPPING — raw vs converted');
  final d = ByteData.view(packet.buffer);
  void row(String label, int offset, num converted, String unit) {
    info('${label.padRight(18)} raw ${d.getInt64(offset, Endian.little).toString().padLeft(12)}'
        '   ->  ${converted.toStringAsFixed(2).padLeft(12)} $unit');
  }

  row('LTP (÷100)', 43, q.lastTradedPrice, 'INR');
  row('prev close (÷100)', 115, q.close, 'INR');
  info('${"volume".padRight(18)} raw ${q.volumeTradedToday.toString().padLeft(12)}'
      '   ->  ${q.volumeTradedToday.toString().padLeft(12)} contracts (NOT scaled)');
  info('${"open interest".padRight(18)} raw ${q.openInterest.toString().padLeft(12)}'
      '   ->  ${q.openInterest.toString().padLeft(12)} contracts (NOT scaled)');

  final pct = percentChange(ltp: q.lastTradedPrice, close: q.close);
  info('${"% change".padRight(18)} computed        ->  '
      '${pct == null ? "null (close is 0 — §3.5 trap 3)" : "${pct.toStringAsFixed(2)}%"}');

  step('Best five (§3.4: scan by FLAG, not position)');
  info('buy levels : ${q.buy.length}, sell levels: ${q.sell.length}');
  for (var i = 0; i < q.buy.length; i++) {
    info('  buy  $i  ${q.buy[i].price.toStringAsFixed(2).padLeft(9)} x '
        '${q.buy[i].quantity.toString().padLeft(7)}  (${q.buy[i].orders} orders)');
  }
  for (var i = 0; i < q.sell.length; i++) {
    info('  sell $i  ${q.sell[i].price.toStringAsFixed(2).padLeft(9)} x '
        '${q.sell[i].quantity.toString().padLeft(7)}  (${q.sell[i].orders} orders)');
  }
  final bestBid = q.buy.isEmpty ? null : q.buy.first;
  final bestAsk = q.sell.isEmpty ? null : q.sell.first;
  info('best bid ${bestBid == null ? "— (§3.5 trap 5: one-sided book)" : bestBid.price.toStringAsFixed(2)}');
  info('best ask ${bestAsk == null ? "— (§3.5 trap 5: one-sided book)" : bestAsk.price.toStringAsFixed(2)}');
  if (bestBid != null && bestAsk != null) {
    final spread = bestAsk.price - bestBid.price;
    info('spread   ${spread.toStringAsFixed(2)}  '
        'mid ${((bestBid.price + bestAsk.price) / 2).toStringAsFixed(2)}');
  }

  step('Day OHLC and the free extras (§3.4 bonus)');
  info('open ${q.open.toStringAsFixed(2)}  high ${q.high.toStringAsFixed(2)}  '
      'low ${q.low.toStringAsFixed(2)}  close ${q.close.toStringAsFixed(2)}');
  info('circuit ${q.lowerCircuit.toStringAsFixed(2)} .. '
      '${q.upperCircuit.toStringAsFixed(2)}');
  info('52wk    ${q.fiftyTwoWeekLow.toStringAsFixed(2)} .. '
      '${q.fiftyTwoWeekHigh.toStringAsFixed(2)}');

  step('SANITY — is the ÷100 divisor right?');
  info('Compare the LTP above against this contract in any Angel One client.');
  info('An option trading around a few hundred rupees should read as such;');
  info('if it reads 100x too large or small, the divisor is wrong.');
  final plausible = q.lastTradedPrice > 0 && q.lastTradedPrice < 100000;
  (plausible ? pass : fail)(plausible
      ? 'LTP ₹${q.lastTradedPrice.toStringAsFixed(2)} is in a plausible range'
      : 'LTP ₹${q.lastTradedPrice} is NOT plausible — re-check the divisor');

  step('Required-field population check');
  final missing = <String>[];
  if (q.lastTradedPrice == 0) missing.add('LTP');
  if (q.volumeTradedToday == 0) missing.add('volume');
  if (q.openInterest == 0) missing.add('open interest');
  if (q.buy.isEmpty && q.sell.isEmpty) missing.add('best-five (both sides)');
  if (missing.isEmpty) {
    pass('Every required field is populated');
  } else {
    info('Zero/empty: ${missing.join(", ")}');
    info('On a liquid near-ATM strike during market hours this suggests a bad');
    info('offset. On an illiquid strike it can be legitimate — re-run against a');
    info('more liquid token before editing §3.4.');
  }

  await ws.close();
  heading('STEP 6 COMPLETE');
  exit(0);
}

/// Nearest expiry, middle strike — a reasonable proxy for ATM without needing a
/// live spot price.
String _nearAtmToken(List<Map<String, dynamic>> contracts) {
  final ce = contracts.where((c) => (c['symbol'] as String).endsWith('CE')).toList()
    ..sort((a, b) => double.parse(a['strike'] as String)
        .compareTo(double.parse(b['strike'] as String)));
  return ce[ce.length ~/ 2]['token'] as String;
}
