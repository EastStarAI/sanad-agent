import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:sanad_agent/core/auth/device_authorization_client.dart';

/// Aligns one device identity with the authenticated Portal clock.
///
/// Only an HTTPS Portal response can supply the offset, and a missing response
/// never replaces the normal signed registration failure path or authorizes an
/// untrusted time source.
Future<void> calibrateIdentityTime({
  required Logger logger,
  required http.Client httpClient,
  required DeviceKeyIdentity identity,
  required String portalUrl,
}) async {
  final portalUri = Uri.parse(portalUrl);
  if (portalUri.scheme != 'https') return;
  try {
    final response = await httpClient
        .head(portalUri)
        .timeout(const Duration(seconds: 5));
    if (response.statusCode < 200 || response.statusCode >= 500) return;
    final offset = DeviceAuthorizationClient.trustedServerTimeOffset(
      portalUri,
      response.headers['date'],
    );
    await identity.rememberServerTimeOffset(offset);
    if (offset.inSeconds.abs() > 300) {
      logger.warning(
        'Local clock differs from the Portal; Gateway proofs will use the '
        'authenticated Portal time.',
      );
    }
  } on Object {
    // A failed calibration keeps the device identity on its verified offset.
  }
}
