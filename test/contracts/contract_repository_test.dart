import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nifty_options_tracker/core/error/failures.dart';
import 'package:nifty_options_tracker/data/contracts/contract_cache.dart';
import 'package:nifty_options_tracker/data/contracts/contract_freshness.dart';
import 'package:nifty_options_tracker/data/contracts/contract_repository_impl.dart';
import 'package:nifty_options_tracker/data/contracts/instrument_master_client.dart';
import 'package:nifty_options_tracker/data/contracts/instrument_master_parser.dart';
import 'package:nifty_options_tracker/domain/entities/option_contract.dart';

/// Fetch/cache/invalidate behaviour, with the filesystem and the network faked.
///
/// The load-bearing test here is the call count: §6 criterion 5 is "second
/// launch uses cache with no network call", and a count is the only way to
/// assert the *absence* of a fetch. This is the same regression-guard shape
/// Phase 1 used to pin the Riverpod retry behaviour.
void main() {
  // `compute()` needs the Flutter binding; the repository parses through it.
  TestWidgetsFlutterBinding.ensureInitialized();

  final rawFixture = File(
    'test/fixtures/nifty_options.json',
  ).readAsStringSync();
  final fixtureContracts = parseNiftyOptions(rawFixture);

  DateTime ist(int year, int month, int day, int hour, int minute) =>
      DateTime.utc(year, month, day, hour, minute).subtract(istOffset);

  final now = ist(2026, 9, 10, 12, 0);

  test('criterion 5 — a fresh cache performs zero fetches', () async {
    final client = _CountingClient(rawFixture);
    final store = _FakeStore(
      CachedContracts(
        // After this morning's 08:30 publication, so still current.
        fetchedAt: ist(2026, 9, 10, 9, 0),
        contracts: fixtureContracts,
      ),
    );

    final repo = ContractRepositoryImpl(
      client: client,
      store: store,
      clock: () => now,
    );
    final result = await repo.loadContracts();

    expect(result, hasLength(fixtureContracts.length));
    expect(
      client.fetchCount,
      0,
      reason: 'a fresh cache must not touch the network',
    );
    expect(store.writeCount, 0, reason: 'nothing new to persist');
  });

  test('an absent cache fetches and then persists', () async {
    final client = _CountingClient(rawFixture);
    final store = _FakeStore(null);

    final result = await ContractRepositoryImpl(
      client: client,
      store: store,
      clock: () => now,
    ).loadContracts();

    expect(result, hasLength(fixtureContracts.length));
    expect(client.fetchCount, 1);
    expect(store.writeCount, 1);
    expect(store.written?.fetchedAt, now);
  });

  test('a stale cache is refetched', () async {
    final client = _CountingClient(rawFixture);
    final store = _FakeStore(
      CachedContracts(
        // Written before this morning's publication, so it holds yesterday's.
        fetchedAt: ist(2026, 9, 10, 8, 0),
        contracts: fixtureContracts,
      ),
    );

    await ContractRepositoryImpl(
      client: client,
      store: store,
      clock: () => now,
    ).loadContracts();

    expect(client.fetchCount, 1);
    expect(store.writeCount, 1);
  });

  test('a network failure with a stale cache serves the stale list', () async {
    // A day-old contract list is overwhelmingly still correct. Refusing to
    // show it because the network blipped would be strictly worse.
    final client = _FailingClient(const SocketException('offline'));
    final store = _FakeStore(
      CachedContracts(
        fetchedAt: ist(2026, 9, 10, 8, 0),
        contracts: fixtureContracts,
      ),
    );

    final result = await ContractRepositoryImpl(
      client: client,
      store: store,
      clock: () => now,
    ).loadContracts();

    expect(result, hasLength(fixtureContracts.length));
  });

  test('a network failure with no cache surfaces NetworkFailure', () async {
    final repo = ContractRepositoryImpl(
      client: _FailingClient(const SocketException('offline')),
      store: _FakeStore(null),
      clock: () => now,
    );

    await expectLater(repo.loadContracts(), throwsA(isA<NetworkFailure>()));
  });

  test('an unreadable payload surfaces ContractFailure', () async {
    final repo = ContractRepositoryImpl(
      client: _CountingClient('{"not":"an array"}'),
      store: _FakeStore(null),
      clock: () => now,
    );

    await expectLater(repo.loadContracts(), throwsA(isA<ContractFailure>()));
  });

  test('an empty filter result is a schema change, not "no matches"', () async {
    // If the §3.2 filter stops matching, failing loudly beats a search screen
    // that silently returns nothing forever.
    final repo = ContractRepositoryImpl(
      client: _CountingClient('[]'),
      store: _FakeStore(null),
      clock: () => now,
    );

    await expectLater(repo.loadContracts(), throwsA(isA<ContractFailure>()));
  });

  test('what is cached is mapped domain data, not raw broker rows', () async {
    final store = _FakeStore(null);
    await ContractRepositoryImpl(
      client: _CountingClient(rawFixture),
      store: store,
      clock: () => now,
    ).loadContracts();

    final cached = store.written!.contracts;
    expect(cached, everyElement(isA<OptionContract>()));
    // Rupees, not paise: the ÷100 does not get a second chance to be wrong.
    expect(cached.every((c) => c.strike < 100000), isTrue);
  });
}

final class _CountingClient implements InstrumentMasterClient {
  _CountingClient(this._payload);

  final String _payload;
  int fetchCount = 0;

  @override
  Future<String> fetch() async {
    fetchCount++;
    return _payload;
  }
}

final class _FailingClient implements InstrumentMasterClient {
  _FailingClient(this._error);

  final Object _error;

  @override
  Future<String> fetch() async => throw _error;
}

final class _FakeStore implements ContractStore {
  _FakeStore(this._initial);

  final CachedContracts? _initial;
  CachedContracts? written;
  int writeCount = 0;

  @override
  Future<CachedContracts?> read() async => written ?? _initial;

  @override
  Future<void> write(CachedContracts value) async {
    written = value;
    writeCount++;
  }
}
