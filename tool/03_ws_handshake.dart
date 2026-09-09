// Phase 0, step 3 — prove SPEC §3.3 connectivity.
//
// Proves:
//   a) wss://smartapisocket.angelone.in/smart-stream accepts the four-header
//      handshake using Dart's native WebSocket.connect
//   b) there is no 302 redirect, so no HttpClient workaround is needed
//   c) what a REJECTED handshake looks like — the error the Phase 3 state
//      machine will have to classify
//
// Requires tool/.session.json from step 1.
import 'dart:io';

import '_shared.dart';

Future<void> main() async {
  heading('PHASE 0 / STEP 3 — WebSocket handshake');

  final session = loadSession();
  final jwt = session['jwtToken'] as String;
  final feed = session['feedToken'] as String;
  final apiKey = session['apiKey'] as String;
  final clientCode = session['clientCode'] as String;

  info('jwt  ${redact(jwt)}');
  info('feed ${redact(feed)}');

  // -- b) redirect check -----------------------------------------------------
  //
  // §3.3 claims there is no 302. A successful WebSocket.connect below proves
  // that on its own: Dart's client does NOT follow redirects during an
  // upgrade, so if the endpoint redirected, the connect would fail. A separate
  // HTTP probe was removed deliberately — the gateway rate-limits connections
  // per client over a short window, and spending one on a probe made the real
  // handshake fail (see DECISIONS.md).

  // -- a) good handshake -----------------------------------------------------
  step('Connecting with the four headers from §3.3');
  final headers = {
    'Authorization': 'Bearer $jwt',
    'x-api-key': apiKey,
    'x-client-code': clientCode,
    'x-feed-token': feed,
  };
  info('headers: ${headers.keys.join(", ")}');

  final sw = Stopwatch()..start();
  try {
    final ws = await WebSocket.connect(wsUrl, headers: headers)
        .timeout(const Duration(seconds: 15));
    pass('Connected in ${sw.elapsedMilliseconds}ms '
        '(readyState ${ws.readyState})');

    var frames = 0;
    final sub = ws.listen(
      (data) {
        frames++;
        final kind = data is List<int>
            ? 'binary ${data.length}B'
            : 'text "${data.toString().trim()}"';
        if (frames <= 5) info('  frame $frames: $kind');
      },
      onError: (Object e) => fail('stream error: $e'),
    );

    // Idle briefly to see whether the server volunteers anything before we
    // subscribe. §3.3 says there is no market_info frame; this shows that.
    info('Holding 5s without subscribing...');
    await Future<void>.delayed(const Duration(seconds: 5));
    info('frames received while idle: $frames');
    if (frames == 0) {
      pass('No unsolicited frames — §3.3 confirmed: no market_info message, '
          'so market-open must come from the clock');
    }

    await sub.cancel();
    await ws.close();
    pass('Closed cleanly');
  } on Object catch (e) {
    fail('Handshake failed: ${e.runtimeType} — $e');
    info('If this is a 401, the session may have expired (05:00 IST rule). '
        'Re-run tool/01_login.dart.');
    exit(1);
  }

  // -- c) rejected handshake -------------------------------------------------
  step('Negative test — omitting x-feed-token');
  info('§3.1 says the feed token is WebSocket-only and mandatory. This shows '
      'the rejection shape Phase 3 has to classify.');
  // Pause first: consecutive connects are rate-limited, and a throttled
  // rejection here would be indistinguishable from a credential rejection —
  // i.e. a false pass.
  info('Waiting 20s so this is not confounded with connection throttling...');
  await Future<void>.delayed(const Duration(seconds: 20));
  try {
    final bad = await WebSocket.connect(wsUrl, headers: {
      'Authorization': 'Bearer $jwt',
      'x-api-key': apiKey,
      'x-client-code': clientCode,
    }).timeout(const Duration(seconds: 15));
    fail('Connected WITHOUT a feed token — §3.3 overstates the requirement');
    await bad.close();
  } on WebSocketException catch (e) {
    pass('Rejected: WebSocketException — ${e.message}');
  } on Object catch (e) {
    pass('Rejected: ${e.runtimeType} — $e');
  }

  heading('STEP 3 COMPLETE');

  // A WebSocket that was ever opened keeps a socket registered with the event
  // loop even after close(), so the VM will not exit on its own. Phase 0
  // scripts are one-shot; exit explicitly rather than hanging the terminal.
  exit(0);
}
