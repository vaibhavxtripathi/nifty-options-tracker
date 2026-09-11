import 'package:flutter/material.dart';

import '../../../domain/entities/market_tick.dart';
import '../format.dart';

/// Last traded price, and the move from the previous close.
///
/// Laid out so a three-digit percentage cannot break it (§6 criterion 4): the
/// price and the change sit in a [Wrap] rather than a fixed [Row], so
/// "+212.50%" moves to its own line instead of overflowing. §3.5 trap 4 says
/// moves that size are ordinary for options, so this is a normal case rather
/// than an edge one.
class PriceHeader extends StatelessWidget {
  const PriceHeader({required this.tick, super.key});

  final MarketTick tick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final change = tick.changePercent;

    // Null when there is no previous close to compare against — a newly listed
    // strike, or one that settled at zero. Neutral colour, because neither up
    // nor down is true.
    final colour = change == null
        ? theme.colorScheme.onSurfaceVariant
        : change >= 0
        ? const Color(0xFF1B873F)
        : theme.colorScheme.error;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.end,
          spacing: 16,
          runSpacing: 4,
          children: [
            Text(
              formatRupees(tick.lastTradedPrice),
              style: theme.textTheme.displaySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                formatPercent(change),
                style: theme.textTheme.titleLarge?.copyWith(color: colour),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Previous close ${formatRupees(tick.previousClose)}',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
