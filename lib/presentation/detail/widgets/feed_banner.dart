import 'package:flutter/material.dart';

import '../../../data/demo/demo_fixture.dart';
import '../../../domain/entities/feed_source.dart';
import '../../../domain/entities/market_tick.dart';
import '../format.dart';

/// Says where the data came from — permanently, not once.
///
/// Under replay this is the most important widget on the screen. A recording
/// that ticks convincingly is indistinguishable from a live feed unless the
/// app says otherwise, and a label that scrolls away or fades out is a label
/// that will be missed. So it is pinned above the content and cannot be
/// dismissed.
class FeedBanner extends StatelessWidget {
  const FeedBanner({
    required this.source,
    this.tick,
    this.isStale = false,
    super.key,
  });

  final FeedSource source;
  final MarketTick? tick;

  /// The stream is not currently delivering — backgrounded, reconnecting, or
  /// still opening. The values on screen are the last known ones.
  ///
  /// Worth surfacing rather than hiding: a screen showing a price that stopped
  /// updating looks identical to one showing a price that has not moved, and
  /// on a trading screen those are very different facts.
  final bool isStale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (isStale) {
      return _Bar(
        icon: Icons.pause_circle_outline,
        background: theme.colorScheme.surfaceContainerHighest,
        foreground: theme.colorScheme.onSurfaceVariant,
        label: 'PAUSED',
        detail: 'Showing the last known values · not updating',
      );
    }

    return switch (source) {
      LiveFeed() => _Bar(
        icon: Icons.circle,
        iconSize: 10,
        background: theme.colorScheme.primaryContainer,
        foreground: theme.colorScheme.onPrimaryContainer,
        label: 'LIVE',
        detail: 'Streaming from Angel One',
      ),

      ReplayFeed(:final recordedAt) => _Bar(
        icon: Icons.history,
        background: theme.colorScheme.tertiaryContainer,
        foreground: theme.colorScheme.onTertiaryContainer,
        label: 'REPLAY',
        // Names the instrument as well as the time, because replay streams
        // what was recorded rather than whichever contract was tapped. Letting
        // the reader believe otherwise would be the dishonest version of this.
        detail:
            'Recorded ${formatRecordedAt(recordedAt)} · '
            '${DemoFixture.recordedSymbol} · market closed',
      ),

      FeedUnavailable() => _Bar(
        icon: Icons.settings_outlined,
        background: theme.colorScheme.errorContainer,
        foreground: theme.colorScheme.onErrorContainer,
        label: 'NOT CONFIGURED',
        detail: 'No broker credentials in this build',
      ),
    };
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.icon,
    required this.background,
    required this.foreground,
    required this.label,
    required this.detail,
    this.iconSize = 16,
  });

  final IconData icon;
  final Color background;
  final Color foreground;
  final String label;
  final String detail;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: iconSize, color: foreground),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
                Text(
                  detail,
                  style: theme.textTheme.bodySmall?.copyWith(color: foreground),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
