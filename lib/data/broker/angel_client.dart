import 'dart:convert';
import 'dart:io';

import '../../core/error/failures.dart';
import '../../core/config/broker_config.dart';
import 'totp.dart';

/// What [BrokerSession] needs from the broker's REST API.
///
/// An interface so the session's rules — the 05:00 IST expiry boundary,
/// refresh-before-login, and coalescing concurrent callers — can be tested
/// without a network, a real TOTP secret, or a rate limit. Those rules are the
/// part with the interesting behaviour; the HTTP is the part that would make
/// them untestable.
abstract interface class BrokerRestClient {
  BrokerConfig get config;

  Future<BrokerTokens> login();

  Future<BrokerTokens> refresh(BrokerTokens current);

  Future<bool> validate(BrokerTokens tokens);
}

/// The Angel One REST surface — **read-only endpoints only, forever**.
///
/// Three endpoints exist here and no others: login, silent refresh, and a
/// profile read used to validate a session. There is deliberately no helper
/// that takes an arbitrary path, because the moment one exists, adding an
/// order endpoint becomes a one-line change rather than a conscious decision.
/// `test/architecture_test.dart` fails the build on any mutating endpoint
/// name, and that test is the backstop rather than the plan.
///
/// This matters more here than it would with a read-only broker token: the
/// credential authenticates a full trading account, so a mutating call that
/// slipped in would place a real order with real money.
final class AngelClient implements BrokerRestClient {
  AngelClient({
    required this.config,
    HttpClient Function()? httpClientFactory,
    DateTime Function()? clock,
  }) : _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _clock = clock ?? DateTime.now;

  @override
  final BrokerConfig config;

  final HttpClient Function() _httpClientFactory;
  final DateTime Function() _clock;

  static const String baseUrl = 'https://apiconnect.angelone.in';
  static const String loginPath =
      '/rest/auth/angelbroking/user/v1/loginByPassword';
  static const String refreshPath =
      '/rest/auth/angelbroking/jwt/v1/generateTokens';
  static const String profilePath =
      '/rest/secure/angelbroking/user/v1/getProfile';

  /// Logs in with a locally generated TOTP.
  ///
  /// Waits for the next time step when the current one is nearly over: a code
  /// that expires mid-flight is rejected with `AB1050`, which is
  /// indistinguishable from a wrong secret and cost Phase 0 real time to
  /// diagnose. Two seconds of latency is cheaper than that ambiguity.
  @override
  Future<BrokerTokens> login() async {
    if (!config.isConfigured) {
      throw BrokerAuthFailure(
        'Market data is not configured (${config.missingKeys.join(", ")}).',
      );
    }

    if (totpSecondsRemaining(at: _clock()) < 3) {
      await Future<void>.delayed(const Duration(seconds: 3));
    }

    final String code;
    try {
      code = generateTotp(base32Secret: config.totpSecret, at: _clock());
    } on FormatException {
      // A malformed secret would otherwise surface as AB1050 — the same error
      // as an account-side problem — so it is worth its own message.
      throw const BrokerAuthFailure(
        'The market-data secret is not valid base32.',
      );
    }

    final body = await _post(loginPath, {
      'clientcode': config.clientCode,
      'password': config.mpin,
      'totp': code,
    });

    return BrokerTokens.fromResponse(body, issuedAt: _clock());
  }

  /// Renews the session with no TOTP.
  ///
  /// Phase 0 confirmed `generateTokens` accepts the jwt+refresh pair and
  /// returns a working new JWT *and* a fresh feed token — verified by calling
  /// `getProfile` with it rather than merely checking it was non-empty. That
  /// is what lets §5.6 renew silently and never re-prompt mid-session.
  @override
  Future<BrokerTokens> refresh(BrokerTokens current) async {
    final body = await _post(refreshPath, {
      'refreshToken': current.refreshToken,
    }, jwtToken: current.jwtToken);

    return BrokerTokens.fromResponse(body, issuedAt: _clock());
  }

  /// A read-only profile fetch, used to prove a token actually works.
  ///
  /// Checking that a refresh returned a non-empty string proves nothing; this
  /// proves the string authenticates.
  @override
  Future<bool> validate(BrokerTokens tokens) async {
    try {
      await _post(profilePath, null, jwtToken: tokens.jwtToken, isGet: true);
      return true;
    } on AppFailure {
      return false;
    }
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, String>? payload, {
    String? jwtToken,
    bool isGet = false,
  }) async {
    final client = _httpClientFactory();
    try {
      final uri = Uri.parse('$baseUrl$path');
      final request = isGet
          ? await client.getUrl(uri)
          : await client.postUrl(uri);

      _applyHeaders(request, jwtToken: jwtToken);
      if (payload != null) {
        request.write(jsonEncode(payload));
      }

      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final text = await response.transform(utf8.decoder).join();

      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw const BrokerAuthFailure('Unexpected response from the broker.');
      }

      // **Classify on the body, not the status code.** Phase 0 measured a
      // missing Authorization header returning HTTP 200 with "Token missing"
      // in the body — so any handling that keys off the code alone reads that
      // as success. This is the concrete reason §4.4 says to check `status`.
      if (decoded['status'] != true) {
        throw BrokerAuthFailure(_messageFor(decoded));
      }

      final data = decoded['data'];
      return data is Map<String, dynamic> ? data : decoded;
    } on SocketException {
      throw const NetworkFailure('No connection.');
    } on HttpException {
      throw const BrokerAuthFailure('Could not reach the market-data service.');
    } on FormatException {
      throw const BrokerAuthFailure('Unexpected response from the broker.');
    } finally {
      client.close();
    }
  }

  /// All nine headers, though Phase 0 proved only four are enforced
  /// (`X-PrivateKey`, `X-SourceID`, `X-MACAddress`, `Authorization`).
  ///
  /// The enforced set is undocumented and could widen without notice, and
  /// matching the official SDK costs a few bytes. The measurement's value is
  /// diagnostic: when a request 400s, those four are where to look.
  void _applyHeaders(HttpClientRequest request, {String? jwtToken}) {
    request.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/json')
      ..set(HttpHeaders.acceptHeader, 'application/json')
      ..set('X-UserType', 'USER')
      ..set('X-SourceID', 'WEB')
      // Stable placeholders: §3.1 says these are checked for presence and
      // shape, never for correctness, and real device fingerprinting is out of
      // scope.
      ..set('X-ClientLocalIP', '192.168.1.1')
      ..set('X-ClientPublicIP', '106.193.147.98')
      ..set('X-MACAddress', 'fe80::216:3eff:fe1a:1a1a')
      ..set('X-PrivateKey', config.apiKey);

    if (jwtToken != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $jwtToken');
    }
  }

  /// A user-safe message. **Never** echoes the raw response, which can carry
  /// credential material.
  String _messageFor(Map<String, dynamic> body) {
    final code = body['errorcode'];
    // AB1050 is the one worth naming: Phase 0 established it means the TOTP
    // and client do not match, which is account-side far more often than it is
    // a code bug.
    if (code == 'AB1050') {
      return 'Market-data sign-in was rejected. Check the account setup.';
    }
    return 'Market data is unavailable right now.';
  }
}

/// The three tokens a session is made of.
///
/// Deliberately has no `toString` that could print one.
final class BrokerTokens {
  const BrokerTokens({
    required this.jwtToken,
    required this.refreshToken,
    required this.feedToken,
    required this.issuedAt,
  });

  factory BrokerTokens.fromResponse(
    Map<String, dynamic> data, {
    required DateTime issuedAt,
  }) {
    final jwt = data['jwtToken'];
    final refresh = data['refreshToken'];
    final feed = data['feedToken'];
    if (jwt is! String || refresh is! String || feed is! String) {
      throw const BrokerAuthFailure('The broker returned an incomplete session.');
    }
    return BrokerTokens(
      jwtToken: jwt,
      refreshToken: refresh,
      feedToken: feed,
      issuedAt: issuedAt,
    );
  }

  final String jwtToken;
  final String refreshToken;
  final String feedToken;
  final DateTime issuedAt;

  /// Never prints a token.
  @override
  String toString() => 'BrokerTokens(issued $issuedAt)';
}
