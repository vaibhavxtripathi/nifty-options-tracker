/// **Pure** `Uint8List` → `MarketTick`. No I/O, no state, no Flutter import.
///
/// The highest-risk file in the project, and worth saying why: Upstox would
/// have sent Protobuf and `protoc` would have written this for us. Angel One
/// sends raw little-endian bytes at fixed offsets, so every field is a
/// hand-written read and **every offset is a chance to be silently wrong**. A
/// wrong offset does not throw — it produces a plausible-looking number that
/// poisons everything downstream.
///
/// Two things defend against that. The offsets below are named constants
/// carrying the §3.4 table, because a bare `getInt64(115)` is unreviewable at
/// a glance. And the tests decode a **real recorded fixture** rather than
/// packets this file's author invented, so a misunderstanding cannot be
/// encoded identically into both the decoder and its test.
///
/// This boundary does all five §5.5 jobs exactly once:
///   1. validate length **before** reading — never read past the end
///   2. integer paise → rupee double, for **prices only**
///   3. byte offsets → domain field names
///   4. best-five scanned **by flag**, not by position
///   5. `close == 0` → null percent change (handled on the entity)
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../domain/entities/book_level.dart';
import '../../domain/entities/market_tick.dart';

/// §3.4 byte offsets. The table is reproduced here rather than linked because
/// this is where a reviewer needs it.
///
/// | Offset  | Type    | Field                  |
/// |---------|---------|------------------------|
/// | 0–1     | uint8   | subscription mode      |
/// | 1–2     | uint8   | exchange type          |
/// | 2–27    | utf8    | token (null-padded)    |
/// | 27–35   | int64   | sequence number        |
/// | 35–43   | int64   | exchange timestamp ms  |
/// | 43–51   | int64   | last traded price      |
/// | 51–59   | int64   | last traded quantity   |
/// | 59–67   | int64   | average traded price   |
/// | 67–75   | int64   | volume traded today    |
/// | 75–83   | float64 | total buy quantity     |
/// | 83–91   | float64 | total sell quantity    |
/// | 91–99   | int64   | open                   |
/// | 99–107  | int64   | high                   |
/// | 107–115 | int64   | low                    |
/// | 115–123 | int64   | close (previous close) |
/// | 123–131 | int64   | last traded timestamp  |
/// | 131–139 | int64   | open interest          |
/// | 139–147 | int64   | OI change %            |
/// | 147–347 | —       | best five, 10 × 20B    |
/// | 347–355 | int64   | upper circuit          |
/// | 355–363 | int64   | lower circuit          |
/// | 363–371 | int64   | 52-week high           |
/// | 371–379 | int64   | 52-week low            |
final class _Offsets {
  const _Offsets._();

  static const int mode = 0;
  static const int token = 2;
  static const int tokenLength = 25;
  // Offsets 1 (exchange type) and 27 (sequence number) are deliberately
  // absent: both are in the table above for reference, but nothing in the
  // domain model needs them, and an unused constant is one more thing that
  // can silently drift out of step with the wire format.
  static const int exchangeTimestamp = 35;
  static const int lastTradedPrice = 43;
  static const int lastTradedQuantity = 51;
  static const int averageTradedPrice = 59;
  static const int volume = 67;
  static const int totalBuyQuantity = 75;
  static const int totalSellQuantity = 83;
  static const int open = 91;
  static const int high = 99;
  static const int low = 107;
  static const int close = 115;
  static const int openInterest = 131;
  static const int openInterestChangePercent = 139;
  static const int bestFive = 147;
  static const int upperCircuit = 347;
  static const int lowerCircuit = 355;
  static const int fiftyTwoWeekHigh = 363;
  static const int fiftyTwoWeekLow = 371;
}

/// §3.4: 10 entries of 20 bytes from offset 147. Entries are *nominally* 0–4
/// buy and 5–9 sell, but the flag is authoritative — see [_readBestFive].
const int _bestFiveEntries = 10;
const int _bestFiveEntrySize = 20;

const int _entryFlagOffset = 0;
const int _entryQuantityOffset = 2;
const int _entryPriceOffset = 10;
const int _entryOrderCountOffset = 18;

const int _buyFlag = 1;

/// A SNAP_QUOTE packet is exactly this long (§3.4, confirmed live in Phase 0).
const int snapQuotePacketLength = 379;

/// Mode 3. A packet in any other mode is not what we subscribed for.
const int snapQuoteMode = 3;

/// §3.5 trap 1: prices are integer paise. Quantities, volume and open interest
/// are **not** scaled — that asymmetry is the single easiest way to ship a
/// silently wrong app, so the divisor is applied per-field and never in bulk.
const double _paisePerRupee = 100;

/// Thrown when bytes cannot be a SNAP_QUOTE packet.
///
/// A distinct type so the connection layer can count malformed frames without
/// catching unrelated errors — and so a short packet is a *rejection* rather
/// than a read past the end of the buffer (§3.5 trap 7).
final class TickDecodeException implements Exception {
  const TickDecodeException(this.message);

  final String message;

  @override
  String toString() => 'TickDecodeException($message)';
}

/// Decodes one SNAP_QUOTE packet.
///
/// Throws [TickDecodeException] if [bytes] is too short or is not mode 3.
/// **Length is validated before any read**, because `ByteData` would otherwise
/// throw a `RangeError` partway through — and a half-decoded tick carrying
/// three valid fields is more dangerous than a rejected one.
MarketTick decodeSnapQuote(Uint8List bytes) {
  if (bytes.length < snapQuotePacketLength) {
    throw TickDecodeException(
      'Packet is ${bytes.length} bytes; SNAP_QUOTE is $snapQuotePacketLength',
    );
  }

  final data = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);

  final mode = data.getUint8(_Offsets.mode);
  if (mode != snapQuoteMode) {
    throw TickDecodeException('Mode $mode is not SNAP_QUOTE ($snapQuoteMode)');
  }

  final book = _readBestFive(data);

  return MarketTick(
    token: _readToken(bytes),
    lastTradedPrice: _rupees(data, _Offsets.lastTradedPrice),
    previousClose: _rupees(data, _Offsets.close),
    volume: data.getInt64(_Offsets.volume, Endian.little),
    openInterest: data.getInt64(_Offsets.openInterest, Endian.little),
    exchangeTimestamp: DateTime.fromMillisecondsSinceEpoch(
      data.getInt64(_Offsets.exchangeTimestamp, Endian.little),
    ),
    bestBid: book.bid,
    bestAsk: book.ask,
    open: _rupees(data, _Offsets.open),
    high: _rupees(data, _Offsets.high),
    low: _rupees(data, _Offsets.low),
    lastTradedQuantity: data.getInt64(
      _Offsets.lastTradedQuantity,
      Endian.little,
    ),
    averageTradedPrice: _rupees(data, _Offsets.averageTradedPrice),
    // Already a float64, and a quantity: neither read as an int nor scaled.
    totalBuyQuantity: data.getFloat64(_Offsets.totalBuyQuantity, Endian.little),
    totalSellQuantity: data.getFloat64(
      _Offsets.totalSellQuantity,
      Endian.little,
    ),
    // A percentage, not a price: no ÷100.
    openInterestChangePercent: data
        .getInt64(_Offsets.openInterestChangePercent, Endian.little)
        .toDouble(),
    upperCircuit: _rupees(data, _Offsets.upperCircuit),
    lowerCircuit: _rupees(data, _Offsets.lowerCircuit),
    fiftyTwoWeekHigh: _rupees(data, _Offsets.fiftyTwoWeekHigh),
    fiftyTwoWeekLow: _rupees(data, _Offsets.fiftyTwoWeekLow),
  );
}

/// Whether [bytes] could be a SNAP_QUOTE packet at all.
///
/// Lets the connection layer discard a frame without a try/catch on the hot
/// path.
bool looksLikeSnapQuote(Uint8List bytes) =>
    bytes.length >= snapQuotePacketLength &&
    bytes[_Offsets.mode] == snapQuoteMode;

/// The 25-byte null-padded token field.
///
/// Trailing NULs are padding, not content — decoding the whole field yields a
/// string with embedded zeros that compares equal to nothing.
String _readToken(Uint8List bytes) {
  final field = bytes.sublist(
    _Offsets.token,
    _Offsets.token + _Offsets.tokenLength,
  );
  final end = field.indexOf(0);
  return utf8.decode(
    end == -1 ? field : field.sublist(0, end),
    allowMalformed: true,
  );
}

double _rupees(ByteData data, int offset) =>
    data.getInt64(offset, Endian.little) / _paisePerRupee;

/// Best bid and best ask, **scanned by flag rather than by position**.
///
/// §3.4 says entries 0–4 are buy and 5–9 are sell, and in every packet Phase 0
/// recorded that held. Trusting it anyway would mean reading the layout
/// instead of the data: the flag is what the protocol defines as
/// authoritative, and an illiquid strike is both where a surprising layout
/// would show up and the case nobody checks by hand.
///
/// A zero price means no resting order, so that level is absent rather than
/// free. Returning null for an empty side is §3.5 trap 5 — never assume an
/// entry exists on either side.
({BookLevel? bid, BookLevel? ask}) _readBestFive(ByteData data) {
  BookLevel? bid;
  BookLevel? ask;

  for (var i = 0; i < _bestFiveEntries; i++) {
    final base = _Offsets.bestFive + i * _bestFiveEntrySize;

    final price =
        data.getInt64(base + _entryPriceOffset, Endian.little) / _paisePerRupee;
    if (price == 0) continue;

    final level = BookLevel(
      price: price,
      quantity: data.getInt64(base + _entryQuantityOffset, Endian.little),
      orderCount: data.getUint16(base + _entryOrderCountOffset, Endian.little),
    );

    final isBuy =
        data.getUint16(base + _entryFlagOffset, Endian.little) == _buyFlag;

    // Best bid is the highest buy; best ask is the lowest sell. Taking the
    // first entry on each side would rely on the server's ordering, which is
    // the same assumption the flag scan exists to avoid.
    if (isBuy) {
      if (bid == null || price > bid.price) bid = level;
    } else {
      if (ask == null || price < ask.price) ask = level;
    }
  }

  return (bid: bid, ask: ask);
}
