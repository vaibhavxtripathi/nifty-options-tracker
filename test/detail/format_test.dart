@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:nifty_options_tracker/presentation/detail/format.dart';

/// Display formatting, including the cases that actually break a layout.
///
/// §7 rules out widget tests, so the rendering logic that carries risk lives
/// in pure functions and is tested here instead.
void main() {
  group('criterion 4 — three-digit percentages', () {
    test('renders a +200% move without truncation', () {
      // §3.5 trap 4: this is ordinary for an option, not an edge case. A
      // formatter that assumed equity-sized moves would clip it.
      expect(formatPercent(212.5), '+212.50%');
      expect(formatPercent(-212.5), '-212.50%');
    });

    test('renders a four-digit move too', () {
      // A contract going from ₹0.05 to ₹5.00 is +9900%, and near expiry that
      // happens. Nothing here caps the width.
      expect(formatPercent(9900), '+9900.00%');
    });

    test('the sign is explicit on gains', () {
      // "+112.5%" and "112.5%" read differently at a glance on a price screen.
      expect(formatPercent(112.5).startsWith('+'), isTrue);
      expect(formatPercent(-112.5).startsWith('-'), isTrue);
    });

    // NOTE: these inputs are **synthetic**. Two live captures on 2026-09-11 —
    // one liquid strike and six near-expiry OTM calls — reached only -33%, so
    // no recorded fixture contains a three-digit move. The layout must handle
    // it per §3.5 trap 4, and saying plainly that the input is invented beats
    // implying fixture coverage that does not exist.
    test('a zero change still renders', () {
      expect(formatPercent(0), '0.00%');
    });
  });

  group('criterion 5 — absent values render as an em dash, never zero', () {
    test('a null percent change', () {
      // `close == 0` yields null, and "0.00%" would claim the price is
      // unchanged — a different and wrong statement.
      expect(formatPercent(null), emDash);
    });

    test('a null price', () {
      // An empty book side. "₹0.00" reads as a real quote at zero.
      expect(formatRupees(null), emDash);
    });

    test('a null quantity', () {
      expect(formatQuantity(null), emDash);
    });
  });

  group('rupee formatting', () {
    test('keeps paise, because options trade in them', () {
      expect(formatRupees(0.40), '₹0.40');
      expect(formatRupees(0.05), '₹0.05');
    });

    test('formats the values from the recorded fixture', () {
      expect(formatRupees(10.75), '₹10.75');
      expect(formatRupees(13.55), '₹13.55');
      expect(formatRupees(483.90), '₹483.90');
    });

    test('rounds carrying into the rupee part', () {
      // 0.999 must become ₹1.00, not ₹0.100 — the carry has to move into the
      // rupee component rather than producing a three-digit paise field.
      expect(formatRupees(0.999), '₹1.00');
      expect(formatRupees(9.999), '₹10.00');
      // Not 9.995: that is stored as slightly *under* 9.995 in binary floating
      // point and correctly rounds down. Asserting ₹10.00 there would be
      // testing a wrong expectation rather than the formatter.
      expect(formatRupees(9.995), '₹9.99');
    });

    test('handles negatives', () {
      expect(formatRupees(-12.5), '-₹12.50');
    });

    test('groups large prices', () {
      expect(formatRupees(21900), '₹21,900.00');
    });
  });

  group('quantity formatting uses Indian grouping', () {
    test('a six-figure volume reads in lakhs', () {
      // 710190 is 7,10,190 to a reader of an Indian market screen, not
      // 710,190. The app shows Indian data; western grouping reads as foreign.
      expect(formatQuantity(710190), '7,10,190');
      expect(formatQuantity(335920), '3,35,920');
    });

    test('small numbers are unchanged', () {
      expect(formatQuantity(65), '65');
      expect(formatQuantity(999), '999');
    });

    test('the first grouping is at four digits', () {
      expect(formatQuantity(1000), '1,000');
      expect(formatQuantity(99999), '99,999');
      expect(formatQuantity(100000), '1,00,000');
    });

    test('a crore groups correctly', () {
      expect(formatQuantity(10000000), '1,00,00,000');
    });
  });

  group('the replay banner timestamp', () {
    test('reads as a date a human would say', () {
      expect(formatRecordedAt(DateTime(2026, 9, 11, 13, 55)), '11 Sep 13:55');
    });

    test('pads single-digit times', () {
      expect(formatRecordedAt(DateTime(2026, 9, 11, 9, 5)), '11 Sep 09:05');
    });
  });
}
