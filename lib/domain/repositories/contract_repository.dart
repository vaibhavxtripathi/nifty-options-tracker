import '../entities/option_contract.dart';

/// Where the searchable contract universe comes from.
///
/// This is the seam a test overrides, matching the [AuthRepository] precedent:
/// the interface lives in `domain/`, the Angel One implementation lives in
/// `data/`, and everything above is written against the abstraction. There is
/// deliberately no use-case layer between them — see `docs/DECISIONS.md`.
///
/// Implementations throw [AppFailure] and nothing else. Whether a result came
/// from the network or from a cache is an implementation concern and is
/// intentionally absent from this signature.
abstract interface class ContractRepository {
  /// The full Nifty option universe, already mapped to domain objects.
  ///
  /// Serves a fresh cache without touching the network; refetches when the
  /// cache has aged past the broker's daily refresh boundary.
  Future<List<OptionContract>> loadContracts();
}
