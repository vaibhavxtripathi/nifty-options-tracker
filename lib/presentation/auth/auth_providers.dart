import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/auth/firebase_auth_repository.dart';
import '../../domain/entities/auth_state.dart';
import '../../domain/repositories/auth_repository.dart';

/// The identity provider. Overridden in tests with a fake.
final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => FirebaseAuthRepository(),
);

/// The current auth state, including the [AuthUnknown] period before the
/// provider has restored a persisted session.
///
/// A `StreamProvider` is right *here* — it observes a stream that does not
/// throw. Auth **actions** deliberately are not providers; see
/// [AuthController] for why.
final authStateProvider = StreamProvider<AuthState>((ref) {
  final repo = ref.watch(authRepositoryProvider);
  return repo.authStateChanges().map<AuthState>(
    (user) => user == null ? const AuthSignedOut() : AuthSignedIn(user),
  );
});

/// [authStateProvider] flattened, mapping "no value yet" onto [AuthUnknown].
///
/// The router needs a synchronous answer on every redirect, and it needs
/// *loading* to mean "don't decide" rather than "signed out".
final currentAuthStateProvider = Provider<AuthState>((ref) {
  return ref
      .watch(authStateProvider)
      .maybeWhen(
        data: (state) => state,
        // An error from the auth stream is not a signed-in user, and the app
        // must remain usable: fall back to signed out rather than trapping the
        // user on a splash screen forever.
        error: (_, _) => const AuthSignedOut(),
        orElse: () => const AuthUnknown(),
      );
});
