import '../entities/feed_state.dart';
import '../entities/market_tick.dart';

/// Live market data for one instrument at a time.
///
/// The seam between the UI and everything the broker requires — sockets,
/// tokens, TOTP, binary offsets, reconnection. None of that appears in this
/// signature, which is the point: the detail screen in Phase 4 asks for ticks
/// by token and is told nothing about how they arrive, and a replay
/// implementation satisfies the same contract as a live one.
abstract interface class MarketDataRepository {
  /// Ticks for [token], already conflated to a render-friendly rate.
  ///
  /// The subscription is opened when the stream is listened to and closed when
  /// the last listener goes away. Tying the socket's lifetime to the stream's
  /// is what makes "the subscription is cleanly closed when the user backs
  /// out" structural rather than something a screen has to remember.
  Stream<MarketTick> ticks(String token);

  /// Connection state, so the UI can tell *market closed* from *socket
  /// broken* — a distinction Angel One offers no help with.
  Stream<FeedState> get states;

  /// Releases everything. Called when the app shuts the feed down.
  Future<void> dispose();
}
