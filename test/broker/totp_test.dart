@TestOn('vm')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nifty_options_tracker/data/broker/totp.dart';

/// TOTP against the published RFC vectors.
///
/// These are the best tests in the project, for a reason worth stating: the
/// expected values come from RFC 4226 and RFC 6238 themselves, so they are
/// ground truth that exists entirely independently of this implementation.
/// Every other test in the codebase compares our code against our fixture or
/// our reasoning; these compare it against the standard.
///
/// That matters because a broken TOTP presents as `AB1050 Invalid totp and
/// client combination` — indistinguishable from a wrong secret, a rotated
/// secret, or an account with no TOTP registered. Phase 0 lost time to exactly
/// that ambiguity, and ruling the arithmetic out cheaply is what let it be
/// diagnosed as account-side.
void main() {
  // RFC 4226 Appendix D: the secret is the ASCII string "12345678901234567890".
  final rfc4226Key = Uint8List.fromList(ascii.encode('12345678901234567890'));

  group('RFC 4226 HOTP vectors', () {
    // All ten, from the RFC's own table. Counter 0 through 9.
    const expected = [
      '755224',
      '287082',
      '359152',
      '969429',
      '338314',
      '254676',
      '287922',
      '162583',
      '399871',
      '520489',
    ];

    for (var counter = 0; counter < expected.length; counter++) {
      test('counter $counter yields ${expected[counter]}', () {
        expect(
          generateHotp(key: rfc4226Key, counter: counter),
          expected[counter],
        );
      });
    }
  });

  group('RFC 6238 TOTP vectors (SHA-1)', () {
    // The RFC's table maps a Unix time to a code for the same 20-byte secret.
    const vectors = <int, String>{
      59: '287082',
      1111111109: '081804',
      1111111111: '050471',
      1234567890: '005924',
      2000000000: '279037',
    };

    // The RFC prints 8-digit codes; the 6-digit truncation is the low 6.
    vectors.forEach((unixTime, code) {
      test('T=$unixTime yields $code', () {
        final at = DateTime.fromMillisecondsSinceEpoch(
          unixTime * 1000,
          isUtc: true,
        );
        expect(
          generateTotp(
            base32Secret: _rfcSecretAsBase32,
            at: at,
          ),
          code,
        );
      });
    });
  });

  group('base32 decoding (RFC 4648)', () {
    test('decodes a known secret', () {
      // "12345678901234567890" in base32.
      expect(
        decodeBase32('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'),
        rfc4226Key,
      );
    });

    test('is case-insensitive and ignores padding and spaces', () {
      final canonical = decodeBase32('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ');
      expect(decodeBase32('gezdgnbvgy3tqojqgezdgnbvgy3tqojq'), canonical);
      expect(decodeBase32('GEZDGNBV GY3TQOJQ GEZDGNBV GY3TQOJQ'), canonical);
      expect(decodeBase32('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ===='), canonical);
    });

    test('rejects a character outside the alphabet', () {
      // 0, 1, 8 and 9 are not in the base32 alphabet — they are the digits
      // most often mistyped for O, L and B.
      expect(() => decodeBase32('ABCD0EFG'), throwsFormatException);
      expect(() => decodeBase32('ABCD1EFG'), throwsFormatException);
      expect(() => decodeBase32('ABCD8EFG'), throwsFormatException);
    });

    test('rejects an empty secret', () {
      expect(() => decodeBase32(''), throwsFormatException);
      expect(() => decodeBase32('   '), throwsFormatException);
    });

    test('the error never quotes the offending character', () {
      // The character is part of a secret. Reporting the position is enough to
      // fix a typo without putting secret material into a message that could
      // be logged.
      try {
        decodeBase32('ABCD0EFG');
        fail('should have thrown');
      } on FormatException catch (e) {
        expect(e.message, contains('position'));
        expect(e.message.contains('0'), isFalse);
      }
    });
  });

  group('time stepping', () {
    test('the code is stable within a 30-second window', () {
      final start = DateTime.utc(2026, 9, 11, 10, 0, 0);
      final code = generateTotp(base32Secret: _rfcSecretAsBase32, at: start);
      for (final offset in const [1, 15, 29]) {
        expect(
          generateTotp(
            base32Secret: _rfcSecretAsBase32,
            at: start.add(Duration(seconds: offset)),
          ),
          code,
          reason: 'same step, so the same code',
        );
      }
    });

    test('the code changes at the window boundary', () {
      final start = DateTime.utc(2026, 9, 11, 10, 0, 0);
      expect(
        generateTotp(
          base32Secret: _rfcSecretAsBase32,
          at: start.add(const Duration(seconds: 30)),
        ),
        isNot(generateTotp(base32Secret: _rfcSecretAsBase32, at: start)),
      );
    });

    test('stepOffset reaches the adjacent windows', () {
      final at = DateTime.utc(2026, 9, 11, 10, 0, 15);
      final current = generateTotp(base32Secret: _rfcSecretAsBase32, at: at);
      final next = generateTotp(
        base32Secret: _rfcSecretAsBase32,
        at: at.add(const Duration(seconds: 30)),
      );
      expect(
        generateTotp(base32Secret: _rfcSecretAsBase32, at: at, stepOffset: 1),
        next,
        reason: 'a +1 step must equal the next window, for clock-skew retries',
      );
      expect(
        generateTotp(base32Secret: _rfcSecretAsBase32, at: at, stepOffset: 0),
        current,
      );
    });

    test('secondsRemaining counts down within the window', () {
      expect(
        totpSecondsRemaining(at: DateTime.utc(2026, 9, 11, 10, 0, 0)),
        30,
      );
      expect(
        totpSecondsRemaining(at: DateTime.utc(2026, 9, 11, 10, 0, 29)),
        1,
      );
      expect(
        totpSecondsRemaining(at: DateTime.utc(2026, 9, 11, 10, 0, 30)),
        30,
      );
    });
  });

  test('codes are always the requested width, zero-padded', () {
    // A code that truncates to fewer than six digits must be padded, not sent
    // short — the broker expects exactly six characters.
    for (var counter = 0; counter < 500; counter++) {
      expect(generateHotp(key: rfc4226Key, counter: counter), hasLength(6));
    }
  });
}

/// "12345678901234567890" — the RFC 4226/6238 test secret — in base32.
const String _rfcSecretAsBase32 = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';
