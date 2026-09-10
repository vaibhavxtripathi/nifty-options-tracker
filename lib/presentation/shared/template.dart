import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../auth/auth_controller.dart';

/// How much chrome a screen gets.
///
/// §5.1 sketched this as `bool showNav`, but a boolean cannot express what the
/// app actually needs. Two flags — one for the nav, one for the logout action
/// — would give four states of which only three are meaningful, and would
/// leave "logout button on the sign-in screen" representable. A sealed
/// hierarchy makes the invalid combination unspeakable and keeps `switch`
/// exhaustiveness-checked, matching how `AuthState` and `AppFailure` are
/// already modelled.
sealed class AppChrome {
  const AppChrome();
}

/// No app bar at all. For the splash screen, which exists to decide nothing
/// and must not flash chrome before the router picks a destination.
final class NoChrome extends AppChrome {
  const NoChrome();
}

/// A title and nothing else. For screens reached while signed **out**, where a
/// logout action would be nonsense — this variant offers no way to request one.
final class BareChrome extends AppChrome {
  const BareChrome({required this.title, this.showTitle = true});

  final String title;

  /// Sign-in renders its own centred heading, so the bar would repeat it.
  final bool showTitle;
}

/// Full chrome for a signed-in screen: title, optional actions, and a logout
/// action **appended unconditionally**.
///
/// No caller passes the logout button — it is added here — which is how §5.1's
/// "a logout action present on every screen by construction" survives the move
/// away from a boolean. A signed-in screen cannot forget it, and a signed-out
/// screen cannot have it.
final class SignedInChrome extends AppChrome {
  const SignedInChrome({required this.title, this.actions = const []});

  final String title;

  /// Screen-specific actions, placed before the logout button.
  final List<Widget> actions;
}

/// The one shared shell. **The only `Scaffold` in `lib/`** — that is an
/// architecture rule in CLAUDE.md, an acceptance criterion in §6, and an
/// assertion in `test/architecture_test.dart`.
///
/// Screens supply a body; everything around it is decided here, so no screen
/// can drift on padding, background or the presence of a logout button.
///
/// Known limitation, for the README: wrapping per-screen means the chrome
/// rebuilds on every navigation. That is free at two screens; at ten, this
/// would be hoisted into a `ShellRoute` so the bar persists across routes.
class AppTemplate extends StatelessWidget {
  const AppTemplate({
    required this.chrome,
    required this.body,
    this.padded = true,
    super.key,
  });

  final AppChrome chrome;
  final Widget body;

  /// A screen that scrolls its own content — a long result list — wants to
  /// bleed to the edges and pad its rows individually.
  final bool padded;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: switch (chrome) {
        NoChrome() => null,
        BareChrome(:final title, :final showTitle) => AppBar(
          title: showTitle ? Text(title) : null,
        ),
        SignedInChrome(:final title, :final actions) => AppBar(
          leading: const _AppMark(),
          title: Text(title),
          actions: [...actions, const _LogoutAction()],
        ),
      },
      body: SafeArea(
        child: padded ? Padding(padding: AppTheme.pagePadding, child: body) : body,
      ),
    );
  }
}

/// Stand-in logo, per §5.1's "dummy logo as leading".
class _AppMark extends StatelessWidget {
  const _AppMark();

  @override
  Widget build(BuildContext context) => Center(
    child: Icon(
      Icons.candlestick_chart_outlined,
      color: Theme.of(context).colorScheme.primary,
    ),
  );
}

/// Logout, wherever a signed-in screen appears.
///
/// It reads the auth controller directly rather than taking a callback,
/// because a callback would let a screen supply the wrong one — or none. This
/// is the widget equivalent of the same guarantee [SignedInChrome] makes.
class _LogoutAction extends ConsumerWidget {
  const _LogoutAction();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final busy = ref.watch(authControllerProvider).isSubmitting;
    return IconButton(
      onPressed: busy ? null : ref.read(authControllerProvider.notifier).signOut,
      icon: const Icon(Icons.logout),
      tooltip: 'Log out',
    );
  }
}
