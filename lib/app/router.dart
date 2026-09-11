import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../presentation/auth/auth_providers.dart';
import '../presentation/auth/register_screen.dart';
import '../presentation/auth/sign_in_screen.dart';
import '../presentation/auth/splash_screen.dart';
import '../presentation/detail/detail_screen.dart';
import '../presentation/search/search_screen.dart';
import 'routes.dart';

/// The app router, with the auth guard.
///
/// The guard's decision lives in [resolveRedirect] — a pure function in
/// `routes.dart` — so the rules are unit-testable without a widget tree. This
/// file only wires that decision to GoRouter.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRefreshNotifier(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: Routes.splash,
    // Re-runs `redirect` whenever auth state changes. Without this the guard
    // evaluates only on navigation, so signing out would leave the user
    // sitting on a screen they are no longer entitled to see.
    refreshListenable: refresh,
    redirect: (context, routerState) => resolveRedirect(
      state: ref.read(currentAuthStateProvider),
      location: routerState.matchedLocation,
    ),
    routes: [
      GoRoute(
        path: Routes.splash,
        builder: (_, _) => const SplashScreen(),
      ),
      GoRoute(
        path: Routes.signIn,
        builder: (_, _) => const SignInScreen(),
      ),
      GoRoute(
        path: Routes.register,
        builder: (_, _) => const RegisterScreen(),
      ),
      GoRoute(
        path: Routes.home,
        builder: (_, _) => const SearchScreen(),
      ),
      GoRoute(
        path: Routes.detail,
        builder: (_, state) =>
            DetailScreen(token: state.pathParameters['token'] ?? ''),
      ),
    ],
  );
});

/// Bridges Riverpod's auth state to the `Listenable` GoRouter wants.
class _AuthRefreshNotifier extends ChangeNotifier {
  _AuthRefreshNotifier(Ref ref) {
    _subscription = ref.listen(
      currentAuthStateProvider,
      (_, _) => notifyListeners(),
      fireImmediately: false,
    );
  }

  late final ProviderSubscription<Object?> _subscription;

  @override
  void dispose() {
    _subscription.close();
    super.dispose();
  }
}
