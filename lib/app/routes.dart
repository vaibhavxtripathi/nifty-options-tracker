import '../domain/entities/auth_state.dart';

/// Route paths, in one place so the guard and the screens cannot disagree
/// about a string literal.
final class Routes {
  const Routes._();

  static const String splash = '/';
  static const String signIn = '/sign-in';
  static const String register = '/register';
  static const String home = '/home';

  /// Routes reachable while signed out.
  static const Set<String> unauthenticated = {signIn, register};
}

/// Decides where a request should go, given who is signed in.
///
/// A pure function of (state, location) with no GoRouter or Flutter types in
/// its signature, so the redirect rules — the part that actually delivers
/// "kill and relaunch and stay signed in" — can be unit-tested without
/// pumping a widget or standing up Firebase.
///
/// Returns null to mean "stay where you are".
String? resolveRedirect({
  required AuthState state,
  required String location,
}) {
  final isOnAuthRoute = Routes.unauthenticated.contains(location);
  final isOnSplash = location == Routes.splash;

  switch (state) {
    // Decide nothing until the provider has reported. Sending an unknown
    // state to the sign-in screen is what makes a restored session look
    // broken: the user sees a sign-in flash before being bounced to home.
    case AuthUnknown():
      return isOnSplash ? null : Routes.splash;

    case AuthSignedOut():
      return isOnAuthRoute ? null : Routes.signIn;

    case AuthSignedIn():
      // Bounce off the splash and off auth routes; leave every other
      // destination alone so deep links still work once signed in.
      return isOnSplash || isOnAuthRoute ? Routes.home : null;
  }
}
