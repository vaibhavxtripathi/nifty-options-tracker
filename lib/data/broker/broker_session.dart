import 'dart:async';

import '../../core/error/failures.dart';
import '../../core/logging/logger.dart';
import 'angel_client.dart';
import 'feed_socket.dart';

/// Owns the broker's identity: login, silent refresh, and the current tokens.
///
/// **It never touches Firebase, and Firebase never touches it.** That is
/// CLAUDE.md's two-auth-systems rule, and this file is where it is enforced in
/// practice rather than merely stated. Every failure here is a
/// [BrokerAuthFailure] — never an [AuthFailure] — so nothing in this trust
/// domain can reach the app's sign-out path.
///
/// Phase 0 measured why that separation is load-bearing rather than tidy: a
/// rate-limited WebSocket rejection is byte-identical to a credential
/// rejection, so a classifier that mapped broker trouble onto app auth would
/// sign a user out over a two-second throttle.
final class BrokerSession {
  BrokerSession({required this.client, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// The broker's REST API. Public because it is how this session is
  /// configured — a fake is what makes the expiry and coalescing rules
  /// testable without a network or a TOTP window.
  final BrokerRestClient client;
  final DateTime Function() _clock;

  BrokerTokens? _tokens;

  /// In-flight login or refresh, so concurrent callers share one round trip.
  ///
  /// Without this, a reconnect storm would fire a login per attempt — and
  /// since the login endpoint is rate-limited and each attempt burns a TOTP
  /// window, that turns a transient blip into a lockout.
  Future<BrokerTokens>? _pending;

  bool get isConfigured => client.config.isConfigured;

  bool get hasSession => _tokens != null;

  /// The current tokens, or null if no session has been established.
  BrokerTokens? get tokens => _tokens;

  /// Credentials for the socket handshake, read fresh on every call.
  ///
  /// A closure rather than a snapshot: a reconnect after a refresh must use
  /// the new JWT, and capturing the value at construction is precisely how a
  /// reconnect ends up presenting an expired one.
  FeedCredentials requireCredentials() {
    final current = _tokens;
    if (current == null) {
      throw const BrokerAuthFailure('No market-data session.');
    }
    return FeedCredentials(
      jwtToken: current.jwtToken,
      apiKey: client.config.apiKey,
      clientCode: client.config.clientCode,
      feedToken: current.feedToken,
    );
  }

  /// Returns a usable session, logging in or refreshing only if needed.
  Future<BrokerTokens> ensureSession() {
    final current = _tokens;
    if (current != null && !_isExpired(current)) {
      return Future.value(current);
    }
    // Anything reaching here is absent or past the 05:00 IST cutoff, and a
    // token past the cutoff cannot be refreshed — the refresh token died with
    // it. So this is always a fresh login; renewing a *live* token is
    // [renew]'s job, not this one.
    return _coalesce(_login);
  }

  /// Forces a renewal after the server rejected the current token.
  ///
  /// Tries a silent refresh first and falls back to a full login, because
  /// Phase 0 confirmed `generateTokens` needs no TOTP — spending a TOTP window
  /// on something a refresh can fix is both slower and closer to the rate
  /// limit.
  Future<BrokerTokens> renew() {
    return _coalesce(() async {
      final existing = _tokens;
      if (existing != null && !_isExpired(existing)) {
        try {
          return await _refresh(existing);
        } on AppFailure {
          Log.warn('Silent refresh failed; falling back to a full sign-in');
        }
      }
      return _login();
    });
  }

  /// Drops the session without touching the app's own sign-in.
  void clear() {
    _tokens = null;
  }

  Future<BrokerTokens> _coalesce(Future<BrokerTokens> Function() action) {
    final inFlight = _pending;
    if (inFlight != null) return inFlight;

    final future = action();
    _pending = future;
    return future.whenComplete(() => _pending = null);
  }

  Future<BrokerTokens> _login() async {
    // Deliberately logs that a sign-in happened and nothing about what was
    // sent. The TOTP code and the MPIN never become log arguments.
    Log.info('Establishing a market-data session');
    final tokens = await client.login();
    _tokens = tokens;
    return tokens;
  }

  Future<BrokerTokens> _refresh(BrokerTokens current) async {
    Log.info('Renewing the market-data session');
    final tokens = await client.refresh(current);
    _tokens = tokens;
    return tokens;
  }

  /// Whether [tokens] has passed the daily 05:00 IST cutoff.
  ///
  /// Angel One expires every token at 05:00 IST regardless of when it was
  /// issued, so this is a wall-clock boundary rather than an age — the same
  /// shape as the contract cache's 08:30 rule, and wrong in the same two
  /// directions if treated as a duration. A token issued at 04:55 is dead in
  /// five minutes; one issued at 05:05 is good for nearly a day.
  bool _isExpired(BrokerTokens tokens) =>
      tokens.issuedAt.toUtc().isBefore(_lastExpiryBoundary(_clock()));

  static const Duration _istOffset = Duration(hours: 5, minutes: 30);
  static const int _expiryHourIst = 5;

  /// The most recent 05:00 IST at or before [now], as UTC.
  static DateTime _lastExpiryBoundary(DateTime now) {
    final nowIst = now.toUtc().add(_istOffset);
    var boundary = DateTime.utc(
      nowIst.year,
      nowIst.month,
      nowIst.day,
      _expiryHourIst,
    );
    if (boundary.isAfter(nowIst)) {
      boundary = boundary.subtract(const Duration(days: 1));
    }
    return boundary.subtract(_istOffset);
  }
}
