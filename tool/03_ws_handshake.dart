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
  // Probed over https:// with the same path. A 101/4xx means the endpoint is
  // terminal; a 3xx would mean §3.3 is wrong and a redirect-following client
  // is needed.
  step('Redirect check — does the endpoint 302 anywhere?');
  final probeClient = HttpClient();
  try {
    final probe = await probeClient
        .getUrl(Uri.parse(wsUrl.replaceFirst('wss://', 'https://')));
    probe.followRedirects = false;
    final probeRes = await probe.close();
    info('HTTP ${probeRes.statusCode} on a plain GET');
    if (probeRes.isRedirect ||
        (probeRes.statusCode >= 300 && probeRes.statusCode < 400)) {
      fail('REDIRECT to ${probeRes.headers.value("location")} — §3.3 is wrong');
    } else {
      pass('No redirect; §3.3 confirmed, WebSocket.connect is sufficient');
    }
    await probeRes.drain<void>();
  } on Object catch (e) {
    info('Plain GET failed (${e.runtimeType}) — expected for a WS-only '
        'endpoint; the connect below is the real test.');
  } finally {
    probeClient.close();
  }

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
}
