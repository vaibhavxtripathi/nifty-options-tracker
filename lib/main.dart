import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'app/app.dart';
import 'core/config/app_config.dart';
import 'firebase_options.dart';

/// Bootstrap only: initialise the identity provider, then hand off.
///
/// Both initialisations live here rather than in a repository because each
/// must happen exactly once per process. `GoogleSignIn.initialize()` in
/// particular has to be awaited before any other call on the singleton, and a
/// repository — which can be constructed more than once — is the wrong owner
/// for a once-per-process guarantee.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  final config = AppConfig.fromEnvironment();
  await GoogleSignIn.instance.initialize(
    // On Android the plugin reads the client ID from google-services.json, so
    // this is only passed when explicitly supplied. It must be the **Web**
    // client ID: the Android one yields a null idToken at sign-in.
    serverClientId: config.hasGoogleServerClientId
        ? config.googleServerClientId
        : null,
  );

  runApp(const ProviderScope(child: NiftyOptionsApp()));
}
