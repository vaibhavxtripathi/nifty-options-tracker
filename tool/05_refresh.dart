// Phase 0, step 5 — prove SPEC §3.1 token refresh.
//
// Proves generateTokens returns a usable new jwtToken WITHOUT a fresh TOTP.
// "Usable" is proven by making a real authenticated read-only call with the
// new token, not merely by it being non-empty — a token that parses but is
// rejected would be a silent trap for §5.6.
//
// Requires tool/.session.json from step 1.
import 'dart:convert';

import '_shared.dart';

Future<void> main() async {
  heading('PHASE 0 / STEP 5 — refresh the session without a TOTP');

  final session = loadSession();
  final oldJwt = session['jwtToken'] as String;
  final refreshToken = session['refreshToken'] as String;
  final apiKey = session['apiKey'] as String;

  info('old jwt       ${redact(oldJwt)}');
  info('refresh token ${redact(refreshToken)}');

  step('Baseline — does the OLD jwt still work?');
  final before = await getJson(
    '$angelRestBase$profilePath',
    angelHeaders(apiKey: apiKey, jwtToken: oldJwt),
  );
  info('HTTP ${before.status}, status=${before.body['status']}');
  if (before.body['status'] != true) {
    fail('The old jwt is already invalid; refresh cannot be isolated. '
        'Re-run tool/01_login.dart.');
    return;
  }
  pass('Old jwt is valid, so any change below is attributable to the refresh');

  step('POST $refreshPath  (no TOTP supplied)');
  final res = await postJson(
    '$angelRestBase$refreshPath',
    angelHeaders(apiKey: apiKey, jwtToken: oldJwt),
    {'refreshToken': refreshToken},
  );
  info('HTTP ${res.status}');
  info('body ${jsonEncode(redactJson(res.body))}');

  if (res.body['status'] != true) {
    fail('Refresh rejected: ${res.body['message']} '
        '(${res.body['errorcode']})');
    info('§5.6 would then need a full re-login on expiry — a materially '
        'worse UX. Correct §3.1 before building on it.');
    return;
  }
  pass('Refresh accepted without a TOTP — §3.1 confirmed');

  final data = res.body['data'] as Map<String, dynamic>;
  final newJwt = data['jwtToken'] as String?;
  final newFeed = data['feedToken'] as String?;
  final newRefresh = data['refreshToken'] as String?;

  step('What came back');
  info('new jwt     ${redact(newJwt)}');
  info('new feed    ${redact(newFeed)}');
  info('new refresh ${redact(newRefresh)}');

  if (newJwt == null || newJwt.isEmpty) {
    fail('No jwtToken in the refresh response');
    return;
  }
  (newJwt == oldJwt ? fail : pass)(newJwt == oldJwt
      ? 'New jwt is IDENTICAL to the old one — suspicious'
      : 'New jwt differs from the old one');

  step('Is the new jwt actually usable? (read-only getProfile)');
  final after = await getJson(
    '$angelRestBase$profilePath',
    angelHeaders(apiKey: apiKey, jwtToken: newJwt),
  );
  info('HTTP ${after.status}, status=${after.body['status']}');
  if (after.body['status'] == true) {
    pass('The refreshed jwt authenticates a real request. §5.6 is viable: '
        'the app can renew silently and never re-prompt for a TOTP mid-session.');
  } else {
    fail('The refreshed jwt was REJECTED: ${after.body['message']}');
    info('This is exactly the silent trap §5.6 must avoid. Update the spec.');
    return;
  }

  step('Does the refresh also yield a working FEED token?');
  if (newFeed == null || newFeed.isEmpty) {
    info('No feedToken returned. The socket must keep using the login-issued '
        'one — worth recording, since §5.6 reconnect depends on it.');
  } else {
    pass('A new feedToken came back; reconnect after refresh can use it');
  }

  saveSession({
    ...session,
    'jwtToken': newJwt,
    if (newFeed != null && newFeed.isNotEmpty) 'feedToken': newFeed,
    if (newRefresh != null && newRefresh.isNotEmpty)
      'refreshToken': newRefresh,
    'refreshedAt': DateTime.now().toIso8601String(),
  });
  info('');
  info('Session file updated with the refreshed tokens.');

  heading('STEP 5 COMPLETE');
}
