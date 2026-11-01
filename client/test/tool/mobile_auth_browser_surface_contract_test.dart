import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Portal authorization page must always open in the platform's external
/// browser. An in-app browser view / custom tab starts from its own website
/// data, so an already signed-in user would have to recreate provider sign-in.
void main() {
  test('Portal authorization opens only the external system browser', () {
    final authService = File(
      'lib/features/auth/infrastructure/auth_service.dart',
    ).readAsStringSync();

    expect(
      authService,
      isNot(contains('LaunchMode.inAppBrowserView')),
      reason:
          'Authorization must not run inside an in-app browser view or custom '
          'tab: it does not carry the user\'s saved provider sessions.',
    );

    final launcher = authService.substring(
      authService.indexOf('Future<bool> _launchPortalAuthorization'),
    );
    final body = launcher.substring(0, launcher.indexOf('\n}\n') + 3);

    expect(
      body,
      contains('if (kIsWeb)'),
      reason:
          'Web authorization keeps the popup owner and must not fall through '
          'to the native launcher.',
    );
    expect(
      body,
      contains('LaunchMode.externalApplication'),
      reason: 'Desktop and mobile authorization use the external browser.',
    );
  });
}
