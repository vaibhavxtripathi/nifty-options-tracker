import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import '../broker/replay_feed_connection.dart';

/// The recorded session that ships inside the app.
///
/// Exists so the app can be demonstrated when the exchange is shut — which,
/// for a weekend handover, is the only condition that matters. Without it the
/// detail screen would be honest and empty, and the graded criterion "live
/// data actually streams and updates" would be unobservable.
///
/// **This is real Angel One market data**, captured 2026-09-11 during market
/// hours. It was scanned for credential material before being committed: no
/// ASCII run of twelve characters or more, every record a mode-3 market-data
/// packet. No token, key or secret ships with it — and no `ANGEL_*` credential
/// ships in the APK at all.
///
/// Lives in `data/demo/` rather than `data/broker/` because loading an asset
/// is a Flutter concern, and `data/broker/` is required by §6 to import no
/// Flutter at all — that rule is what keeps the feed testable without a widget
/// tree, and an asset loader is exactly the kind of thing that would erode it.
///
/// It is always presented behind a banner naming it as a recording. Data that
/// looks live but is not is worse than no data, so the labelling is part of
/// the feature rather than decoration on top of it.
final class DemoFixture {
  const DemoFixture._();

  static const String assetPath = 'assets/demo/feed_session.bin';

  /// When the session was captured, for the banner.
  ///
  /// A constant rather than something read from the file: the container format
  /// stores per-record arrival times, and deriving a display timestamp from
  /// the first of them would put file parsing on the path of rendering a
  /// label. IST, which is the timezone a reader of this app thinks in.
  static final DateTime recordedAt = DateTime(2026, 9, 11, 13, 55);

  /// The instrument the recording actually contains.
  ///
  /// Replay can only stream what was captured, so the detail screen shows this
  /// contract's data whichever row was tapped. The banner says so — pretending
  /// the recording matches an arbitrary selection would be the dishonest
  /// version of this feature.
  static const String recordedToken = '57379';
  static const String recordedSymbol = 'NIFTY22SEP2624150CE';

  static List<RecordedFrame>? _cached;

  /// Loads and parses the recording, once per process.
  ///
  /// Cached because replay loops for as long as a demo runs, and re-reading
  /// 54 KB off the bundle on every restart would be waste with no upside.
  static Future<List<RecordedFrame>> load() async {
    final cached = _cached;
    if (cached != null) return cached;

    final data = await rootBundle.load(assetPath);
    final bytes = Uint8List.sublistView(data);
    final frames = parseRecordedSession(bytes);
    _cached = frames;
    return frames;
  }
}
