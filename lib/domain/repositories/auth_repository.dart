import '../entities/app_user.dart';

/// Who may open the app.
///
/// This is the Firebase trust domain and nothing else. It has no knowledge of
/// the broker session, by construction — a market-data failure must never be
/// able to reach a method on this interface.
///
/// Implementations throw [AppFailure] and nothing else; provider-specific
/// exception types stop at the data layer.
abstract interface class AuthRepository {
  /// Emits the current user, or null when signed out.
  ///
  /// Emits nothing until the identity provider has restored any persisted
  /// session, which is what lets the router tell *unknown* from *signed out*.
  /// Persistence is the provider's job; the app writes no tokens itself.
  Stream<AppUser?> authStateChanges();

  /// The user right now, without waiting for the stream. Null when signed out
  /// or when the session has not been restored yet.
  AppUser? get currentUser;

  /// Returns null if the user dismissed the account picker.
  ///
  /// Cancellation is normal behaviour, not an error: it returns rather than
  /// throwing so callers cannot accidentally render a banner for it.
  Future<AppUser?> signInWithGoogle();

  Future<AppUser> signInWithEmail({
    required String email,
    required String password,
  });

  Future<AppUser> registerWithEmail({
    required String email,
    required String password,
  });

  Future<void> signOut();
}
