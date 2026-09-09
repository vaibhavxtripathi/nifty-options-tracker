import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error/failures.dart';
import '../../domain/repositories/auth_repository.dart';
import 'auth_providers.dart';

/// What the auth screens render: whether a request is in flight, and the last
/// failure if there was one.
///
/// The signed-in user is deliberately absent — that lives in
/// [authStateProvider], sourced from the identity provider's own stream, so
/// there is exactly one answer to "who is signed in".
final class AuthFormState {
  const AuthFormState({this.isSubmitting = false, this.failure});

  final bool isSubmitting;
  final AppFailure? failure;

  bool get hasFailure => failure != null;

  AuthFormState copyWith({bool? isSubmitting, AppFailure? failure}) =>
      AuthFormState(
        isSubmitting: isSubmitting ?? this.isSubmitting,
        // Positional: passing null must be able to *clear* the failure, which
        // `failure ?? this.failure` could not express.
        failure: failure,
      );
}

/// Drives sign-in, registration and sign-out.
///
/// **Why these are imperative methods and not `FutureProvider`s.** Riverpod 3
/// retries a provider that throws an `Exception` — up to ten times with
/// exponential backoff, per `ProviderContainer.defaultRetry`. A
/// `FirebaseAuthException` for a wrong password is an `Exception`, so a
/// sign-in expressed as a provider body would quietly retry the user's bad
/// password ten times while the screen showed a spinner, and the "invalid
/// credentials" state §5.2 requires would never render.
///
/// Catching the failure into state here keeps the retry machinery out of a
/// code path where retrying is both useless and wrong.
final class AuthController extends Notifier<AuthFormState> {
  @override
  AuthFormState build() => const AuthFormState();

  AuthRepository get _repo => ref.read(authRepositoryProvider);

  /// Returns true if a user was signed in, false if they dismissed the picker.
  Future<bool> signInWithGoogle() async {
    return _run(() async => await _repo.signInWithGoogle() != null);
  }

  Future<bool> signInWithEmail({
    required String email,
    required String password,
  }) {
    return _run(() async {
      await _repo.signInWithEmail(email: email.trim(), password: password);
      return true;
    });
  }

  Future<bool> registerWithEmail({
    required String email,
    required String password,
  }) {
    return _run(() async {
      await _repo.registerWithEmail(email: email.trim(), password: password);
      return true;
    });
  }

  Future<void> signOut() async {
    await _run(() async {
      await _repo.signOut();
      return true;
    });
  }

  /// Clears a stale error, so switching between sign-in and register does not
  /// carry the previous screen's banner across.
  void clearFailure() {
    if (state.hasFailure) state = const AuthFormState();
  }

  Future<bool> _run(Future<bool> Function() action) async {
    if (state.isSubmitting) return false;
    state = const AuthFormState(isSubmitting: true);
    try {
      return await action();
    } on AppFailure catch (failure) {
      state = AuthFormState(failure: failure);
      return false;
    } finally {
      // Only clear the spinner if no failure replaced the state above;
      // otherwise this would wipe the failure we just set.
      if (state.isSubmitting) state = const AuthFormState();
    }
  }
}

final authControllerProvider =
    NotifierProvider<AuthController, AuthFormState>(AuthController.new);
