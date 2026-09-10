import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/error/failures.dart';
import '../../core/logging/logger.dart';
import '../../domain/entities/option_contract.dart';
import '../../domain/repositories/contract_repository.dart';
import 'contract_cache.dart';
import 'contract_freshness.dart';
import 'instrument_master_client.dart';
import 'instrument_master_parser.dart';

/// Fetch, map, cache, invalidate — §5.3, in that order.
///
/// The whole point of this class is that the expensive path runs at most once
/// a day. A fresh cache short-circuits before the client is ever touched,
/// which is what makes "second launch uses cache with no network call" true by
/// construction rather than by luck.
final class ContractRepositoryImpl implements ContractRepository {
  ContractRepositoryImpl({
    InstrumentMasterClient? client,
    ContractStore? store,
    DateTime Function()? clock,
  }) : _client = client ?? const AngelInstrumentMasterClient(),
       _store = store ?? const FileContractStore(),
       _now = clock ?? DateTime.now;

  final InstrumentMasterClient _client;
  final ContractStore _store;
  final DateTime Function() _now;

  @override
  Future<List<OptionContract>> loadContracts() async {
    final cached = await _store.read();

    if (cached != null && !isStale(fetchedAt: cached.fetchedAt, now: _now())) {
      Log.info('Serving ${cached.contracts.length} contracts from cache');
      return cached.contracts;
    }

    try {
      return await _fetchAndCache();
    } on AppFailure catch (failure) {
      // A stale cache beats an empty search screen. Contracts change once a
      // day and only at the edges, so yesterday's list is overwhelmingly still
      // correct — refusing to show it because the network blipped would be
      // strictly worse for the user than showing it.
      if (cached != null) {
        Log.warn('Refetch failed; serving stale cache: ${failure.message}');
        return cached.contracts;
      }
      rethrow;
    }
  }

  Future<List<OptionContract>> _fetchAndCache() async {
    final String raw;
    try {
      raw = await _client.fetch();
    } on SocketException {
      throw const NetworkFailure('No connection.');
    } on HttpException {
      throw const ContractFailure('Could not reach the contract list.');
    } on TimeoutException {
      throw const NetworkFailure('The connection timed out.');
    }

    final List<OptionContract> contracts;
    try {
      // 32.5 MB of JSON across 145,599 rows. Decoding that on the UI isolate
      // visibly drops frames — Phase 0 measured 388 ms on a desktop VM, and a
      // phone is materially slower. `compute()` moves both the decode and the
      // filter off the UI isolate, so only the ~1,600 Nifty options are ever
      // copied back.
      contracts = await compute(parseNiftyOptions, raw);
    } on FormatException {
      throw const ContractFailure('The contract list could not be read.');
    }

    if (contracts.isEmpty) {
      // An empty result here is not "no matches", it is a schema change: the
      // filter in §3.2 stopped matching. Failing loudly beats a search screen
      // that silently returns nothing forever.
      throw const ContractFailure('No Nifty contracts found.');
    }

    Log.info('Fetched ${contracts.length} contracts');
    await _store.write(
      CachedContracts(fetchedAt: _now(), contracts: contracts),
    );
    return contracts;
  }
}
