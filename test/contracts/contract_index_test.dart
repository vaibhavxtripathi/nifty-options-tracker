import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nifty_options_tracker/data/contracts/contract_index.dart';
import 'package:nifty_options_tracker/data/contracts/instrument_master_parser.dart';
import 'package:nifty_options_tracker/domain/entities/option_contract.dart';

/// Search behaviour, against the real 590-contract fixture.
///
/// Covers §6 Phase 2 acceptance criteria 2 (correctly sorted results),
/// 3 (nearest expiry marked) and 4 (empty-result state).
void main() {
  final contracts = parseNiftyOptions(
    File('test/fixtures/nifty_options.json').readAsStringSync(),
  );
  final index = ContractIndex(contracts);

  test('the fixture covers three expiries, so ordering is observable', () {
    expect(contracts.map((c) => c.expiry).toSet().length, greaterThan(1));
  });

  group('criterion 2 — searching a strike returns correctly sorted results', () {
    test('a strike search returns that strike', () {
      final results = index.search('21900');
      expect(results, isNotEmpty);
      for (final contract in results) {
        expect(contract.strike, 21900);
      }
    });

    test('results are ordered expiry ascending, then strike', () {
      final results = index.search('219');
      expect(results.length, greaterThan(1));
      for (var i = 1; i < results.length; i++) {
        final previous = results[i - 1];
        final current = results[i];
        final expiryOrder = previous.expiry.compareTo(current.expiry);
        expect(expiryOrder, lessThanOrEqualTo(0));
        if (expiryOrder == 0) {
          expect(previous.strike, lessThanOrEqualTo(current.strike));
        }
      }
    });

    test('this week beats a later expiry at the same strike', () {
      // §5.3's actual requirement: someone searching "21900" wants the
      // nearest contract first, not one four months out.
      final results = index.search('21900');
      expect(results.first.expiry, index.nearestExpiry);
    });

    test('the whole list is ordered too, before anything is typed', () {
      final all = index.search('');
      expect(all, hasLength(contracts.length));
      for (var i = 1; i < all.length; i++) {
        expect(all[i - 1].expiry.compareTo(all[i].expiry), lessThanOrEqualTo(0));
      }
    });

    test('a symbol fragment matches, case-insensitively', () {
      expect(index.search('sep'), isNotEmpty);
      expect(index.search('SEP'), hasLength(index.search('sep').length));
    });

    test('both a call and a put come back for a strike', () {
      final types = index.search('21900').map((c) => c.optionType).toSet();
      expect(types, containsAll(<OptionType>[OptionType.call, OptionType.put]));
    });
  });

  group('criterion 3 — nearest expiry marked', () {
    test('nearestExpiry is the earliest present', () {
      final earliest = contracts
          .map((c) => c.expiry)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      expect(index.nearestExpiry, earliest);
    });

    test('isNearestExpiry marks exactly the contracts on that date', () {
      for (final contract in contracts) {
        expect(
          index.isNearestExpiry(contract),
          contract.expiry == index.nearestExpiry,
        );
      }
    });

    test('an empty index has no nearest expiry rather than throwing', () {
      expect(ContractIndex(const []).nearestExpiry, isNull);
    });
  });

  group('criterion 4 — the empty-result state', () {
    test('a query matching nothing returns empty, and does not throw', () {
      expect(index.search('99999'), isEmpty);
    });

    test('so does obvious junk', () {
      expect(index.search('zzzz'), isEmpty);
    });

    test('a blank query returns everything, so the screen starts populated', () {
      expect(index.search(''), hasLength(contracts.length));
      expect(index.search('   '), hasLength(contracts.length));
    });
  });

  test('search performs no mutation of the indexed order', () {
    final before = index.search('');
    index.search('21900');
    expect(index.search(''), orderedEquals(before));
  });
}
