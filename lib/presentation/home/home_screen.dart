import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../domain/entities/auth_state.dart';
import '../auth/auth_controller.dart';
import '../auth/auth_providers.dart';

/// Phase 1 placeholder: proves a user is signed in and offers logout.
///
/// Phase 2 replaces this with the search screen rendered inside
/// `template.dart` (§5.1). It carries its own `Scaffold` only because that
/// template does not exist yet.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(currentAuthStateProvider);
    final busy = ref.watch(authControllerProvider).isSubmitting;
    final user = authState is AuthSignedIn ? authState.user : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nifty Options Tracker'),
        actions: [
          IconButton(
            onPressed: busy
                ? null
                : ref.read(authControllerProvider.notifier).signOut,
            icon: const Icon(Icons.logout),
            tooltip: 'Log out',
          ),
        ],
      ),
      body: Padding(
        padding: AppTheme.pagePadding,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.check_circle_outline, size: 48),
            const SizedBox(height: 16),
            Text(
              'Signed in',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              user?.label ?? '',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 32),
            Text(
              'Contract search arrives in Phase 2.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
