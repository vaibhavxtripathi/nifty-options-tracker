import 'package:flutter/material.dart';

/// Shown while the identity provider restores any persisted session.
///
/// This screen is the reason a returning user never sees the sign-in form
/// flash on launch: the router parks here during [AuthUnknown] instead of
/// guessing "signed out". It is typically visible for a few frames.
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
