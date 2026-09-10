@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The architecture rules in CLAUDE.md, enforced instead of merely documented.
///
/// A convention that is only written down drifts the first time someone is in
/// a hurry. These read the source and fail the build, which is the difference
/// between a rule and a wish.
void main() {
  group('dependencies point inward', () {
    test('domain/ imports nothing but dart: and pure Dart packages', () {
      final offenders = <String>[];

      for (final file in _dartFilesIn('lib/domain')) {
        for (final import in _importsOf(file)) {
          // A relative import stays inside lib/ and is checked separately by
          // the "never imports data/ or presentation/" test below. Same-
          // directory imports carry no './' prefix, hence the !startsWith
          // rather than a startsWith('.').
          final isRelative = !import.startsWith('package:');
          final isPureDart =
              import.startsWith('dart:') ||
              isRelative ||
              import.startsWith('package:collection/') ||
              import.startsWith('package:meta/');
          if (!isPureDart) {
            offenders.add('${file.path}: $import');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'domain/ must stay pure Dart — no Flutter, Firebase, http or '
            'broker types. The test for this rule is that deleting '
            'presentation/ leaves everything else compiling.',
      );
    });

    test('domain/ never imports data/ or presentation/', () {
      final offenders = <String>[];
      for (final file in _dartFilesIn('lib/domain')) {
        for (final import in _importsOf(file)) {
          if (import.contains('/data/') ||
              import.contains('/presentation/') ||
              import.contains('data/') && import.startsWith('..') ||
              import.contains('presentation/') && import.startsWith('..')) {
            offenders.add('${file.path}: $import');
          }
        }
      }
      expect(offenders, isEmpty);
    });

    test('data/ never imports presentation/', () {
      final offenders = <String>[];
      for (final file in _dartFilesIn('lib/data')) {
        for (final import in _importsOf(file)) {
          if (import.contains('presentation/')) {
            offenders.add('${file.path}: $import');
          }
        }
      }
      expect(offenders, isEmpty);
    });
  });

  group('the two auth systems never touch', () {
    // CLAUDE.md's hardest rule, and the one Phase 0 proved is load-bearing:
    // Angel One's WebSocket rate-limit rejection is byte-identical to an auth
    // failure, so any coupling here would let a two-second throttle sign a
    // user out of the app entirely.
    test('the Firebase auth layer has no concept of the broker', () {
      final brokerWords = RegExp(
        r'angel|smartapi|broker|jwtToken|feedToken|totp',
        caseSensitive: false,
      );

      final offenders = <String>[];
      for (final file in [
        ..._dartFilesIn('lib/data/auth'),
        ..._dartFilesIn('lib/presentation/auth'),
      ]) {
        final source = file.readAsStringSync();
        for (final line in source.split('\n')) {
          // Comments may discuss the rule; code may not implement it.
          final trimmed = line.trimLeft();
          if (trimmed.startsWith('//') || trimmed.startsWith('*')) continue;
          if (brokerWords.hasMatch(line)) {
            offenders.add('${file.path}: ${line.trim()}');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'Firebase governs who may open the app; the Angel One session '
            'governs whether data flows. A broker failure must never be able '
            'to sign a user out.',
      );
    });
  });

  group('the template owns all chrome', () {
    // §6 Phase 2 lists `grep -rn "Scaffold" lib/` matching only
    // template.dart as an acceptance criterion. Asserting it here makes it a
    // permanent guard rather than something that was true once, on the day it
    // was checked.
    test('Scaffold is constructed in exactly one file, and it is the template',
        () {
      // Files rather than 'path:line' strings: a Windows path carries a
      // drive-letter colon, so splitting one back apart is a trap.
      final offenders = <String>{};
      for (final file in _dartFilesIn('lib')) {
        for (final line in file.readAsStringSync().split('\n')) {
          // A doc comment may name Scaffold; only construction counts.
          final trimmed = line.trimLeft();
          if (trimmed.startsWith('//') || trimmed.startsWith('*')) continue;
          if (RegExp(r'\bScaffold\s*\(').hasMatch(line)) {
            offenders.add(file.path.replaceAll('\\', '/'));
          }
        }
      }

      expect(
        offenders,
        {'lib/presentation/shared/template.dart'},
        reason:
            'Screens supply a body; the template owns the chrome. A Scaffold '
            'anywhere else means a screen that can drift on padding, '
            'background, or the presence of a logout button.',
      );
    });
  });

  group('hard prohibitions', () {
    test('no order placement or mutating broker endpoint anywhere in lib/', () {
      final forbidden = RegExp(
        r'placeOrder|modifyOrder|cancelOrder|/order/|squareoff',
        caseSensitive: false,
      );
      final offenders = <String>[];
      for (final file in _dartFilesIn('lib')) {
        if (forbidden.hasMatch(file.readAsStringSync())) {
          offenders.add(file.path);
        }
      }
      expect(offenders, isEmpty, reason: 'read-only endpoints only, ever');
    });

    test('no print() in lib/ — the logger is the only console route', () {
      final offenders = <String>[];
      for (final file in _dartFilesIn('lib')) {
        final lines = file.readAsStringSync().split('\n');
        for (var i = 0; i < lines.length; i++) {
          final trimmed = lines[i].trimLeft();
          if (trimmed.startsWith('//')) continue;
          if (RegExp(r'(^|[^.\w])print\s*\(').hasMatch(lines[i])) {
            offenders.add('${file.path}:${i + 1}');
          }
        }
      }
      expect(offenders, isEmpty);
    });

    test('no secret is hard-coded in lib/', () {
      // Catches an assignment of a literal to a credential-shaped name. The
      // real defence is review, but this stops the obvious slip.
      final assignment = RegExp(
        '''(apiKey|api_key|clientCode|mpin|totpSecret|password|secret)'''
        r'''\s*=\s*['"][^'"]{6,}['"]''',
        caseSensitive: false,
      );
      final offenders = <String>[];
      for (final file in _dartFilesIn('lib')) {
        for (final line in file.readAsStringSync().split('\n')) {
          if (assignment.hasMatch(line)) offenders.add('${file.path}: $line');
        }
      }
      expect(offenders, isEmpty);
    });
  });
}

Iterable<File> _dartFilesIn(String relativePath) {
  final dir = Directory(relativePath);
  if (!dir.existsSync()) return const [];
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      // Generated by flutterfire; not hand-written and not ours to lint.
      .where((f) => !f.path.endsWith('firebase_options.dart'));
}

Iterable<String> _importsOf(File file) {
  final pattern = RegExp('''^\\s*(?:import|export)\\s+['"]([^'"]+)['"]''');
  return file
      .readAsLinesSync()
      .map((line) => pattern.firstMatch(line)?.group(1))
      .whereType<String>();
}
