// Phase 0, step 4 — prove SPEC §3.3 / trap 8: the 10-second ping is mandatory.
//
// Two runs, side by side:
//   A: subscribe, send NO ping, hold 240s  -> expect death on idle timeout
//   B: subscribe, ping every 10s, hold 180s -> expect survival
//
// Death is detected by the close/error event and by a failed write, NOT by
// tick silence — outside market hours a healthy socket is also silent, and
// conflating the two would make this test meaningless after 15:30 IST.
//
// Requires tool/.session.json from step 1.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '_shared.dart';

/// Outcome of holding one connection open.
typedef HoldResult = ({
  bool died,
  int? diedAfterSeconds,
  int frames,
  String? reason,
});

Future<HoldResult> hold({
  required String label,
  required Duration duration,
  required bool sendPings,
  required Map<String, String> headers,
  required String token,
}) async {
  step('$label — ${duration.inSeconds}s, pings ${sendPings ? "ON" : "OFF"}');

  final started = DateTime.now();
  final ws = await WebSocket.connect(wsUrl, headers: headers)
      .timeout(const Duration(seconds: 15));

  var frames = 0;
  var died = false;
  int? diedAt;
  String? reason;
  final finished = Completer<void>();

  void markDead(String why) {
    if (died) return;
    died = true;
    diedAt = DateTime.now().difference(started).inSeconds;
    reason = why;
    info('  [t+${diedAt}s] SOCKET DIED — $why');
    if (!finished.isCompleted) finished.complete();
  }

  ws.listen(
    (data) {
      frames++;
      if (frames <= 3) {
        info('  [t+${DateTime.now().difference(started).inSeconds}s] '
            'frame $frames: ${data is List<int> ? "${data.length}B binary" : data}');
      }
    },
    onError: (Object e) => markDead('stream error: $e'),
    onDone: () => markDead('closed by server '
        '(code ${ws.closeCode}, reason "${ws.closeReason ?? ""}")'),
    cancelOnError: false,
  );

  // Subscribe so the connection is doing real work, not merely open.
  ws.add(jsonEncode({
    'correlationID': 'phase0_${label.toLowerCase().replaceAll(" ", "_")}',
    'action': 1,
    'params': {
      'mode': 3,
      'tokenList': [
        {'exchangeType': 2, 'tokens': [token]},
      ],
    },
  }));
  info('  subscribed to token $token in SNAP_QUOTE mode');

  Timer? pinger;
  if (sendPings) {
    pinger = Timer.periodic(const Duration(seconds: 10), (_) {
      if (died) return;
      try {
        ws.add('ping');
        info('  [t+${DateTime.now().difference(started).inSeconds}s] -> ping');
      } on Object catch (e) {
        markDead('write failed: $e');
      }
    });
  }

  // A periodic no-op write is NOT used on the no-ping arm; that would defeat
  // the experiment. Instead we simply wait for the timeout or for death.
  final timeout = Timer(duration, () {
    if (!finished.isCompleted) finished.complete();
  });

  // Heartbeat log so a long silent hold is visibly progressing.
  final ticker = Timer.periodic(const Duration(seconds: 15), (_) {
    if (!died) {
      info('  [t+${DateTime.now().difference(started).inSeconds}s] '
          'still open, $frames frames, readyState ${ws.readyState}');
    }
  });

  await finished.future;
  // The close frame can arrive in the same tick the hold window expires. Yield
  // briefly so a death that already happened is recorded before we score it.
  await Future<void>.delayed(const Duration(milliseconds: 750));
  pinger?.cancel();
  timeout.cancel();
  ticker.cancel();
  if (!died) await ws.close();

  return (died: died, diedAfterSeconds: diedAt, frames: frames, reason: reason);
}

Future<void> main() async {
  heading('PHASE 0 / STEP 4 — is the 10-second ping mandatory?');

  final open = marketIsOpen();
  info('IST now: ${nowIst()}  |  market ${open ? "OPEN" : "CLOSED"}');
  if (!open) {
    info('');
    info('Outside market hours there are no ticks, so this run proves the');
    info('CONNECTION-level result only: whether the server closes an unpinged');
    info('socket. That is the claim in §3.3, and it is testable now. Re-run');
    info('in-window to also confirm ticks keep flowing on the pinged arm.');
  }

  final session = loadSession();
  final headers = {
    'Authorization': 'Bearer ${session["jwtToken"]}',
    'x-api-key': session['apiKey'] as String,
    'x-client-code': session['clientCode'] as String,
    'x-feed-token': session['feedToken'] as String,
  };

  // A liquid near-ATM token from step 2's fixture. Overridable if the fixture
  // has aged out.
  const token = '47163';

  // 240s, not 120s. The first run of this script used 120s and the server's
  // "Connection Idle Timeout" close arrived at almost exactly t+120s — the
  // hold window expired in the same tick, so the arm was scored as "survived"
  // when it had in fact just died. Give the timeout room to land well inside
  // the window; hold() returns early the moment death is observed, so a
  // generous ceiling costs nothing when the socket does die.
  final a = await hold(
    label: 'ARM A no ping',
    duration: const Duration(seconds: 240),
    sendPings: false,
    headers: headers,
    token: token,
  );

  info('');
  info('Cooling down 5s between arms...');
  await Future<void>.delayed(const Duration(seconds: 5));

  final b = await hold(
    label: 'ARM B with ping',
    duration: const Duration(seconds: 180),
    sendPings: true,
    headers: headers,
    token: token,
  );

  heading('RESULT');
  info('ARM A (no ping)   : ${a.died ? "died at t+${a.diedAfterSeconds}s — ${a.reason}" : "survived 240s"}, ${a.frames} frames');
  info('ARM B (with ping) : ${b.died ? "died at t+${b.diedAfterSeconds}s — ${b.reason}" : "survived 180s"}, ${b.frames} frames');
  info('');
  info('Note: the server answers each "ping" with a text "pong". Phase 3 can');
  info('use a missing pong as a liveness signal, not just the close event.');
  info('');

  if (a.died && !b.died) {
    pass('§3.3 CONFIRMED: the unpinged socket dies, the pinged one survives.');
    info('The 10s ping is mandatory. Phase 3 must implement it in the '
        'connection state machine, not as an afterthought.');
  } else if (!a.died && !b.died) {
    fail('Both arms survived — the ping may not be strictly required, OR the '
        'idle timeout is longer than 240s.');
    info('Re-run ARM A with a longer duration before editing §3.3.');
  } else if (a.died && b.died) {
    fail('BOTH died. The ping alone is not sufficient — investigate before '
        'trusting §3.3.');
  } else {
    fail('Unexpected: the pinged arm died while the unpinged one lived.');
  }

  heading('STEP 4 COMPLETE');

  // Opened sockets keep the event loop alive; exit rather than hang.
  exit(0);
}
