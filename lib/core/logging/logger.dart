import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// The one logger. CLAUDE.md bans `print`, and `avoid_print` is an analyzer
/// error, so this is the only route to the console.
///
/// It routes through `dart:developer` rather than stdout so release builds
/// stay quiet, and it is deliberately small: there is no `log(response)`
/// convenience, because the way a token ends up in a scrollback buffer is
/// someone logging a whole auth response "just this once".
///
/// **Never pass a token, a TOTP code, a password, or a raw broker/auth
/// response to any of these.** Phase 0 solved the same problem for the
/// verification scripts with a `redact()` chokepoint; the app's equivalent
/// rule is that credential material never becomes a log argument in the first
/// place.
final class Log {
  const Log._();

  static void debug(String message) => _emit(message, level: _debugLevel);

  static void info(String message) => _emit(message, level: _infoLevel);

  static void warn(String message) => _emit(message, level: _warnLevel);

  /// [error] should be an `AppFailure` or a short description — not a caught
  /// provider exception, whose `toString()` may embed response detail.
  static void error(String message, {Object? error, StackTrace? stackTrace}) =>
      _emit(message, level: _errorLevel, error: error, stackTrace: stackTrace);

  static void _emit(
    String message, {
    required int level,
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!kDebugMode && level < _warnLevel) return;
    developer.log(
      message,
      name: 'nifty',
      level: level,
      error: error,
      stackTrace: stackTrace,
    );
  }

  static const int _debugLevel = 500;
  static const int _infoLevel = 800;
  static const int _warnLevel = 900;
  static const int _errorLevel = 1000;
}
