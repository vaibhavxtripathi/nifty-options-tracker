import '../../core/error/failures.dart';

/// The §5.4 connection state machine.
///
/// ```
/// disconnected → connecting → connected → subscribed
///                    ↑                        │
///                    └───── reconnecting ←────┘
///                               │
///                               ↓ (retries exhausted)
///                             failed
/// ```
///
/// Sealed so that every UI state in Phase 4 derives from this mechanically:
/// a `switch` over it is exhaustiveness-checked, and adding a state later
/// becomes a compile error at each render site rather than a screen that
/// silently shows nothing.
///
/// This is also what lets the UI distinguish *market closed* from *connection
/// broken* — a distinction Angel One gives no help with, so it has to be
/// structural.
sealed class FeedState {
  const FeedState();
}

final class FeedDisconnected extends FeedState {
  const FeedDisconnected();
}

final class FeedConnecting extends FeedState {
  const FeedConnecting();
}

/// Socket open, handshake accepted, nothing subscribed yet.
final class FeedConnected extends FeedState {
  const FeedConnected();
}

/// Receiving data for at least one instrument.
final class FeedSubscribed extends FeedState {
  const FeedSubscribed(this.tokens);

  final Set<String> tokens;
}

/// Dropped, and retrying with backoff.
///
/// [attempt] is carried so the UI can say "reconnecting" without implying it
/// has given up, and so a test can assert the backoff sequence.
final class FeedReconnecting extends FeedState {
  const FeedReconnecting({required this.attempt, required this.nextDelay});

  final int attempt;
  final Duration nextDelay;
}

/// Retries exhausted. Terminal until something asks it to try again.
final class FeedFailed extends FeedState {
  const FeedFailed(this.failure);

  /// Always a [FeedFailure] or [BrokerAuthFailure] — never an [AuthFailure].
  /// A broker problem must never be able to sign the user out.
  final AppFailure failure;
}
