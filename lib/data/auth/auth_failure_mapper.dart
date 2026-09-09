import '../../core/error/failures.dart';

/// Translates identity-provider error codes into the app's own failures.
///
/// Split out from the repository so it can be unit-tested as a pure function —
/// no Firebase, no device, no network.
///
/// **It classifies on the provider's semantic code, never on a transport
/// status.** Phase 0 measured why that distinction matters: the Angel One
/// gateway returns HTTP 200 with `"Token missing"` in the body, so anything
/// keying off a status code reads a failure as success. Firebase is
/// better-behaved, but the rule is the same one and it is cheaper to apply
/// everywhere than to remember where it applies.
AppFailure mapAuthErrorCode(String? code) {
  switch (code) {
    // The modern code. Firebase collapses "no such user" and "wrong password"
    // into this one on projects with email-enumeration protection — the
    // default since September 2023 — specifically so the response cannot be
    // used to discover whether an address is registered.
    case 'invalid-credential':
    case 'INVALID_LOGIN_CREDENTIALS':
    // Deprecated, but still returned by older projects and by the local auth
    // emulator. Mapped to the same state so behaviour does not depend on when
    // the Firebase project happened to be created.
    case 'wrong-password':
    case 'user-not-found':
    case 'invalid-email':
      return const AuthFailure(
        'Incorrect email or password.',
        kind: AuthFailureKind.invalidCredentials,
      );

    case 'email-already-in-use':
      return const AuthFailure(
        'That email is already registered. Try logging in instead.',
        kind: AuthFailureKind.emailAlreadyInUse,
      );

    case 'weak-password':
      return const AuthFailure(
        'Password is too weak. Use at least 6 characters.',
        kind: AuthFailureKind.weakPassword,
      );

    case 'network-request-failed':
      return const NetworkFailure(
        'No connection. Check your network and try again.',
      );

    case 'too-many-requests':
      return const AuthFailure(
        'Too many attempts. Wait a moment and try again.',
      );

    case 'user-disabled':
      return const AuthFailure('This account has been disabled.');

    case 'operation-not-allowed':
      // Almost always a console misconfiguration rather than a user error:
      // the sign-in provider was never enabled.
      return const AuthFailure('That sign-in method is not enabled.');

    // The default deliberately discards the original code and message. A
    // provider's exception text can embed request detail, and this string
    // reaches a widget.
    default:
      return const AuthFailure('Something went wrong. Please try again.');
  }
}
