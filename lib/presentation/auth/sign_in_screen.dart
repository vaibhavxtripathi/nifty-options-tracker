import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/routes.dart';
import '../../app/theme.dart';
import '../shared/template.dart';
import 'auth_controller.dart';
import 'widgets/auth_error_banner.dart';

/// Sign in with Google or with an existing email/password.
///
/// Navigation on success is deliberately absent: the router's guard reacts to
/// the auth state change and redirects. A screen that also pushed a route
/// would race with it.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submitEmail() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    await ref
        .read(authControllerProvider.notifier)
        .signInWithEmail(email: _email.text, password: _password.text);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(authControllerProvider);
    final controller = ref.read(authControllerProvider.notifier);
    final busy = state.isSubmitting;

    return AppTemplate(
      // Signed out: [BareChrome] is the variant that cannot offer a logout
      // action. The screen renders its own centred heading, so the bar shows
      // no title rather than repeating it.
      chrome: const BareChrome(title: 'Sign in', showTitle: false),
      padded: false,
      body: Center(
          child: SingleChildScrollView(
            padding: AppTheme.pagePadding,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Nifty Options Tracker',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 32),
                    AuthErrorBanner(failure: state.failure),
                    TextFormField(
                      controller: _email,
                      enabled: !busy,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(labelText: 'Email'),
                      validator: _validateEmail,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _password,
                      enabled: !busy,
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      decoration: const InputDecoration(labelText: 'Password'),
                      validator: (value) => (value == null || value.isEmpty)
                          ? 'Enter your password'
                          : null,
                      onFieldSubmitted: (_) => _submitEmail(),
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: busy ? null : _submitEmail,
                      child: busy
                          ? const _ButtonSpinner()
                          : const Text('Log in'),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: busy ? null : controller.signInWithGoogle,
                      icon: const Icon(Icons.g_mobiledata, size: 28),
                      label: const Text('Continue with Google'),
                    ),
                    const SizedBox(height: 24),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () {
                              controller.clearFailure();
                              context.push(Routes.register);
                            },
                      child: const Text("Don't have an account? Register"),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
    );
  }
}

String? _validateEmail(String? value) {
  final email = value?.trim() ?? '';
  if (email.isEmpty) return 'Enter your email';
  // Deliberately permissive. Firebase is the authority on what it will accept;
  // a strict client-side pattern only rejects addresses that would have worked.
  if (!email.contains('@') || !email.contains('.')) {
    return 'Enter a valid email';
  }
  return null;
}

class _ButtonSpinner extends StatelessWidget {
  const _ButtonSpinner();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: 20,
    width: 20,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
}
