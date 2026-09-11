import 'package:flutter/material.dart';

import '../../../domain/entities/market_tick.dart';
import '../../../domain/entities/option_contract.dart';
import '../format.dart';

/// Volume, open interest, day range, and the §3.4 bonus fields.
///
/// The required set (§3.4) comes first; the extras — OI change, circuit limits,
/// 52-week range — arrive in the same packet at no extra request, so showing
/// them costs nothing. **No Greeks**: Angel One's feed carries none, and a
/// computed one would be a guess presented as a fact.
class StatGrid extends StatelessWidget {
  const StatGrid({required this.tick, this.contract, super.key});

  final MarketTick tick;
  final OptionContract? contract;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final stats = <(String, String)>[
      ('Volume', formatQuantity(tick.volume)),
      ('Open interest', formatQuantity(tick.openInterest)),
      ('Day open', formatRupees(tick.open)),
      ('Day high', formatRupees(tick.high)),
      ('Day low', formatRupees(tick.low)),
      if (contract != null) ('Lot size', formatQuantity(contract!.lotSize)),
      ('OI change', formatPercent(tick.openInterestChangePercent)),
      ('Upper circuit', formatRupees(tick.upperCircuit)),
      ('Lower circuit', formatRupees(tick.lowerCircuit)),
      ('52-week high', formatRupees(tick.fiftyTwoWeekHigh)),
      ('52-week low', formatRupees(tick.fiftyTwoWeekLow)),
    ];

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Statistics', style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            for (final (label, value) in stats)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(label, style: theme.textTheme.bodySmall),
                    // Constrained so a wide value wraps rather than overflowing
                    // the row — three-digit percentages and seven-figure open
                    // interest both land here.
                    Flexible(
                      child: Text(
                        value,
                        textAlign: TextAlign.end,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
