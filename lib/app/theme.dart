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

  /// Standard page inset, so screens do not each invent one.
  static const EdgeInsets pagePadding = EdgeInsets.all(24);
}
