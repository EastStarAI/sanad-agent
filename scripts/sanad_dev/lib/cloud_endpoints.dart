import 'dart:convert';
import 'dart:io';

import 'package:sanad_public_service_endpoints/public_service_endpoints.dart';

class SanadCloudEndpoints {
  const SanadCloudEndpoints({
    required this.gatewayUrl,
    required this.portalUrl,
  });

  final String gatewayUrl;
  final String portalUrl;

  Map<String, String> toAgentEnvironment() => {
    'GATEWAY_URL': gatewayUrl,
    'PORTAL_URL': portalUrl,
  };
}

SanadCloudEndpoints readSanadCloudEndpoints(File configFile) {
  final decoded = jsonDecode(configFile.readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Client configuration must be a JSON object.');
  }

  final environment = decoded['ENVIRONMENT'];
  if (environment is! String || environment.trim().isEmpty) {
    throw const FormatException('Client configuration requires ENVIRONMENT.');
  }

  String configuredUrl(String key, String fallback) {
    final value = decoded[key];
    if (value == null) {
      return fallback;
    }
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('Client configuration has an invalid $key.');
    }
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw FormatException('Client configuration has an invalid $key.');
    }
    return uri.toString();
  }

  return SanadCloudEndpoints(
    gatewayUrl: configuredUrl(
      'BACKEND_URL',
      PublicServiceEndpoints.backendFor(environment),
    ),
    portalUrl: configuredUrl(
      'PORTAL_URL',
      PublicServiceEndpoints.portalFor(environment),
    ),
  );
}
