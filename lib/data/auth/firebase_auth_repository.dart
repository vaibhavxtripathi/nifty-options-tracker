import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../core/error/failures.dart';
import '../../core/logging/logger.dart';
import '../../domain/entities/app_user.dart';
import '../../domain/repositories/auth_repository.dart';
import 'auth_failure_mapper.dart';

/// Firebase-backed [AuthRepository].
///
/// This is the only file in the app that names a Firebase or Google type.
/// Everything above it sees [AppUser] and [AppFailure], which is what keeps
/// `domain/` pure and makes the identity provider replaceable.
///
/// It has no reference to the broker, and must never acquire one.
final class FirebaseAuthRepository implements AuthRepository {
  FirebaseAuthRepository({
    FirebaseAuth? firebaseAuth,
    GoogleSignIn? googleSignIn,
  }) : _auth = firebaseAuth ?? FirebaseAuth.instance,
       _google = googleSignIn ?? GoogleSignIn.instance;

  final FirebaseAuth _auth;
  final GoogleSignIn _google;

  @override
  Stream<AppUser?> authStateChanges() => _auth.authStateChanges().map(_toAppUser);

  @override
  AppUser? get currentUser => _toAppUser(_auth.currentUser);

  @override
  Future<AppUser?> signInWithGoogle() async {
    try {
      // v7 replaced signIn() with authenticate(). It throws on cancellation
      // rather than returning null, so there is no null-return path here.
      final account = await _google.authenticate();

      // v7 hands back an idToken only — there is no accessToken on
      // GoogleSignInAuthentication any more. GoogleAuthProvider.credential
      // asserts merely that one of the two is non-null, so this is valid.
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        // Overwhelmingly means serverClientId was set to the Android OAuth
        // client ID instead of the Web one. Worth its own message because the
        // symptom is otherwise a sign-in that fails silently.
        Log.error('Google sign-in returned no idToken; check serverClientId');
        throw const AuthFailure('Could not complete Google sign-in.');
      }

      final credential = GoogleAuthProvider.credential(idToken: idToken);
      final result = await _auth.signInWithCredential(credential);
      final user = _toAppUser(result.user);
      if (user == null) throw const AuthFailure('Could not complete sign-in.');
      return user;
    } on GoogleSignInException catch (e) {
      // Dismissing the picker is normal behaviour, not an error. Returning
      // null — rather than throwing — means a caller cannot accidentally
      // render a banner for it.
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      Log.warn('Google sign-in failed: ${e.code}');
      throw const AuthFailure('Could not complete Google sign-in.');
    } on FirebaseAuthException catch (e) {
      Log.warn('Google credential rejected: ${e.code}');
      throw mapAuthErrorCode(e.code);
    }
  }

  @override
  Future<AppUser> signInWithEmail({
    required String email,
    required String password,
  }) => _emailCall(
    () => _auth.signInWithEmailAndPassword(email: email, password: password),
  );

  @override
  Future<AppUser> registerWithEmail({
    required String email,
    required String password,
  }) => _emailCall(
    () =>
        _auth.createUserWithEmailAndPassword(email: email, password: password),
  );

  @override
  Future<void> signOut() async {
    // Sign out of Google too, otherwise the next sign-in silently reuses the
    // previous account and "log out" appears not to have worked.
    //
    // Order matters: Firebase first, so that if the Google call fails the app
    // is still signed out of the thing that gates access.
    await _auth.signOut();
    try {
      await _google.signOut();
    } on GoogleSignInException catch (e) {
      Log.warn('Google sign-out failed after Firebase sign-out: ${e.code}');
    }
  }

  Future<AppUser> _emailCall(Future<UserCredential> Function() call) async {
    try {
      final result = await call();
      final user = _toAppUser(result.user);
      if (user == null) throw const AuthFailure('Could not complete sign-in.');
      return user;
    } on FirebaseAuthException catch (e) {
      // Only the code crosses this boundary. e.message can carry request
      // detail and must not reach a widget.
      Log.warn('Email auth failed: ${e.code}');
      throw mapAuthErrorCode(e.code);
    }
  }

  AppUser? _toAppUser(User? user) => user == null
      ? null
      : AppUser(
          id: user.uid,
          email: user.email,
          displayName: user.displayName,
        );
}
