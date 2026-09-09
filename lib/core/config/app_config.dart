/// Typed access to injected configuration.
///
/// Phase 1 needs exactly one value, and it is not a secret: the Google **Web**
/// OAuth client ID. Broker credentials (`ANGEL_*`) are deliberately absent —
/// they belong to the broker session in Phase 3, and putting them here now
/// would give the auth layer a reference to the broker's trust domain that
/// CLAUDE.md forbids.
///
/// Values arrive via `--dart-define` rather than a bundled `.env` asset. An
/// asset ships inside the APK and can be extracted from it; a dart-define is
/// compiled in, which is no stronger against a determined reverse-engineer but
/// avoids putting a credentials *file* on disk. The Phase 3 broker secrets
/// will need this argument revisited and recorded properly.
final class AppConfig {
  const AppConfig({required this.googleServerClientId});

  /// Read from the build environment.
  factory AppConfig.fromEnvironment() => const AppConfig(
    googleServerClientId: String.fromEnvironment(_googleServerClientIdKey),
  );

  /// The OAuth **Web** client ID from the Firebase console, passed to
  /// `GoogleSignIn.initialize(serverClientId:)`.
  ///
  /// It must be the Web client ID, not the Android one. Supplying the Android
  /// ID yields a null `idToken` at sign-in with no useful error message —
  /// §5.2 calls this out as the most common Android setup mistake.
  ///
  /// Not a secret: an OAuth client ID is a public identifier, and the same
  /// value already ships inside `google-services.json`.
  final String googleServerClientId;

  /// Empty when the define was omitted. On Android, Google Sign-In still works
  /// without it via `google-services.json`, so this is a soft signal used to
  /// decide whether to pass the parameter at all.
  bool get hasGoogleServerClientId => googleServerClientId.isNotEmpty;

  static const String _googleServerClientIdKey = 'GOOGLE_SERVER_CLIENT_ID';
}
