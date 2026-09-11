import 'package:flutter/material.dart';

/// One theme, defined once.
///
/// §7 rules out a custom design system, so this is Material 3 with a seed
/// colour and a few defaults that keep the screens consistent without any
/// screen having to restate them.
final class AppTheme {
  const AppTheme._();

  static ThemeData get light => _build(Brightness.light);
  static ThemeData get dark => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
        ),
      ),
    );
  }

  /// Deep indigo: neutral enough not to imply a direction on a price screen,
  /// where red and green already carry meaning.
  static const Color _seed = Color(0xFF2A3B8F);

  /// Overscroll that does not distort the content.
  ///
  /// Flutter's Android default since Android 12 is a *stretch* indicator: pull
  /// past the end and the whole list scales. On a price screen that is
  /// actively bad — the numbers are the content, and momentarily rendering
  /// them stretched makes a reader doubt what they just read. It is also
  /// heavy-handed on a short list, which is most of this app.
  ///
  /// A glow leaves the text at its true size and still signals the boundary.
  static const ScrollBehavior scrollBehavior = _AppScrollBehavior();

  /// Standard page inset, so screens do not each invent one.
  static const EdgeInsets pagePadding = EdgeInsets.all(24);
}

/// Replaces the Android 12+ stretch overscroll with a glow.
///
/// Also pins `ClampingScrollPhysics` so the feel is the same on every
/// platform the app is ever built for: §7 rules out iOS, but a screen that
/// scrolls differently depending on where it runs is a surprise waiting to
/// happen rather than a feature.
final class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return GlowingOverscrollIndicator(
      axisDirection: details.direction,
      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
      child: child,
    );
  }

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const ClampingScrollPhysics();
}
