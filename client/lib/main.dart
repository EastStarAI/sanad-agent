import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:sanad_client/core/bootstrap/app_bootstrap.dart';
import 'app.dart';

void main() async {
  if (kIsWeb) {
    usePathUrlStrategy();
  }
  final bootstrap = await AppBootstrap.initialize();
  runApp(SanadAgentApp(
    initialTheme: bootstrap.initialTheme,
    initialLocale: bootstrap.initialLocale,
    initialAppearance: bootstrap.initialAppearance,
  ));
}
