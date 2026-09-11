@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nifty_options_tracker/data/broker/tick_decoder.dart';
import 'package:nifty_options_tracker/domain/entities/book_level.dart';

import 'fixture_reader.dart';

/// The tests that prove the hand-written byte offsets are right.
///
/// They run against `assets/demo/feed_session.bin` — 141 real SNAP_QUOTE
/// packets captured live on 2026-09-11 during market hours. That matters more
/// than it looks: a decoder tested only against packets its own author
/// constructed proves that the author is self-consistent, not that the offsets
/// match what Angel One actually sends. The expected values below were read
/// out of the fixture with an independent script, not produced by this
/// decoder.
void main() {
  final frames = loadFeedSessionFixture();

  test('the fixture is the recording we think it is', () {
    // If this fails, every other assertion here is meaningless.
    expect(frames, hasLength(141));
    expect(
      frames.every((f) => f.payload.length == snapQuotePacketLength),
      isTrue,
    );
  });

  group('criterion 1 — the recorded fixture decodes into correct ticks', () {
    test('all 141 packets decode without throwing', () {
      for (final frame in frames) {
        expect(
          () => decodeSnapQuote(frame.payload),
          returnsNormally,
          reason: 'every recorded packet must decode',
        );
      }
    });

    test('the first packet matches its independently-read values', () {
      final tick = decodeSnapQuote(frames.first.payload);

      expect(tick.token, '57379');
      expect(tick.lastTradedPrice, 10.75);
      expect(tick.previousClose, 13.55);
      expect(tick.volume, 710190);
      expect(tick.openInterest, 335920);
      expect(tick.open, 8.15);
      expect(tick.high, 12.40);
      expect(tick.low, 8.15);
      expect(tick.upperCircuit, 121.55);
      expect(tick.lowerCircuit, 0.05);
      expect(tick.fiftyTwoWeekHigh, 483.90);
    });

    test('only the two subscribed tokens appear', () {
      final tokens = frames.map((f) => decodeSnapQuote(f.payload).token).toSet();
      expect(tokens, {'57379', '55292'});
    });

    test('the token field survives its null padding', () {
      // A 25-byte field decoded whole would carry embedded NULs and compare
      // equal to nothing, which is a bug that only shows up as "no data".
      for (final frame in frames) {
        final token = decodeSnapQuote(frame.payload).token;
        expect(token, isNotEmpty);
        expect(token.contains(String.fromCharCode(0)), isFalse);
        expect(int.tryParse(token), isNotNull);
      }
    });
  });

  group('criterion 2 — the ÷100 scaling', () {
    test('prices land in a plausible option range', () {
      // The scaling error this catches is silent. A missing divisor turns
      // ₹10.75 into ₹1,075, which is a number, not an exception.
      for (final frame in frames) {
        final tick = decodeSnapQuote(frame.payload);
        expect(tick.lastTradedPrice, inInclusiveRange(0, 1000));
      }
      final prices = frames
          .map((f) => decodeSnapQuote(f.payload).lastTradedPrice)
          .toList();
      expect(prices.reduce((a, b) => a < b ? a : b), 0.60);
      expect(prices.reduce((a, b) => a > b ? a : b), 12.15);
    });

    test('the book corroborates the LTP, which a wrong divisor could not', () {
      // The real proof that the divisor is right: the price offsets agree with
      // each other. LTP sits inside the day range and next to the book, and no
      // single wrong divisor could produce that coincidence across offsets
      // 43, 91-115 and 147+.
      final tick = decodeSnapQuote(frames.first.payload);
      expect(tick.lastTradedPrice, inInclusiveRange(tick.low, tick.high));
      expect(tick.bestBid!.price, closeTo(tick.lastTradedPrice, 0.5));
      expect(tick.bestAsk!.price, closeTo(tick.lastTradedPrice, 0.5));
    });

    test('quantities are NOT scaled', () {
      // §3.5 trap 1: the divisor applies to prices only. Volume in the
      // hundreds of thousands is the tell — ÷100 would render it as 7,101.
      final tick = decodeSnapQuote(frames.first.payload);
      expect(tick.volume, 710190);
      expect(tick.openInterest, 335920);
      expect(tick.bestBid!.quantity, 3185);
    });
  });

  group('criterion 3 — close == 0 yields a null percent change', () {
    test('a real packet with a close computes a percentage', () {
      final tick = decodeSnapQuote(frames.first.payload);
      // (10.75 - 13.55) / 13.55 * 100
      expect(tick.changePercent, closeTo(-20.66, 0.01));
    });

    test('a zero close yields null rather than Infinity or NaN', () {
      final tick = decodeSnapQuote(
        _packetWith(lastTradedPrice: 1075, close: 0),
      );
      expect(tick.previousClose, 0);
      expect(tick.changePercent, isNull);
    });

    test('the guard is the only thing preventing Infinity', () {
      // Vacuity check: without the guard this arithmetic really does produce
      // a non-finite double, so the null is doing work.
      expect(((10.75 - 0) / 0 * 100).isFinite, isFalse);
    });
  });

  group('criterion 4 — a short packet is rejected, never read past', () {
    test('a truncated packet throws instead of reading past its end', () {
      final short = Uint8List.sublistView(frames.first.payload, 0, 200);
      expect(
        () => decodeSnapQuote(short),
        throwsA(isA<TickDecodeException>()),
      );
    });

    test('an LTP-mode packet (51 bytes) is rejected', () {
      // §3.5 trap 7: packet length varies by mode, and a 51-byte LTP packet
      // arriving on a SNAP_QUOTE subscription must not be parsed as one.
      expect(
        () => decodeSnapQuote(Uint8List(51)),
        throwsA(isA<TickDecodeException>()),
      );
    });

    test('an empty payload is rejected', () {
      expect(
        () => decodeSnapQuote(Uint8List(0)),
        throwsA(isA<TickDecodeException>()),
      );
    });

    test('a full-length packet in the wrong mode is rejected', () {
      final wrongMode = Uint8List.fromList(frames.first.payload)..[0] = 1;
      expect(
        () => decodeSnapQuote(wrongMode),
        throwsA(isA<TickDecodeException>()),
      );
    });

    test('looksLikeSnapQuote screens the same cases without throwing', () {
      expect(looksLikeSnapQuote(frames.first.payload), isTrue);
      expect(looksLikeSnapQuote(Uint8List(51)), isFalse);
    });
  });

  group('criterion 5 — a one-sided book yields null on the empty side', () {
    // NOTE: this criterion is tested with synthetic packets **by necessity**.
    // Phase 0 step 7b subscribed five deep strikes (15000PE through 34500CE,
    // roughly 40% out of the money) for two minutes and every one was quoted
    // five-deep on both sides — so no fully one-sided book could be recorded
    // on the day. That is a real finding about Nifty option liquidity, not a
    // gap that was skipped; see docs/DECISIONS.md.
    test('no resting sells yields a null ask and a live bid', () {
      final tick = decodeSnapQuote(
        _packetWith(
          lastTradedPrice: 500,
          close: 500,
          buys: const [(price: 5, quantity: 75, orders: 1)],
          sells: const [],
        ),
      );

      expect(tick.bestBid, isNotNull);
      expect(tick.bestBid!.price, 0.05);
      expect(tick.bestAsk, isNull);
      expect(tick.spread, isNull, reason: 'no spread without both sides');
      expect(tick.mid, isNull);
    });

    test('no resting buys yields a null bid', () {
      final tick = decodeSnapQuote(
        _packetWith(
          lastTradedPrice: 500,
          close: 500,
          buys: const [],
          sells: const [(price: 60, quantity: 75, orders: 1)],
        ),
      );

      expect(tick.bestBid, isNull);
      expect(tick.bestAsk, isNotNull);
      expect(tick.bestAsk!.price, 0.60);
    });

    test('a completely empty book yields null on both sides', () {
      final tick = decodeSnapQuote(
        _packetWith(
          lastTradedPrice: 500,
          close: 500,
          buys: const [],
          sells: const [],
        ),
      );
      expect(tick.bestBid, isNull);
      expect(tick.bestAsk, isNull);
    });
  });

  group('the book is scanned by flag, not by position', () {
    test('the real fixture picks the best of each side', () {
      // Ground truth for the first packet: buys 10.60-10.80, sells 10.90-11.10.
      final tick = decodeSnapQuote(frames.first.payload);
      expect(tick.bestBid, const BookLevel(price: 10.80, quantity: 3185, orderCount: 9));
      expect(tick.bestAsk!.price, 10.90);
      expect(tick.spread, closeTo(0.10, 1e-9));
      expect(tick.mid, closeTo(10.85, 1e-9));
      expect(tick.bestBid!.price, lessThan(tick.bestAsk!.price));
    });

    test('a sell in a nominally-buy slot is still read as a sell', () {
      // §3.4 says slots 0-4 are buy and 5-9 are sell, and every recorded
      // packet honoured that. This asserts the decoder reads the flag anyway:
      // put the only sell in slot 0 and the only buy in slot 9.
      final tick = decodeSnapQuote(
        _packetWith(
          lastTradedPrice: 1000,
          close: 1000,
          buys: const [],
          sells: const [],
          rawEntries: const [
            (slot: 0, isBuy: false, price: 1100, quantity: 50, orders: 2),
            (slot: 9, isBuy: true, price: 900, quantity: 40, orders: 3),
          ],
        ),
      );

      expect(tick.bestAsk!.price, 11.00, reason: 'flag says sell, not slot 0');
      expect(tick.bestBid!.price, 9.00, reason: 'flag says buy, not slot 9');
    });

    test('best bid is the highest buy and best ask the lowest sell', () {
      final tick = decodeSnapQuote(
        _packetWith(
          lastTradedPrice: 1000,
          close: 1000,
          // Deliberately out of order, so "first entry" would pick wrongly.
          buys: const [
            (price: 900, quantity: 10, orders: 1),
            (price: 950, quantity: 20, orders: 2),
          ],
          sells: const [
            (price: 1200, quantity: 30, orders: 3),
            (price: 1050, quantity: 40, orders: 4),
          ],
        ),
      );

      expect(tick.bestBid!.price, 9.50);
      expect(tick.bestAsk!.price, 10.50);
    });
  });

  group('every decoded value is plausible, not merely present', () {
    // Added after a real miss. §3.4's table lists offset 139 as an int64, and
    // the decoder believed it — producing "+4581235513960227840.00%" on the
    // device. Every assertion aimed at that field had been written from the
    // same wrong premise as the decoder, so nothing caught it.
    //
    // A round-trip test cannot find an error like that. Only a *range* test
    // can: the question is not "did we read the bytes we wrote" but "could
    // this number be true of a real option".
    test('OI change is a percentage, not an astronomical integer', () {
      for (final frame in frames) {
        final tick = decodeSnapQuote(frame.payload);
        expect(
          tick.openInterestChangePercent.abs(),
          lessThan(1000),
          reason:
              'offset 139 is a float64 despite the spec saying int64; read as '
              'an int it yields ~4.6e18',
        );
      }
    });

    test('no decoded double is astronomical or non-finite', () {
      // A blanket guard over every numeric field. Any future offset error
      // large enough to matter trips this, without a hand-written assertion
      // per field.
      for (final frame in frames) {
        final tick = decodeSnapQuote(frame.payload);
        final values = <String, double>{
          'ltp': tick.lastTradedPrice,
          'close': tick.previousClose,
          'open': tick.open,
          'high': tick.high,
          'low': tick.low,
          'avg': tick.averageTradedPrice,
          'upperCircuit': tick.upperCircuit,
          'lowerCircuit': tick.lowerCircuit,
          'week52High': tick.fiftyTwoWeekHigh,
          'week52Low': tick.fiftyTwoWeekLow,
          'oiChange': tick.openInterestChangePercent,
          'totalBuy': tick.totalBuyQuantity,
          'totalSell': tick.totalSellQuantity,
        };
        values.forEach((name, value) {
          expect(value.isFinite, isTrue, reason: '\$name is not finite');
          expect(
            value.abs(),
            lessThan(1e9),
            reason: '\$name = \$value is too large to be a real market value',
          );
        });
      }
    });

    test('day OHLC is internally consistent where the contract traded', () {
      // high >= low, and the last price sits inside the day range. Three
      // offsets agreeing is far harder to fake with a wrong constant than one.
      //
      // Skipped when high == 0, which is not a decode error: an illiquid
      // strike that has not traded today reports zero OHLC while still
      // carrying an LTP from an earlier session. The recorded far-OTM call is
      // exactly that case, and asserting a range over it would be asserting
      // that every contract trades every day.
      for (final frame in frames) {
        final tick = decodeSnapQuote(frame.payload);
        expect(tick.high, greaterThanOrEqualTo(tick.low));
        if (tick.high == 0) continue;
        expect(tick.lastTradedPrice, inInclusiveRange(tick.low, tick.high));
      }
    });

    test('circuit limits bracket the traded price', () {
      for (final frame in frames) {
        final tick = decodeSnapQuote(frame.payload);
        expect(tick.upperCircuit, greaterThan(tick.lowerCircuit));
        expect(
          tick.lastTradedPrice,
          inInclusiveRange(tick.lowerCircuit, tick.upperCircuit),
        );
      }
    });
  });

  group('across the whole recording', () {
    test('every tick has a coherent book where both sides exist', () {
      for (final frame in frames) {
        final tick = decodeSnapQuote(frame.payload);
        final bid = tick.bestBid;
        final ask = tick.bestAsk;
        if (bid != null && ask != null) {
          expect(
            bid.price,
            lessThanOrEqualTo(ask.price),
            reason: 'a crossed book means the sides were mixed up',
          );
        }
      }
    });

    test('exchange timestamps are real and ordered within the session', () {
      final stamps = frames
          .map((f) => decodeSnapQuote(f.payload).exchangeTimestamp)
          .toList();
      expect(stamps.first.year, 2026);
      expect(stamps.first.month, 9);
      // Recorded over 180s, so the whole session sits inside a few minutes.
      final span = stamps.last.difference(stamps.first);
      expect(span.inMinutes, lessThan(10));
      expect(span.isNegative, isFalse);
    });

    test('the illiquid strike decodes too', () {
      final illiquid = frames
          .map((f) => decodeSnapQuote(f.payload))
          .where((t) => t.token == '55292')
          .toList();
      expect(illiquid, hasLength(1));
      expect(illiquid.single.lastTradedPrice, 0.60);
      expect(illiquid.single.previousClose, 0.65);
    });
  });
}

typedef _Level = ({int price, int quantity, int orders});
typedef _RawEntry = ({
  int slot,
  bool isBuy,
  int price,
  int quantity,
  int orders,
});

/// Builds a synthetic SNAP_QUOTE packet.
///
/// Used only for the cases the live recording could not produce: a zero
/// previous close, and a one-sided book. Prices are in **paise**, matching the
/// wire format, so the test states what the broker would send rather than what
/// the decoder should return.
Uint8List _packetWith({
  required int lastTradedPrice,
  required int close,
  List<_Level> buys = const [],
  List<_Level> sells = const [],
  List<_RawEntry> rawEntries = const [],
  String token = '57379',
}) {
  final bytes = Uint8List(snapQuotePacketLength);
  final data = ByteData.view(bytes.buffer);

  data.setUint8(0, snapQuoteMode);
  data.setUint8(1, 2);
  for (var i = 0; i < token.length; i++) {
    bytes[2 + i] = token.codeUnitAt(i);
  }
  data.setInt64(35, DateTime(2026, 9, 11, 13, 52).millisecondsSinceEpoch, Endian.little);
  data.setInt64(43, lastTradedPrice, Endian.little);
  data.setInt64(115, close, Endian.little);

  void writeEntry(int slot, bool isBuy, _Level level) {
    final base = 147 + slot * 20;
    data.setUint16(base, isBuy ? 1 : 0, Endian.little);
    data.setInt64(base + 2, level.quantity, Endian.little);
    data.setInt64(base + 10, level.price, Endian.little);
    data.setUint16(base + 18, level.orders, Endian.little);
  }

  for (var i = 0; i < buys.length && i < 5; i++) {
    writeEntry(i, true, buys[i]);
  }
  for (var i = 0; i < sells.length && i < 5; i++) {
    writeEntry(5 + i, false, sells[i]);
  }
  for (final entry in rawEntries) {
    writeEntry(entry.slot, entry.isBuy, (
      price: entry.price,
      quantity: entry.quantity,
      orders: entry.orders,
    ));
  }

  return bytes;
}
