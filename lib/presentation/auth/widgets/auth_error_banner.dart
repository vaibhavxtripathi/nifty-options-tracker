import 'package:flutter/material.dart';

import '../../../core/error/failures.dart';

/// Renders an [AppFailure] above a form.
///
/// Takes a failure rather than a string so the call site cannot pass raw
/// exception text — the only way to populate this is through the mapper, which
/// guarantees the message is safe to display.
class AuthErrorBanner extends StatelessWidget {
  const AuthErrorBanner({required this.failure, super.key});

  final AppFailure? failure;

  @override
  Widget build(BuildContext context) {
    final current = failure;
    if (current == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 20, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              current.message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}
