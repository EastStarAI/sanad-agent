import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:sanad_client/infrastructure/js_interop/auth_popup.dart' as popup;

import 'auth_callback_contract.dart';

Future<AuthCallbackBinding> createPlatformAuthCallbackBinding() async => _WebPopupBinding();

class _WebPopupBinding implements AuthCallbackBinding {
  @override
  String get clientId => 'sanad_flutter_web';

  @override
  String get redirectUri => '${popup.appOrigin().toDart}/oauth/callback';

  @override
  Future<AuthCallbackResult> waitForResult(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final encoded = popup.takeAuthorizationMessage()?.toDart;
      if (encoded != null) {
        final decoded = jsonDecode(encoded);
        if (decoded is Map && decoded['code'] is String && decoded['state'] is String) {
          return AuthCallbackResult(
            code: decoded['code'] as String,
            state: decoded['state'] as String,
          );
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('Authentication callback timed out.');
  }

  @override
  Future<void> dispose() async {}
}
