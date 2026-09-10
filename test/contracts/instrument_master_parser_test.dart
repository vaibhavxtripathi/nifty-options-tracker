import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nifty_options_tracker/data/contracts/instrument_master_parser.dart';
import 'package:nifty_options_tracker/domain/entities/option_contract.dart';

/// The four §3.2 parsing hazards, each as its own test, against the real
/// instrument-master rows recorded in Phase 0.
///
/// These are the tests that stop the app being silently wrong. A ÷100 error
/// produces a plausible-looking strike, not an exception, so nothing else in
/// the codebase would notice.
void main() {
  final rawFixture = File(
    'test/fixtures/nifty_options.json',
  ).readAsStringSync();
  final contracts = parseNiftyOptions(rawFixture);

  group('§3.2 hazard 1 — strike is paise, divide by 100', () {
    test('a known row maps to rupees', () {
      final contract = contracts.firstWhere(
        (c) => c.symbol == 'NIFTY15SEP2621900CE',
      );
      // The fixture row reads "2190000.000000".
      expect(contract.strike, 21900);
    });

    test('every strike lands in a plausible Nifty range', () {
      // The scaling error this catches is silent: forgetting the divisor
      // yields ₹2,190,000, which is a number, not an error.
      for (final contract in contracts) {
        expect(
          contract.strike,
          inInclusiveRange(1000, 100000),
          reason: '${contract.symbol} looks unscaled',
        );
      }
    });
  });

  group('§3.2 hazard 2 — expiry is DDMMMYYYY, not ISO', () {
    test('DateTime.parse genuinely throws on the broker format', () {
      // Asserted rather than assumed: this is why a hand-written parser
      // exists at all, and if it ever stopped being true the parser could go.
      expect(() => DateTime.parse('06OCT2026'), throwsFormatException);
    });

    test('parseAngelExpiry reads it correctly', () {
      expect(parseAngelExpiry('06OCT2026'), DateTime(2026, 10, 6));
      expect(parseAngelExpiry('15SEP2026'), DateTime(2026, 9, 15));
    });

    test('every fixture expiry parsed', () {
      expect(contracts, isNotEmpty);
      for (final contract in contracts) {
        expect(contract.expiry.year, greaterThan(2000));
      }
    });

    test('a malformed expiry is rejected', () {
      expect(() => parseAngelExpiry('06XXX2026'), throwsFormatException);
      expect(() => parseAngelExpiry('2026-10-06'), throwsFormatException);
    });
  });

  group('§3.2 hazard 3 — every numeric field arrives quoted', () {
    test('the fixture really does quote them', () {
      final row = (jsonDecode(rawFixture) as List).first as Map<String, dynamic>;
      for (final key in ['token', 'strike', 'lotsize', 'tick_size']) {
        expect(row[key], isA<String>(), reason: '$key should be quoted');
      }
    });

    test('they arrive as numbers on the domain object', () {
      final contract = contracts.first;
      expect(contract.lotSize, isA<int>());
      expect(contract.strike, isA<double>());
      expect(contract.tickSize, isA<double>());
    });
  });

  group('§3.2 hazard 4 — no CE/PE field; derive from the symbol suffix', () {
    test('the source rows carry no option-type field', () {
      final row = (jsonDecode(rawFixture) as List).first as Map<String, dynamic>;
      expect(row.keys.any((k) => k.toLowerCase().contains('option')), isFalse);
    });

    test('the suffix decides', () {
      expect(optionTypeOf('NIFTY15SEP2621900CE'), OptionType.call);
      expect(optionTypeOf('NIFTY15SEP2621900PE'), OptionType.put);
      expect(() => optionTypeOf('NIFTY15SEP2621900XX'), throwsFormatException);
    });

    test('every fixture contract resolved to a type, and both appear', () {
      final calls = contracts.where((c) => c.optionType == OptionType.call);
      final puts = contracts.where((c) => c.optionType == OptionType.put);
      expect(calls, isNotEmpty);
      expect(puts, isNotEmpty);
      expect(calls.length + puts.length, contracts.length);
    });
  });

  group('filtering', () {
    test('the fixture yields its full 590 contracts', () {
      expect(contracts, hasLength(590));
    });

    test('non-Nifty and non-OPTIDX rows are excluded', () {
      final mixed = jsonEncode([
        {
          'token': '1',
          'symbol': 'NIFTY15SEP2621900CE',
          'name': 'NIFTY',
          'expiry': '15SEP2026',
          'strike': '2190000.000000',
          'lotsize': '65',
          'instrumenttype': 'OPTIDX',
          'exch_seg': 'NFO',
          'tick_size': '5.000000',
        },
        // Right name, wrong instrument type — a Nifty future, not an option.
        {
          'token': '2',
          'symbol': 'NIFTY25SEP26FUT',
          'name': 'NIFTY',
          'expiry': '25SEP2026',
          'strike': '0.000000',
          'lotsize': '65',
          'instrumenttype': 'FUTIDX',
          'exch_seg': 'NFO',
          'tick_size': '5.000000',
        },
        // Right type, wrong underlying.
        {
          'token': '3',
          'symbol': 'BANKNIFTY15SEP2650000CE',
          'name': 'BANKNIFTY',
          'expiry': '15SEP2026',
          'strike': '5000000.000000',
          'lotsize': '15',
          'instrumenttype': 'OPTIDX',
          'exch_seg': 'NFO',
          'tick_size': '5.000000',
        },
      ]);

      final parsed = parseNiftyOptions(mixed);
      expect(parsed, hasLength(1));
      expect(parsed.single.token, '1');
    });

    test('a malformed row is skipped, not fatal', () {
      // One bad record out of 145,599 must not empty the search screen.
      final withJunk = jsonEncode([
        {
          'token': '1',
          'symbol': 'NIFTY15SEP2621900CE',
          'name': 'NIFTY',
          'expiry': '15SEP2026',
          'strike': '2190000.000000',
          'lotsize': '65',
          'instrumenttype': 'OPTIDX',
          'exch_seg': 'NFO',
          'tick_size': '5.000000',
        },
        {
          'token': '2',
          'symbol': 'NIFTY15SEP2621950CE',
          'name': 'NIFTY',
          'expiry': 'NOT-A-DATE',
          'strike': '2195000.000000',
          'lotsize': '65',
          'instrumenttype': 'OPTIDX',
          'exch_seg': 'NFO',
          'tick_size': '5.000000',
        },
      ]);

      final parsed = parseNiftyOptions(withJunk);
      expect(parsed, hasLength(1));
      expect(parsed.single.token, '1');
    });

    test('a non-array payload is rejected outright', () {
      expect(() => parseNiftyOptions('{"error":"nope"}'), throwsFormatException);
    });
  });
}
