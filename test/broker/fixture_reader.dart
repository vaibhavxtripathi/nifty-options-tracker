import 'dart:io';
import 'dart:typed_data';

import 'package:nifty_options_tracker/data/broker/replay_feed_connection.dart';

/// Loads the committed live capture: 141 SNAP_QUOTE packets over 180s,
/// recorded 2026-09-11 during market hours.
///
/// Deliberately a thin wrapper over the **shipped** parser rather than a
/// second implementation of the container format. A test-only reader would be
/// a second chance to misread the file, and the two could agree with each
/// other while both being wrong about what `tool/07_record.dart` wrote.
List<RecordedFrame> loadFeedSessionFixture() => parseRecordedSession(
  File('test/fixtures/feed_session.bin').readAsBytesSync(),
);

/// The raw fixture bytes, for tests that need to corrupt them deliberately.
Uint8List loadFixtureBytes() =>
    File('test/fixtures/feed_session.bin').readAsBytesSync();
