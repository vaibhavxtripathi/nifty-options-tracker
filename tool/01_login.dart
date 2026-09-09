// Phase 0, step 1 — prove SPEC §3.1.
//
// Proves three things:
//   a) a locally generated TOTP is accepted by loginByPassword
//   b) all three tokens (jwt, refresh, feed) come back
//   c) which of the nine headers are GENUINELY required, measured by dropping
//      one at a time and observing the rejection — not assumed
//
// Writes tool/.session.json (gitignored) so later scripts reuse this login
// rather than burning a fresh TOTP each run.
import 'dart:convert';
import 'dart:io';

import '_shared.dart';

Future<void> main() async {
  heading('PHASE 0 / STEP 1 — Angel One login + header requirement proof');

  final env = loadEnv();
  final apiKey = requireEnv(env, 'ANGEL_API_KEY');
  final clientCode = requireEnv(env, 'ANGEL_CLIENT_CODE');
  final mpin = requireEnv(env, 'ANGEL_MPIN');
  final totpSecret = requireEnv(env, 'ANGEL_TOTP_SECRET');

  step('Credentials loaded from .env (fingerprints only)');
  info('ANGEL_API_KEY      ${redact(apiKey)}');
  info('ANGEL_CLIENT_CODE  ${redact(clientCode)}');
  info('ANGEL_MPIN         ${redact(mpin)}');
  info('ANGEL_TOTP_SECRET  ${redact(totpSecret)}');

  // -- a) TOTP ---------------------------------------------------------------
  step('Generating TOTP locally (RFC 6238, HMAC-SHA1, 30s step)');
  final String totp;
  try {
    totp = generateTotp(totpSecret);
  } on FormatException catch (e) {
    fail('ANGEL_TOTP_SECRET is not valid base32: ${e.message}');
    exit(1);
  }
  info('code ${redact(totp)}, ${totpSecondsRemaining()}s left in this window');
  pass('TOTP generated without needing an external authenticator app');

  // -- b) login --------------------------------------------------------------
  step('POST $loginPath  (full 9-header set)');
  final fullHeaders = angelHeaders(apiKey: apiKey);
  final res = await postJson(
    '$angelRestBase$loginPath',
    fullHeaders,
    {'clientcode': clientCode, 'password': mpin, 'totp': totp},
  );

  info('HTTP ${res.status}');
  info('body ${jsonEncode(redactJson(res.body))}');

  final ok = res.body['status'] == true;
  if (!ok) {
    fail('Login rejected: ${res.body['message']} '
        '(errorcode ${res.body['errorcode']})');
    info('');
    info('Common causes:');
    info('  AB1007 / invalid totp -> secret wrong, or clock skew');
    info('  AB1050 / invalid mpin -> ANGEL_MPIN is the trading MPIN');
    info('  Rate limit            -> wait a minute, TOTP is once per 30s');
    exit(1);
  }

  final data = res.body['data'] as Map<String, dynamic>;
  final jwt = data['jwtToken'] as String?;
  final refresh = data['refreshToken'] as String?;
  final feed = data['feedToken'] as String?;

  step('Token presence check (SPEC §3.1 says all three must arrive)');
  var allThree = true;
  for (final entry in {
    'jwtToken': jwt,
    'refreshToken': refresh,
    'feedToken': feed,
  }.entries) {
    if (entry.value == null || entry.value!.isEmpty) {
      fail('${entry.key} MISSING');
      allThree = false;
    } else {
      pass('${entry.key.padRight(13)} ${redact(entry.value)}');
    }
  }
  if (!allThree) exit(1);

  saveSession({
    'jwtToken': jwt,
    'refreshToken': refresh,
    'feedToken': feed,
    'clientCode': clientCode,
    'apiKey': apiKey,
    'issuedAt': DateTime.now().toIso8601String(),
  });
  info('');
  info('Session cached to $sessionPath (gitignored)');

  // -- c) header ablation ----------------------------------------------------
  //
  // One request per omitted header. A fresh TOTP would be needed for a real
  // login attempt, so instead each probe hits the AUTHENTICATED profile
  // endpoint with the jwt we just obtained. That isolates the header check
  // from TOTP validity, and getProfile is read-only.
  step('Header ablation — dropping one header at a time');
  info('Probing $profilePath (read-only) with jwt from the login above.');
  info('A header is REQUIRED if omitting it changes the outcome.\n');

  final authed = angelHeaders(apiKey: apiKey, jwtToken: jwt);

  final baseline = await getJson('$angelRestBase$profilePath', authed);
  info('baseline (all headers): HTTP ${baseline.status}, '
      'status=${baseline.body['status']}');
  if (baseline.body['status'] != true) {
    fail('Baseline profile call failed; ablation results would be '
        'meaningless. Body: ${jsonEncode(redactJson(baseline.body))}');
    exit(1);
  }
  info('');

  final results = <String, String>{};
  for (final omitted in authed.keys.toList()) {
    final probe = Map<String, String>.from(authed)..remove(omitted);
    final r = await getJson('$angelRestBase$profilePath', probe);
    final accepted = r.body['status'] == true;
    results[omitted] = accepted
        ? 'OPTIONAL  (HTTP ${r.status}, still accepted)'
        : 'REQUIRED  (HTTP ${r.status}, ${r.body['errorcode'] ?? '-'} '
            '${r.body['message'] ?? ''})';
    info('${omitted.padRight(17)} ${results[omitted]}');
    // Courtesy pacing; the gateway rate-limits aggressively.
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  step('Verdict vs SPEC §3.1');
  final optional = results.entries
      .where((e) => e.value.startsWith('OPTIONAL'))
      .map((e) => e.key)
      .toList();
  if (optional.isEmpty) {
    pass('Every header in §3.1 is genuinely required. Spec confirmed.');
  } else {
    fail('These are NOT required, contrary to §3.1: ${optional.join(', ')}');
    info('Reality wins — update docs/SPEC.md §3.1 and note it in DECISIONS.md.');
  }

  heading('STEP 1 COMPLETE');
}
