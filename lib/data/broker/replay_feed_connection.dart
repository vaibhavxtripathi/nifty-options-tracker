import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../domain/entities/market_tick.dart';
import 'tick_decoder.dart';

/// Replays a recorded session as if it were live.
///
/// This is what makes the app demonstrable outside market hours, and it is the
/// reason Phase 0 step 7 existed at all: the detail screen in Phase 4 can be
/// built, shown and recorded at midnight against real exchange data rather
/// than against numbers someone made up.
///
/// **Timing is preserved, not synthesised.** Each frame is re-emitted after
/// the gap that actually separated it from the one before, so bursts arrive as
/// bursts and quiet stretches stay quiet. A fixed-interval replay would be a
/// different thing entirely — it would make conflation look effective when it
/// had never been tested against a real burst.
final class ReplayFeedConnection {
  ReplayFeedConnection({
    required this.frames,
    this.speed = 1.0,
    this.loop = false,
  }) {
    if (speed <= 0) {
      throw ArgumentError.value(speed, 'speed', 'must be positive');
    }
  }

  /// Reads a container written by `tool/07_record.dart`.
  factory ReplayFeedConnection.fromBytes(
    Uint8List bytes, {
    double speed = 1.0,
    bool loop = false,
  }) => ReplayFeedConnection(
    frames: parseRecordedSession(bytes),
    speed: speed,
    loop: loop,
  );

  /// The recorded session, in arrival order.
  final List<RecordedFrame> frames;

  /// Wall-clock multiplier. 2.0 replays twice as fast, which is useful for a
  /// demo but is deliberately not the default — the honest thing to show is
  /// the rate the market actually produced.
  final double speed;

  /// Restart from the beginning on reaching the end, so a demo recording does
  /// not stop mid-take.
  final bool loop;

  StreamController<MarketTick>? _controller;
  Timer? _timer;
  var _index = 0;
  var _stopped = false;

  /// Ticks, emitted with the original inter-arrival timing.
  Stream<MarketTick> get ticks {
    final controller = _controller ??= StreamController<MarketTick>.broadcast(
      onListen: _start,
      onCancel: stop,
    );
    return controller.stream;
  }

  int get frameCount => frames.length;

  /// The wall-clock span the recording covers.
  Duration get duration => frames.length < 2
      ? Duration.zero
      : frames.last.arrivedAt.difference(frames.first.arrivedAt);

  void _start() {
    _stopped = false;
    _index = 0;
    _scheduleNext(Duration.zero);
  }

  void _scheduleNext(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, _emitNext);
  }

  void _emitNext() {
    if (_stopped) return;
    final controller = _controller;
    if (controller == null || controller.isClosed) return;

    if (_index >= frames.length) {
      if (loop) {
        _index = 0;
      } else {
        unawaited(controller.close());
        return;
      }
    }

    final frame = frames[_index];
    if (looksLikeSnapQuote(frame.payload)) {
      try {
        controller.add(decodeSnapQuote(frame.payload));
      } on TickDecodeException {
        // A recorded frame that will not decode is a fixture problem, not a
        // runtime one. Skipping keeps a replay usable rather than aborting it.
      }
    }

    final previous = frame;
    _index++;
    if (_index >= frames.length && !loop) {
      unawaited(controller.close());
      return;
    }

    final next = frames[_index % frames.length];
    // Looping wraps to a negative gap; restart immediately instead.
    final gap = next.arrivedAt.difference(previous.arrivedAt);
    final scaled = gap.isNegative
        ? Duration.zero
        : Duration(
            microseconds: (gap.inMicroseconds / speed).round(),
          );
    _scheduleNext(scaled);
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> dispose() async {
    stop();
    final controller = _controller;
    _controller = null;
    if (controller != null && !controller.isClosed) await controller.close();
  }
}

/// One recorded frame: the payload and when it arrived.
final class RecordedFrame {
  const RecordedFrame({required this.arrivedAt, required this.payload});

  final DateTime arrivedAt;
  final Uint8List payload;
}

const String _magic = 'ANGLFEED';
const int _headerLength = 12;
const int _recordHeaderLength = 12;

/// Parses the container written by `tool/07_record.dart`.
///
/// ```
/// file   := header record*
/// header := magic "ANGLFEED" (8B) | version uint16 | reserved uint16
/// record := epochMillis int64 | length uint32 | payload[length]
/// ```
///
/// Nothing in the SmartAPI spec defines a recording format, so this one is
/// ours: fixed-width headers, no framing ambiguity, and a magic that makes a
/// truncated or unrelated file fail loudly rather than decode into noise.
List<RecordedFrame> parseRecordedSession(Uint8List bytes) {
  if (bytes.length < _headerLength) {
    throw const FormatException('File is shorter than its header');
  }

  final magic = ascii.decode(bytes.sublist(0, 8), allowInvalid: true);
  if (magic != _magic) {
    throw FormatException('Bad magic "$magic"; expected "$_magic"');
  }

  final frames = <RecordedFrame>[];
  var offset = _headerLength;

  while (offset + _recordHeaderLength <= bytes.length) {
    final header = ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes + offset,
      _recordHeaderLength,
    );
    final millis = header.getInt64(0, Endian.little);
    final length = header.getUint32(8, Endian.little);
    offset += _recordHeaderLength;

    if (offset + length > bytes.length) {
      // Refuse a partial read rather than returning what was recoverable: a
      // half-read fixture would let a test claim coverage it does not have.
      throw FormatException('Truncated record at offset $offset');
    }

    frames.add(
      RecordedFrame(
        arrivedAt: DateTime.fromMillisecondsSinceEpoch(millis),
        payload: Uint8List.sublistView(bytes, offset, offset + length),
      ),
    );
    offset += length;
  }

  return frames;
}
