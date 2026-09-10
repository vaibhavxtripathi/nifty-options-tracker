import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/contracts/contract_index.dart';
import '../../data/contracts/contract_repository_impl.dart';
import '../../domain/entities/option_contract.dart';
import '../../domain/repositories/contract_repository.dart';

/// The contract source. Overridden in tests with a fake.
final contractRepositoryProvider = Provider<ContractRepository>(
  (ref) => ContractRepositoryImpl(),
);

/// Loads the day's contracts.
///
/// **This one keeps Riverpod 3's automatic retry, deliberately.** Phase 1
/// removed it from auth because retrying a wrong password ten times is both
/// useless and harmful. The reasoning inverts here: this is an idempotent read
/// of a public file that fails for transient reasons — a flaky connection, a
/// CDN hiccup — and nothing the user typed can make it fail. Retrying with
/// backoff is exactly the right response, and it costs the user nothing
/// because they are not waiting on a decision they made.
///
/// So the default is not being inherited by accident; it is the correct
/// behaviour for this provider, and the contrast with `AuthController` is the
/// point. See `docs/DECISIONS.md`.
final contractsProvider = FutureProvider<List<OptionContract>>(
  (ref) => ref.watch(contractRepositoryProvider).loadContracts(),
);

/// The searchable index, rebuilt only when the contract list itself changes.
///
/// Sorting happens once here rather than per keystroke.
final contractIndexProvider = Provider<AsyncValue<ContractIndex>>(
  (ref) => ref.watch(contractsProvider).whenData(ContractIndex.new),
);

/// What the user has typed. A plain string: search is synchronous and pure, so
/// there is no request in flight and nothing to model beyond the query itself.
final searchQueryProvider = NotifierProvider<SearchQuery, String>(
  SearchQuery.new,
);

final class SearchQuery extends Notifier<String> {
  @override
  String build() => '';

  void update(String value) => state = value;
}

/// The results.
///
/// A `Provider`, not a `FutureProvider`: filtering an in-memory list cannot
/// fail and cannot be slow, so there is nothing to await and — unlike the
/// fetch above — nothing that could ever be worth retrying.
final searchResultsProvider = Provider<AsyncValue<List<OptionContract>>>((ref) {
  final query = ref.watch(searchQueryProvider);
  return ref.watch(contractIndexProvider).whenData((i) => i.search(query));
});
