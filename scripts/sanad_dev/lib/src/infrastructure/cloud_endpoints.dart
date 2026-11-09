import 'dart:convert';
import 'dart:io';

import 'package:sanad_public_service_endpoints/public_service_endpoints.dart';

class SanadCloudEndpoints {
  const SanadCloudEndpoints({
    required this.environment,
    required this.gatewayUrl,
    required this.portalUrl,
  });

  final String environment;
  final String gatewayUrl;
  final String portalUrl;

  Map<String, String> toAgentEnvironment() => {
    'GATEWAY_URL': gatewayUrl,
    'PORTAL_URL': portalUrl,
  };
}

SanadCloudEndpoints readSanadCloudEndpoints(File configFile) {
  final decoded = _decodeClientConfiguration(configFile);

  final environment = readSanadClientEnvironment(configFile, decoded: decoded);

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
    environment: environment,
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

/// Client `ENVIRONMENT` of a launch configuration.
///
/// It decides the deterministic Web Client origin, so it is required even when
/// the cloud gateway is disabled and no endpoint is resolved.
String readSanadClientEnvironment(
  File configFile, {
  Map<String, dynamic>? decoded,
}) {
  final config = decoded ?? _decodeClientConfiguration(configFile);
  final environment = config['ENVIRONMENT'];
  if (environment is! String || environment.trim().isEmpty) {
    throw const FormatException('Client configuration requires ENVIRONMENT.');
  }
  return environment.trim();
}

/// Client `ENVIRONMENT` reached through a live launch argument vector.
///
/// The launcher's additional-Client path replays a recorded command line instead
/// of the parsed CLI options, so the configuration file is recovered from the
/// `--dart-define-from-file` argument. Returns `null` when it cannot be resolved,
/// which callers treat as a failure rather than guessing an origin.
String? readSanadClientEnvironmentFromLaunchArguments({
  required List<String> arguments,
  required String clientDirectory,
}) {
  final configFile = clientConfigFileFromLaunchArguments(
    arguments: arguments,
    clientDirectory: clientDirectory,
  );
  if (configFile == null) return null;
  try {
    return readSanadClientEnvironment(configFile);
  } on FormatException {
    return null;
  }
}

/// Cloud endpoints reached through a live launch argument vector.
///
/// The additional-Client path needs the Portal URL as well as the environment to
/// keep a Web Client on the origin that Portal accepts. `null` means the recorded
/// command line names no readable configuration, never a guessed endpoint.
SanadCloudEndpoints? readSanadCloudEndpointsFromLaunchArguments({
  required List<String> arguments,
  required String clientDirectory,
}) {
  final configFile = clientConfigFileFromLaunchArguments(
    arguments: arguments,
    clientDirectory: clientDirectory,
  );
  if (configFile == null) return null;
  try {
    return readSanadCloudEndpoints(configFile);
  } on FormatException {
    return null;
  }
}

/// Client configuration file named by `--dart-define-from-file=`.
File? clientConfigFileFromLaunchArguments({
  required List<String> arguments,
  required String clientDirectory,
}) {
  const flag = '--dart-define-from-file=';
  final argument = arguments.firstWhere(
    (value) => value.startsWith(flag),
    orElse: () => '',
  );
  if (argument.isEmpty) return null;
  final value = argument.substring(flag.length).trim();
  if (value.isEmpty) return null;
  final direct = File(value);
  final candidate = direct.isAbsolute
      ? direct
      : File('$clientDirectory${Platform.pathSeparator}$value');
  return candidate.existsSync()
      ? candidate
      : direct.existsSync()
      ? direct
      : null;
}

Map<String, dynamic> _decodeClientConfiguration(File configFile) {
  final decoded = jsonDecode(configFile.readAsStringSync());
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Client configuration must be a JSON object.');
  }
  return decoded;
}
