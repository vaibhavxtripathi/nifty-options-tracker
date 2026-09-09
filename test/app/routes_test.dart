import 'package:flutter_test/flutter_test.dart';
import 'package:nifty_options_tracker/app/routes.dart';
import 'package:nifty_options_tracker/domain/entities/app_user.dart';
import 'package:nifty_options_tracker/domain/entities/auth_state.dart';

void main() {
  const user = AppUser(id: 'uid-1', email: 'trader@example.com');

  group('resolveRedirect — auth state unknown', () {
    // This group is the regression guard for "kill and relaunch and remain
    // signed in". Firebase restores a session asynchronously, so if unknown
    // were treated as signed out the user would be bounced to /sign-in on
    // every cold start and then bounced back — a visible flash that looks
    // exactly like persistence being broken.
    test('parks on the splash rather than sending to sign-in', () {
      expect(
        resolveRedirect(state: const AuthUnknown(), location: Routes.home),
        Routes.splash,
      );
      expect(
        resolveRedirect(state: const AuthUnknown(), location: Routes.signIn),
        Routes.splash,
      );
    });

    test('stays put when already on the splash', () {
      expect(
        resolveRedirect(state: const AuthUnknown(), location: Routes.splash),
        isNull,
      );
    });

    test('never resolves to an auth route while unknown', () {
      for (final location in [
        Routes.splash,
        Routes.signIn,
        Routes.register,
        Routes.home,
      ]) {
        final target = resolveRedirect(
          state: const AuthUnknown(),
          location: location,
        );
        expect(Routes.unauthenticated.contains(target), isFalse);
      }
    });
  });

  group('resolveRedirect — signed out', () {
    test('sends protected routes to sign-in', () {
      expect(
        resolveRedirect(state: const AuthSignedOut(), location: Routes.home),
        Routes.signIn,
      );
    });

    test('leaves auth routes alone so register stays reachable', () {
      expect(
        resolveRedirect(state: const AuthSignedOut(), location: Routes.signIn),
        isNull,
      );
      expect(
        resolveRedirect(
          state: const AuthSignedOut(),
          location: Routes.register,
        ),
        isNull,
      );
    });

    // Logout must not strand the user on the splash.
    test('moves off the splash to sign-in', () {
      expect(
        resolveRedirect(state: const AuthSignedOut(), location: Routes.splash),
        Routes.signIn,
      );
    });
  });

  group('resolveRedirect — signed in', () {
    test('bounces off auth routes and the splash to home', () {
      for (final location in [Routes.splash, Routes.signIn, Routes.register]) {
        expect(
          resolveRedirect(state: const AuthSignedIn(user), location: location),
          Routes.home,
          reason: '$location should redirect to home when signed in',
        );
      }
    });

    test('leaves other destinations alone', () {
      expect(
        resolveRedirect(state: const AuthSignedIn(user), location: Routes.home),
        isNull,
      );
    });
  });

  group('resolveRedirect — stability', () {
    // A redirect target that itself redirects is an infinite loop at runtime.
    test('every decision reaches a fixed point in one more hop', () {
      final states = <AuthState>[
        const AuthUnknown(),
        const AuthSignedOut(),
        const AuthSignedIn(user),
      ];
      final locations = [
        Routes.splash,
        Routes.signIn,
        Routes.register,
        Routes.home,
      ];

      for (final state in states) {
        for (final location in locations) {
          final first = resolveRedirect(state: state, location: location);
          if (first == null) continue;
          expect(
            resolveRedirect(state: state, location: first),
            isNull,
            reason: '$state at $location redirects to $first, which redirects '
                'again — that is a navigation loop',
          );
        }
      }
    });
  });
}
