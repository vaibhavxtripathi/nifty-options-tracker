// Phase 0 support code. Throwaway — not imported by app code, not bound by the
// domain-purity rules in CLAUDE.md.
//
// The single most important thing in this file is redact(). Every value that
// originates from .env or from a broker auth response passes through it before
// it reaches stdout. Nothing else in tool/ is allowed to print such a value
// directly.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Fingerprint a secret for logging: length plus the last four characters.
///
/// Why last-four and not a hash: when a login fails you need to answer "did the
/// script read the value I think it did", and a tail is enough to tell two
/// credentials apart without disclosing either. Short values are fully masked
/// because a tail of a 6-digit TOTP would be most of the TOTP.
String redact(Object? secret) {
  if (secret == null) return '<null>';
  final s = secret.toString();
  if (s.isEmpty) return '<empty>';
  if (s.length <= 8) return '<len ${s.length}, ****>';
  return '<len ${s.length}, ...${s.substring(s.length - 4)}>';
}

/// Field names whose values must never be printed, matched case-insensitively
/// against JSON keys anywhere in a broker response.
const _sensitiveKeys = {
  'jwttoken',
  'refreshtoken',
  'feedtoken',
  'password',
  'totp',
  'mpin',
  'apikey',
  'x-privatekey',
  'authorization',
};

/// Deep-copy a decoded JSON structure with every sensitive value replaced by
/// its redacted fingerprint. Use this to print a whole auth response safely.
Object? redactJson(Object? node) {
  if (node is Map) {
    return {
      for (final e in node.entries)
        e.key: _sensitiveKeys.contains(e.key.toString().toLowerCase())
            ? redact(e.value)
            : redactJson(e.value),
    };
  }
  if (node is List) return node.map(redactJson).toList();
  return node;
}

/// Minimal .env reader. No package: the format we need is KEY=VALUE with #
/// comments, and pulling in a dependency for that is not worth the review cost.
Map<String, String> loadEnv([String path = '.env']) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('$path not found. Copy .env.example and fill it in.');
  }
  final env = <String, String>{};
  for (final raw in file.readAsLinesSync()) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    var value = line.substring(eq + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    env[line.substring(0, eq).trim()] = value;
  }
  return env;
}

/// Read a required key, failing loudly but without ever echoing the value.
String requireEnv(Map<String, String> env, String key) {
  final v = env[key];
  if (v == null || v.isEmpty) {
    throw StateError('$key is missing or empty in .env');
  }
  return v;
}

// ---------------------------------------------------------------------------
// TOTP (RFC 6238 / RFC 4226), HMAC-SHA1, 6 digits, 30-second step.
// ---------------------------------------------------------------------------

/// Decode a base32 secret (RFC 4648, padding optional, case-insensitive).
List<int> base32Decode(String input) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final cleaned = input.replaceAll('=', '').replaceAll(' ', '').toUpperCase();
  var bits = 0;
  var value = 0;
  final out = <int>[];
  for (final ch in cleaned.split('')) {
    final idx = alphabet.indexOf(ch);
    if (idx < 0) throw FormatException('Not valid base32: character "$ch"');
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      out.add((value >> (bits - 8)) & 0xFF);
      bits -= 8;
    }
  }
  return out;
}

/// Current TOTP code. [offsetSteps] shifts the time window, used to try an
/// adjacent window when the broker's clock disagrees with ours.
String generateTotp(String base32Secret, {int offsetSteps = 0, int digits = 6}) {
  final key = base32Decode(base32Secret);
  final counter =
      (DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000) ~/ 30 +
          offsetSteps;

  final counterBytes = List<int>.filled(8, 0);
  var c = counter;
  for (var i = 7; i >= 0; i--) {
    counterBytes[i] = c & 0xFF;
    c >>= 8;
  }

  final digest = Hmac(sha1, key).convert(counterBytes).bytes;
  final offset = digest[digest.length - 1] & 0x0F;
  final binary = ((digest[offset] & 0x7F) << 24) |
      ((digest[offset + 1] & 0xFF) << 16) |
      ((digest[offset + 2] & 0xFF) << 8) |
      (digest[offset + 3] & 0xFF);

  return (binary % pow(10, digits).toInt()).toString().padLeft(digits, '0');
}

/// Seconds remaining in the current 30-second TOTP window. Printed so a
/// failure right at a window boundary is recognisable as such.
int totpSecondsRemaining() =>
    30 - ((DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000) % 30);

// ---------------------------------------------------------------------------
// Angel One REST
// ---------------------------------------------------------------------------

const angelRestBase = 'https://apiconnect.angelone.in';
const loginPath = '/rest/auth/angelbroking/user/v1/loginByPassword';
const refreshPath = '/rest/auth/angelbroking/jwt/v1/generateTokens';
const profilePath = '/rest/secure/angelbroking/user/v1/getProfile';

const instrumentMasterUrl =
    'https://margincalculator.angelbroking.com/OpenAPI_File/files/OpenAPIScripMaster.json';

const wsUrl = 'wss://smartapisocket.angelone.in/smart-stream';

/// The nine headers from SPEC §3.1. The IP/MAC values are deliberate stable
/// placeholders — §3.1 says they are checked for presence and shape, never for
/// correctness, and real device fingerprinting is out of scope.
Map<String, String> angelHeaders({
  required String apiKey,
  String? jwtToken,
}) {
  return {
    'Content-type': 'application/json',
    'Accept': 'application/json',
    'X-UserType': 'USER',
    'X-SourceID': 'WEB',
    'X-ClientLocalIP': '192.168.1.10',
    'X-ClientPublicIP': '106.193.147.98',
    'X-MACAddress': 'aa:bb:cc:dd:ee:ff',
    'X-PrivateKey': apiKey,
    if (jwtToken != null) 'Authorization': 'Bearer $jwtToken',
  };
}

/// POST JSON and decode. Returns the status code alongside the body so callers
/// can assert on rejection shape, not just on success.
Future<({int status, Map<String, dynamic> body})> postJson(
  String url,
  Map<String, String> headers,
  Map<String, dynamic> payload,
) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse(url));
    headers.forEach(req.headers.set);
    req.add(utf8.encode(jsonEncode(payload)));
    final res = await req.close();
    final raw = await res.transform(utf8.decoder).join();
    return (status: res.statusCode, body: _decodeBody(raw));
  } finally {
    client.close();
  }
}

/// GET JSON with a supplied header set.
Future<({int status, Map<String, dynamic> body})> getJson(
  String url,
  Map<String, String> headers,
) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    headers.forEach(req.headers.set);
    final res = await req.close();
    final raw = await res.transform(utf8.decoder).join();
    return (status: res.statusCode, body: _decodeBody(raw));
  } finally {
    client.close();
  }
}

Map<String, dynamic> _decodeBody(String raw) {
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic>
        ? decoded
        : <String, dynamic>{'_nonObject': decoded};
  } catch (_) {
    // Truncated so an HTML error page cannot flood the console.
    final head = raw.length > 200 ? raw.substring(0, 200) : raw;
    return <String, dynamic>{'_unparseable': head};
  }
}

// ---------------------------------------------------------------------------
// Session cache — gitignored. Lets scripts 03-07 reuse one login instead of
// burning a TOTP code (and risking a rate limit) on every run.
// ---------------------------------------------------------------------------

const sessionPath = 'tool/.session.json';

void saveSession(Map<String, dynamic> tokens) {
  File(sessionPath)
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(tokens));
}

Map<String, dynamic> loadSession() {
  final f = File(sessionPath);
  if (!f.existsSync()) {
    throw StateError('No $sessionPath. Run:  dart tool/01_login.dart  first.');
  }
  final s = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  final issued = DateTime.tryParse(s['issuedAt'] as String? ?? '');
  if (issued != null) {
    final age = DateTime.now().difference(issued);
    stdout.writeln('  session age: ${age.inMinutes} min '
        '(tokens expire 05:00 IST next day)');
  }
  return s;
}

// ---------------------------------------------------------------------------
// Console helpers
// ---------------------------------------------------------------------------

void heading(String text) {
  stdout.writeln('\n${'=' * 72}\n$text\n${'=' * 72}');
}

void step(String text) => stdout.writeln('\n--- $text');
void pass(String text) => stdout.writeln('  [PASS] $text');
void fail(String text) => stdout.writeln('  [FAIL] $text');
void info(String text) => stdout.writeln('  $text');

/// IST is UTC+5:30 with no DST, so a fixed offset is correct year-round.
DateTime nowIst() =>
    DateTime.now().toUtc().add(const Duration(hours: 5, minutes: 30));

bool marketIsOpen() {
  final ist = nowIst();
  if (ist.weekday > 5) return false;
  final minutes = ist.hour * 60 + ist.minute;
  return minutes >= 9 * 60 + 15 && minutes <= 15 * 60 + 30;
}
