import 'package:flutter/material.dart';

import '../../../domain/entities/option_contract.dart';

/// One contract in the result list.
///
/// Presentation only — every value it shows was computed at the mapping
/// boundary. There is no arithmetic in this file beyond formatting.
class ContractRow extends StatelessWidget {
  const ContractRow({
    required this.contract,
    required this.isNearestExpiry,
    super.key,
  });

  final OptionContract contract;

  /// Marks this week's contract, which is what a trader searching a strike
  /// almost always wants (§5.3).
  final bool isNearestExpiry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCall = contract.optionType == OptionType.call;

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isCall
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.tertiaryContainer,
        child: Text(
          contract.optionType.code,
          style: theme.textTheme.labelMedium?.copyWith(
            color: isCall
                ? theme.colorScheme.onPrimaryContainer
                : theme.colorScheme.onTertiaryContainer,
          ),
        ),
      ),
      title: Text(_formatStrike(contract.strike)),
      subtitle: Text(
        '${_formatExpiry(contract.expiry)}  ·  ${contract.lotSize} per lot',
      ),
      trailing: isNearestExpiry
          ? Chip(
              label: const Text('Nearest'),
              labelStyle: theme.textTheme.labelSmall,
              visualDensity: VisualDensity.compact,
              side: BorderSide(color: theme.colorScheme.outlineVariant),
            )
          : null,
    );
  }
}

/// Whole rupees with a thousands separator: strikes are always round numbers,
/// and "₹21,900.00" is two characters of noise per row.
String _formatStrike(double strike) {
  final whole = strike.round().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < whole.length; i++) {
    if (i > 0 && (whole.length - i) % 3 == 0) buffer.write(',');
    buffer.write(whole[i]);
  }
  return '₹$buffer';
}

const List<String> _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatExpiry(DateTime expiry) =>
    '${expiry.day} ${_monthNames[expiry.month - 1]} ${expiry.year}';
