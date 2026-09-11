import 'dart:async';

/// Emits the most recent value on a fixed schedule (§5.7).
///
/// **Conflate, do not debounce.** A debounce waits for a quiet gap, and under
/// a live feed that gap never arrives — the screen would appear frozen during
/// exactly the bursts a trader cares about most. Conflation instead bounds the
/// *render rate* while keeping the displayed value never more than one
/// interval stale.
///
/// **Lossless here specifically**, and the qualifier is the interesting part:
/// every SNAP_QUOTE packet is a complete snapshot rather than a delta, so the
/// newest value contains everything a dropped one did. An app building candles
/// or VWAP would have to process every tick and conflate only at the render
/// boundary — the difference between a safe optimisation and silent data loss.
///
/// A standalone transformer rather than a method, so the live path, the replay
/// path and the repository all share one implementation. A demo that rendered
/// differently from production would be demonstrating the wrong thing.
Stream<T> conflate<T>(
  Stream<T> source, {
  Duration interval = const Duration(milliseconds: 100),
  void Function(void Function() callback)? onDispose,
}) {
  late final StreamController<T> controller;
  StreamSubscription<T>? subscription;
  Timer? timer;
  T? latest;
  var hasPending = false;

  void emitPending() {
    if (!hasPending || controller.isClosed) return;
    hasPending = false;
    controller.add(latest as T);
  }

  void start() {
    var isFirst = true;
    subscription = source.listen(
      (value) {
        // Every value is ingested and the newest always wins. Nothing queues,
        // so a burst cannot build a backlog to work through after it ends.
        latest = value;
        hasPending = true;

        // The first value goes out immediately rather than waiting out an
        // interval: on opening a screen, a 100 ms blank reads as "still
        // loading" rather than "live", and there is nothing to conflate when
        // only one value has arrived.
        if (isFirst) {
          isFirst = false;
          emitPending();
        }
      },
      onError: controller.addError,
      onDone: () {
        emitPending();
        unawaited(controller.close());
      },
      cancelOnError: false,
    );

    timer = Timer.periodic(interval, (_) => emitPending());
  }

  Future<void> stop() async {
    timer?.cancel();
    timer = null;
    final current = subscription;
    subscription = null;
    await current?.cancel();
  }

  controller = StreamController<T>(
    onListen: start,
    onCancel: stop,
  );

  // Lets a provider tear the timer down even if nothing cancelled the stream,
  // so a closed screen never leaves a periodic timer running behind it.
  onDispose?.call(() => unawaited(stop()));

  return controller.stream;
}
