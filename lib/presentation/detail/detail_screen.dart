import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../domain/entities/feed_source.dart';
import '../../domain/entities/market_tick.dart';
import '../../domain/entities/option_contract.dart';
import '../search/search_providers.dart';
import '../shared/template.dart';
import 'detail_providers.dart';
import 'widgets/book_panel.dart';
import 'widgets/feed_banner.dart';
import 'widgets/price_header.dart';
import 'widgets/stat_grid.dart';

/// Live market data for one contract.
///
/// Reads state and renders it. Every value shown was computed at the decoding
/// boundary or by a pure formatter — there is no arithmetic in this file.
///
/// Supplies a body to [AppTemplate] and builds no `Scaffold`, so logout is
/// present here by construction.
class DetailScreen extends ConsumerWidget {
  const DetailScreen({required this.token, super.key});

  final String token;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contract = ref
        .watch(contractIndexProvider)
        .value
        ?.findByToken(token);
    final source = ref.watch(feedSourceProvider);
    final tick = ref.watch(tickProvider(token));

    return AppTemplate(
      chrome: SignedInChrome(title: contract?.displayName ?? 'Contract'),
      padded: false,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Always visible, never dismissible: data that looks live but is not
          // is worse than no data, so the provenance is part of the screen
          // rather than a toast that disappears.
          FeedBanner(source: source, tick: tick.value),
          Expanded(
            child: switch (tick) {
              AsyncData(:final value) => _Body(
                tick: value,
                contract: contract,
                source: source,
              ),
              AsyncError(:final error) => _FeedError(error: error),
              _ => const Center(child: CircularProgressIndicator()),
            },
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.tick,
    required this.contract,
    required this.source,
  });

  final MarketTick tick;
  final OptionContract? contract;
  final FeedSource source;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: AppTheme.pagePadding,
      children: [
        PriceHeader(tick: tick),
        const SizedBox(height: 24),
        BookPanel(tick: tick),
        const SizedBox(height: 24),
        StatGrid(tick: tick, contract: contract),
      ],
    );
  }
}

/// A feed that could not start.
///
/// Distinguishes a **setup problem** from a transient one, because they need
/// different actions from the reader: a missing credential is something to fix
/// in the build, while a dropped socket is something to wait out.
class _FeedError extends ConsumerWidget {
  const _FeedError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isSetup = error is StateError;

    return Center(
      child: Padding(
        padding: AppTheme.pagePadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isSetup ? Icons.settings_outlined : Icons.cloud_off,
              size: 48,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              isSetup
                  ? 'Market data is not configured'
                  : 'Market data is unavailable',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              isSetup
                  // Names the missing keys, never their values.
                  ? 'This build has no broker credentials. Pass them with '
                        '--dart-define at build time.'
                  : 'The connection could not be established. It will retry '
                        'automatically.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
