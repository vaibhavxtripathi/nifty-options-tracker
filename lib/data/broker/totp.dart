/// RFC 6238 TOTP over RFC 4226 HOTP: HMAC-SHA1, 6 digits, 30-second step.
///
/// Angel One has no long-lived credential — every login needs a fresh 6-digit
/// code, and tokens die at 05:00 IST — so this is what lets the app
/// re-authenticate without a human typing a code from their phone. That is a
/// deliberate trade recorded in `docs/DECISIONS.md`: it puts a
/// trading-capable secret on the device in exchange for a demo that does not
/// stall on an expired token.
///
/// Pure and clock-injectable, which is what makes it testable against the RFC
/// vectors. Phase 0 verified this algorithm against all ten RFC 4226 HOTP
/// vectors plus the RFC 6238 `T=59` case before any of it reached app code.
///
/// **Never log a generated code or the secret it came from.**
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const String _base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// The RFC 6238 default time step.
const Duration totpStep = Duration(seconds: 30);

/// Decodes a base32 secret (RFC 4648). Padding optional, case-insensitive.
///
/// Throws [FormatException] on a character outside the alphabet — which is
/// how a secret pasted with a typo fails loudly at startup rather than
/// silently generating codes the broker will reject. Phase 0 spent real time
/// on an `AB1050` that turned out to be account-side; a malformed secret
/// producing the *same* symptom is worth ruling out cheaply.
Uint8List decodeBase32(String input) {
  final cleaned = input.replaceAll('=', '').replaceAll(' ', '').toUpperCase();
  if (cleaned.isEmpty) {
    throw const FormatException('Base32 secret is empty');
  }

  var bits = 0;
  var value = 0;
  final out = <int>[];

  for (var i = 0; i < cleaned.length; i++) {
    final index = _base32Alphabet.indexOf(cleaned[i]);
    if (index < 0) {
      // Deliberately reports the position, not the character: the character
      // is part of a secret.
      throw FormatException('Invalid base32 character at position $i');
    }
    value = (value << 5) | index;
    bits += 5;
    if (bits >= 8) {
      out.add((value >> (bits - 8)) & 0xFF);
      bits -= 8;
    }
  }

  return Uint8List.fromList(out);
}

/// The HOTP code for [counter] (RFC 4226).
///
/// Separated from [generateTotp] so the RFC 4226 test vectors — which are
/// defined over counters, not timestamps — can be asserted directly.
String generateHotp({
  required Uint8List key,
  required int counter,
  int digits = 6,
}) {
  final counterBytes = Uint8List(8);
  var remaining = counter;
  for (var i = 7; i >= 0; i--) {
    counterBytes[i] = remaining & 0xFF;
    remaining >>= 8;
  }

  final digest = Hmac(sha1, key).convert(counterBytes).bytes;

  // Dynamic truncation, RFC 4226 §5.3: the low nibble of the last byte picks
  // the offset, and the high bit of the first selected byte is masked off so
  // the result is unambiguously positive across implementations.
  final offset = digest[digest.length - 1] & 0x0F;
  final binary =
      ((digest[offset] & 0x7F) << 24) |
      ((digest[offset + 1] & 0xFF) << 16) |
      ((digest[offset + 2] & 0xFF) << 8) |
      (digest[offset + 3] & 0xFF);

  return (binary % pow(10, digits).toInt()).toString().padLeft(digits, '0');
}

/// The TOTP code for [at] (defaults to now).
///
/// [stepOffset] shifts the window by whole steps, so a caller can try the
/// adjacent window when the broker's clock disagrees with the device's.
String generateTotp({
  required String base32Secret,
  DateTime? at,
  int stepOffset = 0,
  int digits = 6,
}) {
  final instant = at ?? DateTime.now();
  final counter =
      instant.toUtc().millisecondsSinceEpoch ~/ totpStep.inMilliseconds +
      stepOffset;
  return generateHotp(
    key: decodeBase32(base32Secret),
    counter: counter,
    digits: digits,
  );
}

/// Seconds left in the current step.
///
/// Used to decide whether to wait for the next window rather than spend a code
/// that is about to expire mid-flight — a login that crosses a window boundary
/// fails in a way that looks like a bad secret.
int totpSecondsRemaining({DateTime? at}) {
  final instant = at ?? DateTime.now();
  final seconds = instant.toUtc().millisecondsSinceEpoch ~/ 1000;
  return totpStep.inSeconds - (seconds % totpStep.inSeconds);
}
