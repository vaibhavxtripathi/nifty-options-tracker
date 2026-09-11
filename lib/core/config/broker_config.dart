/// The Angel One credentials, kept **separate from [AppConfig]** on purpose.
///
/// CLAUDE.md's two-auth-systems rule says Firebase and the broker session are
/// different trust domains that never reference each other. A single config
/// class holding both would be exactly such a reference: any file needing the
/// Google client ID would also be holding a trading credential, and the
/// architecture test that scans the auth layer for broker vocabulary would
/// have to start making exceptions.
///
/// Two classes, two imports, no shared type. The separation costs one file.
///
/// ---
///
/// **Security, stated plainly, because Phase 1 deferred this decision to here
/// and the honest answer is uncomfortable.**
///
/// These credentials authenticate a **full trading account**. Angel One issues
/// no read-only market-data credential — that is the single biggest thing lost
/// in the move from Upstox, whose analytics token was read-only by
/// construction.
///
/// Neither `--dart-define` nor a bundled `.env` asset protects them from
/// anyone holding the APK. A dart-define is a compiled-in string constant,
/// recoverable with `strings`; a `.env` asset is a file sitting in the archive,
/// recoverable by unzipping it. **Neither is encryption and neither should be
/// described as security.** The choice between them is about which is less bad
/// operationally, not about achieving secrecy.
///
/// `--dart-define` is chosen for two reasons that are about operations rather
/// than strength:
///
/// 1. It cannot be committed by accident. A `.env` file lives in the working
///    tree and is one `git add -A` away from the history; a build flag lives in
///    the build command.
/// 2. It keeps the credentials out of the app's asset bundle, so no code path
///    can read them off disk at runtime and no crash reporter can attach them
///    to a bug report.
///
/// The app is read-only **by construction** — it never calls a mutating
/// endpoint, and `test/architecture_test.dart` fails the build if one appears.
/// But that is a property of this code, not of the credential. The README's
/// security note is where this gets said to a reader rather than to a compiler.
final class BrokerConfig {
  const BrokerConfig({
    required this.apiKey,
    required this.clientCode,
    required this.mpin,
    required this.totpSecret,
  });

  /// Reads the build environment.
  ///
  /// Every value defaults to empty rather than throwing, so a build with no
  /// broker credentials still runs: auth and contract search work without
  /// them, and only the feed is unavailable. A hard failure here would make
  /// the whole app unlaunchable for anyone who only wanted to see the search
  /// screen — including a reviewer without an Angel One account.
  factory BrokerConfig.fromEnvironment() => const BrokerConfig(
    apiKey: String.fromEnvironment(_apiKeyKey),
    clientCode: String.fromEnvironment(_clientCodeKey),
    mpin: String.fromEnvironment(_mpinKey),
    totpSecret: String.fromEnvironment(_totpSecretKey),
  );

  /// From the SmartAPI developer console. Sent as the `X-PrivateKey` header —
  /// one of the four Phase 0 proved are actually enforced.
  final String apiKey;

  /// The Angel One login / client code.
  final String clientCode;

  /// The trading MPIN.
  final String mpin;

  /// Base32 TOTP secret, used to generate the 6-digit code locally at login.
  final String totpSecret;

  /// Whether a live broker session can be attempted at all.
  ///
  /// The feed degrades to replay when this is false, which is what lets the
  /// app be demonstrated — and reviewed — without credentials.
  bool get isConfigured =>
      apiKey.isNotEmpty &&
      clientCode.isNotEmpty &&
      mpin.isNotEmpty &&
      totpSecret.isNotEmpty;

  /// Names which values are missing, without revealing any of them.
  ///
  /// Exists so a misconfigured build produces an actionable message instead of
  /// an `AB1050` that Phase 0 showed is indistinguishable from a wrong secret,
  /// a rotated secret, or an unregistered account.
  List<String> get missingKeys => [
    if (apiKey.isEmpty) _apiKeyKey,
    if (clientCode.isEmpty) _clientCodeKey,
    if (mpin.isEmpty) _mpinKey,
    if (totpSecret.isEmpty) _totpSecretKey,
  ];

  /// Reports only whether it is configured. **Never** the values.
  ///
  /// The logger bans token material, and the cheapest way to honour that is to
  /// make this object unable to print any.
  @override
  String toString() => 'BrokerConfig(configured: $isConfigured)';

  static const String _apiKeyKey = 'ANGEL_API_KEY';
  static const String _clientCodeKey = 'ANGEL_CLIENT_CODE';
  static const String _mpinKey = 'ANGEL_MPIN';
  static const String _totpSecretKey = 'ANGEL_TOTP_SECRET';
}
