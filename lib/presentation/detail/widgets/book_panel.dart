import 'package:flutter/material.dart';

import '../../../domain/entities/book_level.dart';
import '../../../domain/entities/market_tick.dart';
import '../format.dart';

/// Best bid and best ask, with spread and mid.
///
/// Every value here is nullable, and that is the point (§6 criterion 5). An
/// illiquid strike may have nothing resting on a side at all, so each cell
/// renders an em dash rather than a zero — `₹0.00` reads as a real quote at
/// zero, which is a different and wrong claim.
///
/// Spread and mid are two lines that §5.7 calls out as signalling domain
/// awareness; both are null whenever either side is empty, because a spread
/// against a missing quote is not a number.
class BookPanel extends StatelessWidget {
  const BookPanel({required this.tick, super.key});

  final MarketTick tick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Order book', style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _Side(
                    label: 'Bid',
                    level: tick.bestBid,
                    colour: const Color(0xFF1B873F),
                  ),
                ),
                Expanded(
                  child: _Side(
                    label: 'Ask',
                    level: tick.bestAsk,
                    colour: theme.colorScheme.error,
                    alignEnd: true,
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _Inline(label: 'Spread', value: formatRupees(tick.spread)),
                _Inline(label: 'Mid', value: formatRupees(tick.mid)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Side extends StatelessWidget {
  const _Side({
    required this.label,
    required this.level,
    required this.colour,
    this.alignEnd = false,
  });

  final String label;
  final BookLevel? level;
  final Color colour;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = level;

    return Column(
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall),
        const SizedBox(height: 2),
        Text(
          formatRupees(current?.price),
          style: theme.textTheme.titleMedium?.copyWith(
            color: current == null ? theme.colorScheme.onSurfaceVariant : colour,
          ),
        ),
        Text(
          current == null
              // Says why it is empty rather than leaving a blank the reader
              // has to interpret.
              ? 'no resting orders'
              : '${formatQuantity(current.quantity)} @ '
                    '${current.orderCount} orders',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _Inline extends StatelessWidget {
  const _Inline({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text('$label ', style: theme.textTheme.bodySmall),
        Text(value, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}
