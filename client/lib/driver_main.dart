// ignore: depend_on_referenced_packages
import 'package:flutter_driver/driver_extension.dart';
import 'package:sanad_client/main.dart' as app;

import 'dart:developer' as developer;
import 'dart:convert';

import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/driver/inspect_ui_extension.dart';
import 'package:sanad_client/driver/interaction_extensions.dart';
import 'package:sanad_client/features/auth/infrastructure/auth_service.dart';

/// Registers the authentication challenge retrieval service extension (`ext.sanad_client.auth_url`).
void registerAuthUrlExtension() {
  developer.registerExtension('ext.sanad_client.auth_url', (
    method,
    parameters,
  ) async {
    if (!getIt.isRegistered<AuthService>()) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        json.encode({'error': 'Authentication service is not ready'}),
      );
    }

    final challenge = getIt<AuthService>().loginChallenge;
    if (challenge == null) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        json.encode({'error': 'No active authentication challenge'}),
      );
    }

    final authUri = Uri.tryParse(challenge.authUrl);
    if (authUri == null || (authUri.scheme != 'http' && authUri.scheme != 'https') || authUri.host.isEmpty) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        json.encode({
          'error': 'Active authentication challenge URL is invalid',
        }),
      );
    }

    return developer.ServiceExtensionResponse.result(
      json.encode({'status': 'ok', 'auth_url': challenge.authUrl}),
    );
  });
}

void main() {
  // Enable integration testing with the Flutter Driver extension.
  enableFlutterDriverExtension(enableTextEntryEmulation: false);

  // Register development service extensions in documented order:
  // 1. ext.sanad_client.auth_url
  // 2. ext.sanad_client.inspect_ui
  // 3. ext.sanad_client.enter_text
  // 4. ext.sanad_client.scroll
  // 5. ext.sanad_client.tap
  // 6. ext.sanad_client.reveal
  registerAuthUrlExtension();
  registerInspectUiExtension();
  registerEnterTextExtension();
  registerScrollExtension();
  registerTapExtension();
  registerRevealExtension();

  app.main();
}
