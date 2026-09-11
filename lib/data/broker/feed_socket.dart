import 'dart:async';
import 'dart:io';

/// The socket, behind an interface.
///
/// Exists so `FeedConnection` can be driven by a fake in tests: the backoff
/// sequence, the 10-second ping cadence and resubscribe-on-reconnect are all
/// behaviours about *timing and ordering*, which cannot be asserted against a
/// real server without a live market and a great deal of luck.
abstract interface class FeedSocket {
  /// Frames from the server. Binary frames are market data; text frames are
  /// `"pong"` replies — callers must discriminate on type, not content.
  Stream<dynamic> get messages;

  void send(String frame);

  /// Why the server closed, when it did. §3.3 measured code **1001** with
  /// reason `"Connection Idle Timeout"` for an unpinged socket, so surfacing
  /// these turns a mystery disconnect into a diagnosis.
  int? get closeCode;
  String? get closeReason;

  Future<void> close();
}

/// Opens sockets. Injected so a test supplies fakes and can count how many
/// times a connection was attempted.
abstract interface class FeedSocketFactory {
  Future<FeedSocket> connect();
}

/// The live Angel One socket (§3.3).
final class AngelFeedSocket implements FeedSocket {
  AngelFeedSocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<dynamic> get messages => _socket;

  @override
  void send(String frame) => _socket.add(frame);

  @override
  int? get closeCode => _socket.closeCode;

  @override
  String? get closeReason => _socket.closeReason;

  @override
  Future<void> close() => _socket.close();
}

/// Connects with the four-header handshake.
///
/// There is **no 302 redirect** here — unlike Upstox, Angel One accepts the
/// auth headers directly, so no `HttpClient`/`followRedirects` dance is needed.
final class AngelFeedSocketFactory implements FeedSocketFactory {
  const AngelFeedSocketFactory({
    required this.url,
    required this.credentials,
  });

  final String url;

  /// Supplies fresh values per attempt: a reconnect after a token refresh must
  /// use the new JWT, not the one captured when this object was built.
  final FeedCredentials Function() credentials;

  @override
  Future<FeedSocket> connect() async {
    final creds = credentials();
    final socket = await WebSocket.connect(
      url,
      headers: {
        'Authorization': 'Bearer ${creds.jwtToken}',
        'x-api-key': creds.apiKey,
        'x-client-code': creds.clientCode,
        'x-feed-token': creds.feedToken,
      },
    ).timeout(const Duration(seconds: 15));
    return AngelFeedSocket(socket);
  }
}

/// The four values §3.3's handshake needs.
///
/// A plain carrier, deliberately without a `toString` that could put a token
/// into a log line.
final class FeedCredentials {
  const FeedCredentials({
    required this.jwtToken,
    required this.apiKey,
    required this.clientCode,
    required this.feedToken,
  });

  final String jwtToken;
  final String apiKey;
  final String clientCode;
  final String feedToken;

  /// Never prints the credentials themselves. The logger bans token values and
  /// the cheapest way to honour that is to make them unprintable here.
  @override
  String toString() => 'FeedCredentials($clientCode)';
}
