/// A signed-in application user.
///
/// Deliberately *not* a wrapper around Firebase's `User`. Firebase is one
/// possible source of identity; the rest of the app must not be able to tell.
/// The mapping happens once, in the data layer, so that deleting
/// `presentation/` — or swapping Firebase out entirely — leaves this untouched.
final class AppUser {
  const AppUser({
    required this.id,
    this.email,
    this.displayName,
  });

  /// Stable identifier for this user, unique within the app's identity
  /// provider. Not an email: an email can change, this cannot.
  final String id;

  /// Null for sign-in methods that do not surface one.
  final String? email;

  final String? displayName;

  /// What to show when greeting the user, falling back through the fields
  /// that may be absent. Never empty.
  String get label {
    final name = displayName;
    if (name != null && name.isNotEmpty) return name;
    final address = email;
    if (address != null && address.isNotEmpty) return address;
    return 'Signed in';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppUser &&
          other.id == id &&
          other.email == email &&
          other.displayName == displayName;

  @override
  int get hashCode => Object.hash(id, email, displayName);

  /// Deliberately omits [email] and [displayName]: this object reaches the
  /// logger, and a user's address is personal data that does not belong in a
  /// log line.
  @override
  String toString() => 'AppUser($id)';
}
