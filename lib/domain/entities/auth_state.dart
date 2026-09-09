import 'app_user.dart';

/// Whether anyone is signed in — including the case where we do not yet know.
///
/// The third state is the entire point. Firebase restores a persisted session
/// asynchronously, so for the first frames after launch "no user" and "not yet
/// loaded" are indistinguishable unless they are modelled apart. A router that
/// conflates them sends every cold start to the sign-in screen for a moment,
/// which looks exactly like session persistence being broken.
sealed class AuthState {
  const AuthState();
}

/// The identity provider has not reported yet. Show a splash; decide nothing.
final class AuthUnknown extends AuthState {
  const AuthUnknown();
}

final class AuthSignedOut extends AuthState {
  const AuthSignedOut();
}

final class AuthSignedIn extends AuthState {
  const AuthSignedIn(this.user);

  final AppUser user;
}
