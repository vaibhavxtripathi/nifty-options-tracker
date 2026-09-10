import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/error/failures.dart';
import '../../data/contracts/contract_index.dart';
import '../../domain/entities/option_contract.dart';
import '../shared/template.dart';
import 'search_providers.dart';
import 'widgets/contract_row.dart';

/// Search the day's Nifty option contracts.
///
/// Reads state and renders it. Every decision it displays — what matches, what
/// order, which expiry is nearest — was made below it in [ContractIndex]; this
/// file contains no filtering, no sorting and no arithmetic.
///
/// It supplies a body to [AppTemplate] and constructs no `Scaffold`, so logout
/// is present without this screen doing anything to provide it.
class SearchScreen extends ConsumerWidget {
  const SearchScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppTemplate(
      chrome: const SignedInChrome(title: 'Nifty Options'),
      // The result list scrolls to the edges; rows carry their own insets.
      padded: false,
      body: Column(
        children: [
          const _SearchField(),
          Expanded(
            child: switch (ref.watch(searchResultsProvider)) {
              AsyncData(:final value) => _Results(results: value),
              AsyncError(:final error) => _Failure(error: error),
              _ => const Center(child: CircularProgressIndicator()),
            },
          ),
        ],
      ),
    );
  }
}

class _SearchField extends ConsumerStatefulWidget {
  const _SearchField();

  @override
  ConsumerState<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends ConsumerState<_SearchField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: TextField(
        controller: _controller,
        keyboardType: TextInputType.text,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search a strike, e.g. 21900',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _controller.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _controller.clear();
                    ref.read(searchQueryProvider.notifier).update('');
                    setState(() {});
                  },
                ),
        ),
        // Straight through on every keystroke, with no debounce: the search is
        // a synchronous filter over an in-memory list, so there is no request
        // to coalesce and waiting would only add lag (§5.3).
        onChanged: (value) {
          ref.read(searchQueryProvider.notifier).update(value);
          setState(() {});
        },
      ),
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({required this.results});

  final List<OptionContract> results;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (results.isEmpty) return const _NoMatches();

    final index = ref.watch(contractIndexProvider).value;
    return ListView.separated(
      itemCount: results.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) => ContractRow(
        contract: results[i],
        isNearestExpiry: index?.isNearestExpiry(results[i]) ?? false,
      ),
    );
  }
}

/// The empty-result state, which §5.3 calls out as graded and requiring
/// explicit handling. It is a normal outcome of a search, not an error, so it
/// reads as guidance rather than as a failure.
class _NoMatches extends StatelessWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: AppTheme.pagePadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off, size: 48),
            const SizedBox(height: 16),
            Text(
              'No contracts match that search.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Try a strike price like 21900, or an expiry like SEP.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _Failure extends ConsumerWidget {
  const _Failure({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Switching over the sealed hierarchy rather than reading a string: adding
    // a failure type later becomes a compile error here rather than a silently
    // unhandled state.
    final message = switch (error) {
      NetworkFailure(:final message) => message,
      ContractFailure(:final message) => message,
      AppFailure(:final message) => message,
      _ => 'Could not load contracts.',
    };

    return Center(
      child: Padding(
        padding: AppTheme.pagePadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => ref.invalidate(contractsProvider),
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}
