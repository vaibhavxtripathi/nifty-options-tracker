/// Builders for the WebSocket **request** frames (§3.3).
///
/// Requests are JSON **text**; responses are binary. That asymmetry is worth
/// stating because it inverts the Upstox design, where requests were
/// JSON-encoded binary — and because a decoder that assumes every frame is a
/// packet will try to parse the server's `"pong"` text reply as market data.
///
/// Pure string-building with no socket and no state, so the frames can be
/// asserted byte-for-byte in a test.
library;

import 'dart:convert';


/// §3.3 `action` values.
const int _actionSubscribe = 1;
const int _actionUnsubscribe = 0;

/// §3.3 `mode` values. SNAP_QUOTE is the only one carrying open interest *and*
/// the best-bid/ask book *and* previous close, which is exactly the set §3.4
/// requires — this is requirements-driven, not preference.
const int modeSnapQuote = 3;

/// §3.3 `exchangeType`. Nifty options are NSE_FO.
const int exchangeNseFo = 2;

/// The literal keepalive payload. §3.3: mandatory every 10 seconds, and the
/// single most common cause of "the socket just died" reports.
const String pingFrame = 'ping';

/// The server's reply to [pingFrame]. Arrives as **text**, and one shows up on
/// connect before any ping is sent (measured in Phase 0).
const String pongFrame = 'pong';

/// A subscribe frame for [tokens] in SNAP_QUOTE mode.
///
/// [correlationId] is echoed by the server, so it is how a reply is matched to
/// the request that caused it.
String subscribeFrame({
  required Iterable<String> tokens,
  required String correlationId,
}) => _frame(
  action: _actionSubscribe,
  tokens: tokens,
  correlationId: correlationId,
);

/// An unsubscribe frame. Identical but for `action`.
///
/// This is the frame that makes "the subscription is cleanly closed when the
/// user backs out" true on the wire rather than merely in local state.
String unsubscribeFrame({
  required Iterable<String> tokens,
  required String correlationId,
}) => _frame(
  action: _actionUnsubscribe,
  tokens: tokens,
  correlationId: correlationId,
);

String _frame({
  required int action,
  required Iterable<String> tokens,
  required String correlationId,
}) {
  final list = tokens.toList(growable: false);
  if (list.isEmpty) {
    throw ArgumentError.value(tokens, 'tokens', 'must not be empty');
  }
  return jsonEncode({
    'correlationID': correlationId,
    'action': action,
    'params': {
      'mode': modeSnapQuote,
      'tokenList': [
        {'exchangeType': exchangeNseFo, 'tokens': list},
      ],
    },
  });
}
