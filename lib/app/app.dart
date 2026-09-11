import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'theme.dart';

class NiftyOptionsApp extends ConsumerWidget {
  const NiftyOptionsApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Nifty Options Tracker',
      debugShowCheckedModeBanner: false,
      scrollBehavior: AppTheme.scrollBehavior,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      routerConfig: ref.watch(routerProvider),
    );
  }
}
