import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/logging/logger.dart';
import '../../domain/entities/option_contract.dart';

/// A contract list as it was last persisted, with the instant it was fetched.
///
/// The timestamp travels with the data because staleness is decided against
/// the broker's 08:30 IST publication boundary, not against the file's mtime —
/// see `contract_freshness.dart`.
final class CachedContracts {
  const CachedContracts({required this.fetchedAt, required this.contracts});

  final DateTime fetchedAt;
  final List<OptionContract> contracts;
}

/// Durable storage for the mapped contract list.
///
/// An interface rather than a concrete file handle so the repository's
/// "a fresh cache performs zero fetches" behaviour can be tested without a
/// filesystem, a plugin, or a device.
abstract interface class ContractStore {
  Future<CachedContracts?> read();

  Future<void> write(CachedContracts value);
}

/// Stores the contract list as one JSON file in the app documents directory.
///
/// **What is persisted is already-mapped domain data** — rupee strikes and ISO
/// expiries — not the broker's raw rows. The §3.2 hazards are resolved once at
/// the mapping boundary and never re-enter the app through the back door of a
/// cache read. It also means the cached file is ~1,600 records rather than
/// 32.5 MB.
final class FileContractStore implements ContractStore {
  const FileContractStore();

  /// Bumped when the serialised shape changes. A file written by an older
  /// build is then discarded and refetched rather than parsed into something
  /// subtly wrong — a cache that crashes on upgrade is a bad first launch.
  static const int schemaVersion = 1;

  static const String _fileName = 'nifty_contracts.json';

  @override
  Future<CachedContracts?> read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return null;

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      if (decoded['schemaVersion'] != schemaVersion) {
        Log.info('Contract cache schema changed; discarding');
        return null;
      }

      final fetchedAt = DateTime.tryParse(decoded['fetchedAt'] as String? ?? '');
      final rows = decoded['contracts'];
      if (fetchedAt == null || rows is! List) return null;

      return CachedContracts(
        fetchedAt: fetchedAt,
        contracts: rows
            .whereType<Map<String, dynamic>>()
            .map(_fromJson)
            .whereType<OptionContract>()
            .toList(),
      );
    } on Object catch (error) {
      // A corrupt or half-written cache must degrade to "no cache", never to a
      // crash on launch. The caller then refetches.
      Log.warn('Contract cache unreadable; treating as absent: $error');
      return null;
    }
  }

  @override
  Future<void> write(CachedContracts value) async {
    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode({
          'schemaVersion': schemaVersion,
          'fetchedAt': value.fetchedAt.toUtc().toIso8601String(),
          'contracts': value.contracts.map(_toJson).toList(),
        }),
      );
      Log.info('Cached ${value.contracts.length} contracts');
    } on Object catch (error) {
      // Failing to cache is not failing to serve. The user has their
      // contracts; they just pay for the fetch again next launch.
      Log.warn('Could not write contract cache: $error');
    }
  }

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }
}

Map<String, dynamic> _toJson(OptionContract c) => {
  'token': c.token,
  'symbol': c.symbol,
  'strike': c.strike,
  'expiry': c.expiry.toIso8601String(),
  'optionType': c.optionType.code,
  'lotSize': c.lotSize,
  'tickSize': c.tickSize,
};

OptionContract? _fromJson(Map<String, dynamic> json) {
  final expiry = DateTime.tryParse(json['expiry'] as String? ?? '');
  final token = json['token'];
  final symbol = json['symbol'];
  final strike = json['strike'];
  final lotSize = json['lotSize'];
  final tickSize = json['tickSize'];
  if (expiry == null ||
      token is! String ||
      symbol is! String ||
      strike is! num ||
      lotSize is! int ||
      tickSize is! num) {
    return null;
  }

  final type = OptionType.values
      .where((t) => t.code == json['optionType'])
      .firstOrNull;
  if (type == null) return null;

  return OptionContract(
    token: token,
    symbol: symbol,
    strike: strike.toDouble(),
    expiry: expiry,
    optionType: type,
    lotSize: lotSize,
    tickSize: tickSize.toDouble(),
  );
}
