import 'package:flutter_test/flutter_test.dart';
import 'package:nifty_options_tracker/core/error/failures.dart';
import 'package:nifty_options_tracker/data/auth/auth_failure_mapper.dart';

void main() {
  group('mapAuthErrorCode', () {
    test('maps the modern invalid-credential code', () {
      final failure = mapAuthErrorCode('invalid-credential');
      expect(failure, isA<AuthFailure>());
      expect(
        (failure as AuthFailure).kind,
        AuthFailureKind.invalidCredentials,
      );
    });

    // Projects created before email-enumeration protection still return the
    // deprecated pair, and the auth emulator returns a third spelling. All
    // three must land on the same state, or behaviour would depend on when the
    // Firebase project was created.
    test('maps deprecated credential codes to the same state', () {
      for (final code in [
        'wrong-password',
        'user-not-found',
        'INVALID_LOGIN_CREDENTIALS',
        'invalid-email',
      ]) {
        final failure = mapAuthErrorCode(code);
        expect(
          failure,
          isA<AuthFailure>()
              .having((f) => f.kind, 'kind', AuthFailureKind.invalidCredentials),
          reason: '$code should read as invalid credentials',
        );
      }
    });

    test('maps email-already-in-use', () {
      expect(
        mapAuthErrorCode('email-already-in-use'),
        isA<AuthFailure>()
            .having((f) => f.kind, 'kind', AuthFailureKind.emailAlreadyInUse),
      );
    });

    test('maps weak-password', () {
      expect(
        mapAuthErrorCode('weak-password'),
        isA<AuthFailure>()
            .having((f) => f.kind, 'kind', AuthFailureKind.weakPassword),
      );
    });

    // §5.2 lists network failure as one of the four states, but it is not an
    // auth problem: it must not be able to reach code that signs a user out.
    test('maps network-request-failed to NetworkFailure, not AuthFailure', () {
      final failure = mapAuthErrorCode('network-request-failed');
      expect(failure, isA<NetworkFailure>());
      expect(failure, isNot(isA<AuthFailure>()));
    });

    test('falls back to a generic AuthFailure for unknown codes', () {
      for (final code in [null, '', 'something-new-from-firebase']) {
        final failure = mapAuthErrorCode(code);
        expect(failure, isA<AuthFailure>());
        expect((failure as AuthFailure).kind, AuthFailureKind.unknown);
      }
    });

    // The mapper is the barrier that stops provider text reaching a widget.
    test('never echoes the provider code back in the message', () {
      const code = 'some-internal-code-with-detail';
      expect(mapAuthErrorCode(code).message, isNot(contains(code)));
    });

    test('every message is non-empty and user-facing', () {
      for (final code in [
        'invalid-credential',
        'email-already-in-use',
        'weak-password',
        'network-request-failed',
        'too-many-requests',
        'user-disabled',
        'operation-not-allowed',
        'unknown',
      ]) {
        expect(mapAuthErrorCode(code).message, isNotEmpty);
      }
    });
  });
}
