import 'package:flutter/material.dart';

import '../shared/template.dart';

/// Shown while the identity provider restores any persisted session.
///
/// This screen is the reason a returning user never sees the sign-in form
/// flash on launch: the router parks here during [AuthUnknown] instead of
/// guessing "signed out". It is typically visible for a few frames.
///
/// [NoChrome] because a screen that exists to decide nothing must not flash an
/// app bar — and because there is no signed-in user yet to log out.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const AppTemplate(
      chrome: NoChrome(),
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
