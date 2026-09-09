import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nifty_options_tracker/core/error/failures.dart';
import 'package:nifty_options_tracker/domain/entities/app_user.dart';
import 'package:nifty_options_tracker/domain/repositories/auth_repository.dart';
import 'package:nifty_options_tracker/presentation/auth/auth_controller.dart';
import 'package:nifty_options_tracker/presentation/auth/auth_providers.dart';

void main() {
  late _FakeAuthRepository repo;

  ProviderContainer makeContainer() {
    final container = ProviderContainer.test(
      overrides: [authRepositoryProvider.overrideWithValue(repo)],
    );
    return container;
  }

  setUp(() => repo = _FakeAuthRepository());

  group('AuthController', () {
    test('a successful email sign-in leaves no failure', () async {
      final container = makeContainer();
      final controller = container.read(authControllerProvider.notifier);

      final ok = await controller.signInWithEmail(
        email: 'trader@example.com',
        password: 'correct-horse',
      );

      expect(ok, isTrue);
      expect(container.read(authControllerProvider).hasFailure, isFalse);
      expect(container.read(authControllerProvider).isSubmitting, isFalse);
    });

    // The core of the Riverpod 3 retry finding: a failed sign-in must surface
    // as a rendered failure exactly once, not as a retried spinner. If this
    // were a FutureProvider, defaultRetry would re-run the call up to ten
    // times with backoff and the error state would never render.
    test('a failed sign-in surfaces the failure and calls the repo once',
        () async {
      repo.failure = const AuthFailure(
        'Incorrect email or password.',
        kind: AuthFailureKind.invalidCredentials,
      );
      final container = makeContainer();
      final controller = container.read(authControllerProvider.notifier);

      final ok = await controller.signInWithEmail(
        email: 'trader@example.com',
        password: 'wrong',
      );

      expect(ok, isFalse);
      expect(repo.signInCallCount, 1, reason: 'must not be retried');

      final state = container.read(authControllerProvider);
      expect(state.isSubmitting, isFalse);
      expect(state.failure, isA<AuthFailure>());
      expect(
        (state.failure! as AuthFailure).kind,
        AuthFailureKind.invalidCredentials,
      );
    });

    test('a network failure is preserved as NetworkFailure', () async {
      repo.failure = const NetworkFailure('No connection.');
      final container = makeContainer();

      await container
          .read(authControllerProvider.notifier)
          .signInWithEmail(email: 'a@b.com', password: 'x');

      expect(
        container.read(authControllerProvider).failure,
        isA<NetworkFailure>(),
      );
    });

    // Dismissing the Google picker is normal behaviour. §5.2 requires it show
    // nothing at all — no banner, and no spinner left running.
    test('cancelling Google sign-in sets no failure and clears the spinner',
        () async {
      repo.googleReturnsNull = true;
      final container = makeContainer();

      final ok = await container
          .read(authControllerProvider.notifier)
          .signInWithGoogle();

      expect(ok, isFalse);
      final state = container.read(authControllerProvider);
      expect(state.hasFailure, isFalse, reason: 'cancellation is not an error');
      expect(state.isSubmitting, isFalse);
    });

    test('clearFailure removes a stale banner', () async {
      repo.failure = const AuthFailure('nope');
      final container = makeContainer();
      final controller = container.read(authControllerProvider.notifier);

      await controller.signInWithEmail(email: 'a@b.com', password: 'x');
      expect(container.read(authControllerProvider).hasFailure, isTrue);

      controller.clearFailure();
      expect(container.read(authControllerProvider).hasFailure, isFalse);
    });

    test('a second submit is ignored while one is in flight', () async {
      repo.gate = Completer<void>();
      final container = makeContainer();
      final controller = container.read(authControllerProvider.notifier);

      final first = controller.signInWithEmail(email: 'a@b.com', password: 'x');
      final second = await controller.signInWithEmail(
        email: 'a@b.com',
        password: 'x',
      );

      expect(second, isFalse, reason: 'the in-flight call should win');
      repo.gate!.complete();
      await first;
      expect(repo.signInCallCount, 1);
    });

    test('registration failures surface the same way', () async {
      repo.failure = const AuthFailure(
        'That email is already registered.',
        kind: AuthFailureKind.emailAlreadyInUse,
      );
      final container = makeContainer();

      await container
          .read(authControllerProvider.notifier)
          .registerWithEmail(email: 'a@b.com', password: 'password');

      expect(
        (container.read(authControllerProvider).failure! as AuthFailure).kind,
        AuthFailureKind.emailAlreadyInUse,
      );
    });
  });
}

final class _FakeAuthRepository implements AuthRepository {
  AppFailure? failure;
  bool googleReturnsNull = false;
  int signInCallCount = 0;
  Completer<void>? gate;

  static const _user = AppUser(id: 'uid-1', email: 'trader@example.com');

  @override
  Stream<AppUser?> authStateChanges() => const Stream.empty();

  @override
  AppUser? get currentUser => null;

  @override
  Future<AppUser?> signInWithGoogle() async {
    signInCallCount++;
    if (googleReturnsNull) return null;
    final current = failure;
    if (current != null) throw current;
    return _user;
  }

  @override
  Future<AppUser> signInWithEmail({
    required String email,
    required String password,
  }) async {
    signInCallCount++;
    if (gate != null) await gate!.future;
    final current = failure;
    if (current != null) throw current;
    return _user;
  }

  @override
  Future<AppUser> registerWithEmail({
    required String email,
    required String password,
  }) async {
    signInCallCount++;
    final current = failure;
    if (current != null) throw current;
    return _user;
  }

  @override
  Future<void> signOut() async {}
}
