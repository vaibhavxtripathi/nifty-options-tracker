/// The closed set of things that can go wrong, as the app models them.
///
/// Sealed on purpose. Every render site `switch`es over this, so adding a
/// variant later is a compile error at each one — an unhandled error state
/// cannot ship. That property is the whole reason this hierarchy exists
/// instead of passing strings around.
///
/// All five variants are declared now even though Phase 1 can only produce
/// [AuthFailure] and [NetworkFailure]. Declaring them up front is what makes
/// the exhaustiveness guarantee worth having; adding them one phase at a time
/// would silently widen every existing switch instead.
sealed class AppFailure {
  const AppFailure(this.message);

  /// Safe to show a user. Never contains a token, a raw provider response, or
  /// an exception's `toString()` — any of which can carry credential material.
  final String message;

  @override
  String toString() => '$runtimeType($message)';
}

/// The app's own sign-in failed: Firebase, and only Firebase.
///
/// This is the **only** failure that may sign a user out. It must never be
/// constructed in response to a broker problem — see [BrokerAuthFailure].
final class AuthFailure extends AppFailure {
  const AuthFailure(super.message, {this.kind = AuthFailureKind.unknown});

  final AuthFailureKind kind;
}

/// The four states §5.2 requires the auth screens to render, plus a fallback.
///
/// A closed enum rather than free text so the UI decides the wording and the
/// data layer only classifies. It also keeps provider-specific strings from
/// reaching the screen.
enum AuthFailureKind {
  /// Wrong password, unknown account, or malformed email. Deliberately one
  /// state: Firebase collapses these into `invalid-credential` on projects
  /// with email-enumeration protection, and distinguishing them would leak
  /// whether an account exists.
  invalidCredentials,
  emailAlreadyInUse,
  weakPassword,
  unknown,
}

/// The **broker** session is unusable — expired, rejected, or throttled.
///
/// Structurally separate from [AuthFailure] because the two auth systems have
/// different trust domains and different blast radii. This one shows
/// "reconnecting to market data" and the user stays signed in.
///
/// Phase 0 measured why this separation is load-bearing: Angel One's
/// WebSocket rate-limit rejection is byte-identical to an auth rejection, so a
/// classifier that mapped broker trouble onto [AuthFailure] would sign a user
/// out over a two-second throttle.
final class BrokerAuthFailure extends AppFailure {
  const BrokerAuthFailure(super.message);
}

/// The market-data socket dropped, stalled, or refused to open.
final class FeedFailure extends AppFailure {
  const FeedFailure(super.message);
}

/// The instrument master could not be fetched, parsed, or cached.
final class ContractFailure extends AppFailure {
  const ContractFailure(super.message);
}

/// No usable network. Distinct from every failure above because it is the
/// user's connection at fault, not a credential, and retrying is reasonable.
final class NetworkFailure extends AppFailure {
  const NetworkFailure(super.message);
}
