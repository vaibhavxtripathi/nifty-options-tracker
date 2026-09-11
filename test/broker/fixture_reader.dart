import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Reads the recorded-session container written by `tool/07_record.dart`.
///
/// Format (little-endian), which nothing in the spec pins down:
///
/// ```
/// file   := header record*
/// header := magic "ANGLFEED" (8B) | version uint16 | reserved uint16
/// record := epochMillis int64 | length uint32 | payload[length]
/// ```
///
/// Shared by the decoder tests and the replay connection so there is exactly
/// one implementation of the container format. A second reader would be a
/// second chance to misread it.
final class RecordedFrame {
  const RecordedFrame({required this.arrivedAt, required this.payload});

  final DateTime arrivedAt;
  final Uint8List payload;
}

const String _magic = 'ANGLFEED';
const int _headerLength = 12;
const int _recordHeaderLength = 12;

/// Parses a recorded session.
///
/// Throws [FormatException] on a bad magic or a truncated record rather than
/// returning what it managed to read — a half-read fixture would make a test
/// pass against less data than it claims to cover.
List<RecordedFrame> readRecordedSession(Uint8List bytes) {
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

/// The committed live capture: 141 SNAP_QUOTE packets over 180s, recorded
/// 2026-09-11 during market hours.
List<RecordedFrame> loadFeedSessionFixture() => readRecordedSession(
  File('test/fixtures/feed_session.bin').readAsBytesSync(),
);
