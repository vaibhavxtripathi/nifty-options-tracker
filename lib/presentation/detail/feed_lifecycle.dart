import 'dart:async';

import 'package:flutter/widgets.dart';

/// Disconnects the feed while the app is backgrounded, and reconnects on
/// resume (§5.4).
///
/// Two reasons this is not optional. Streaming to a screen nobody is looking
/// at burns the user's data and battery for nothing. And the OS will suspend
/// the process unpredictably anyway — so without this, the socket dies on the
/// platform's schedule rather than ours, and comes back as a mystery
/// disconnect the reconnect logic has to clean up.
///
/// Doing it deliberately means the teardown is ordered and the reconnect is a
/// known path rather than an error path.
final class FeedLifecycle {
  FeedLifecycle({required this.onPause, required this.onResume}) {
    _listener = AppLifecycleListener(
      onPause: _handlePause,
      onResume: _handleResume,
      // `onHide` and `onInactive` also fire for transient interruptions — a
      // notification shade pull, an incoming call overlay — which are far too
      // frequent to tear a socket down for. Only a real pause counts.
    );
  }

  final FutureOr<void> Function() onPause;
  final FutureOr<void> Function() onResume;

  late final AppLifecycleListener _listener;

  /// Whether the feed is currently stopped because the app is in the
  /// background, as opposed to stopped for any other reason.
  bool get isPaused => _paused;
  bool _paused = false;

  void _handlePause() {
    if (_paused) return;
    _paused = true;
    unawaited(Future.sync(onPause));
  }

  void _handleResume() {
    if (!_paused) return;
    _paused = false;
    unawaited(Future.sync(onResume));
  }

  void dispose() => _listener.dispose();
}
