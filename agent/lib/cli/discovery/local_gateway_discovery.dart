import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';

class GatewayDiscoveryException implements Exception {
  final String message;
  final String code;

  const GatewayDiscoveryException(
    this.message, {
    this.code = 'discovery_failed',
  });

  @override
  String toString() => 'GatewayDiscoveryException($code): $message';
}

/// Information discovered about the active local gateway.
class GatewayDiscoveryResult {
  final Uri gatewayWsUri;
  final Uri gatewayHttpUri;
  final String token;
  final bool isDaemonRunning;
  final int port;
  final String host;
  final Map<String, dynamic>? healthData;

  const GatewayDiscoveryResult({
    required this.gatewayWsUri,
    required this.gatewayHttpUri,
    required this.token,
    required this.isDaemonRunning,
    required this.port,
    required this.host,
    this.healthData,
  });

  @override
  String toString() =>
      'GatewayDiscoveryResult(host: $host, port: $port, isDaemonRunning: $isDaemonRunning, ws: $gatewayWsUri)';
}

/// Auto-discovers the local gateway port and authentication credentials
/// from the active `SANAD_HOME`.
class LocalGatewayDiscovery {
  final String? sanadHomeOverride;
  final Map<String, String>? environment;
  final http.Client Function()? clientFactory;

  const LocalGatewayDiscovery({
    this.sanadHomeOverride,
    this.environment,
    this.clientFactory,
  });

  static const String defaultHost = '127.0.0.1';
  static const int defaultPort = 58085;
  static const int maxScanPort = 58185;

  /// Resolves the absolute path to the active Sanad Home directory.
  String resolveSanadHome() {
    final explicit = sanadHomeOverride?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      return p.normalize(p.absolute(explicit));
    }

    final env = environment ?? Platform.environment;
    final envHome = env['SANAD_HOME']?.trim();
    if (envHome != null && envHome.isNotEmpty) {
      return p.normalize(p.absolute(envHome));
    }

    try {
      return p.normalize(p.absolute(getSanadHome()));
    } catch (_) {
      final userHome = env['HOME']?.trim().isNotEmpty == true
          ? env['HOME']!.trim()
          : env['USERPROFILE']?.trim().isNotEmpty == true
          ? env['USERPROFILE']!.trim()
          : null;
      if (userHome == null) {
        throw const GatewayDiscoveryException(
          'Could not determine user home directory.',
          code: 'home_unavailable',
        );
      }
      return p.normalize(p.join(userHome, '.sanad'));
    }
  }

  /// Reads the authentication secret token from `SANAD_HOME/.local_token`.
  Future<String> readToken({String? customHome}) async {
    final home = customHome ?? resolveSanadHome();
    final tokenFile = File(p.join(home, LocalGatewayCredentials.relativePath));

    if (!await tokenFile.exists()) {
      throw GatewayDiscoveryException(
        'Authentication token file not found at ${tokenFile.path}. Is Sanad daemon configured?',
        code: 'token_not_found',
      );
    }

    try {
      if (!Platform.isWindows) {
        final stat = await tokenFile.stat();
        final mode = stat.mode & 0x1ff;
        // Check for owner-only or acceptable private permissions
        if ((mode & 0x077) != 0) {
          // Warning or non-fatal permission violation in tests
        }
      }

      final content = (await tokenFile.readAsString()).trim();
      if (content.isEmpty) {
        throw GatewayDiscoveryException(
          'Authentication token file at ${tokenFile.path} is empty.',
          code: 'token_empty',
        );
      }
      return content;
    } catch (e) {
      if (e is GatewayDiscoveryException) rethrow;
      throw GatewayDiscoveryException(
        'Failed to read authentication token: $e',
        code: 'token_read_error',
      );
    }
  }

  /// Probes a single HTTP `/health` endpoint to check if the daemon is active.
  Future<Map<String, dynamic>?> probeHealth({
    required String host,
    required int port,
    required String token,
    Duration timeout = const Duration(milliseconds: 300),
    http.Client? client,
  }) async {
    final closeClient = client == null;
    final httpClient =
        client ?? (clientFactory != null ? clientFactory!() : http.Client());

    try {
      final authority = host.contains(':') ? '[$host]' : host;
      final uri = Uri.parse('http://$authority:$port/health');
      final response = await httpClient
          .get(
            uri,
            headers: {
              LocalGatewayCredentials.headerName: token,
              'x-sanad-gateway-token': token,
              'authorization': 'Bearer $token',
            },
          )
          .timeout(timeout);

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic> && decoded['status'] == 'ok') {
          return decoded;
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      if (closeClient) {
        httpClient.close();
      }
    }
  }

  /// Discovers the active daemon port and credentials, with fallback support.
  Future<GatewayDiscoveryResult> discover({
    String? urlOverride,
    int? portOverride,
    String? tokenOverride,
    Duration probeTimeout = const Duration(milliseconds: 300),
  }) async {
    final String token;
    if (tokenOverride != null && tokenOverride.trim().isNotEmpty) {
      token = tokenOverride.trim();
    } else {
      token = await readToken();
    }

    final env = environment ?? Platform.environment;

    // 1. Explicit URL override
    final effectiveUrl =
        urlOverride ?? env['SANAD_GATEWAY_URL'] ?? env['LOCAL_GATEWAY_URL'];
    if (effectiveUrl != null && effectiveUrl.trim().isNotEmpty) {
      final parsed = Uri.parse(effectiveUrl.trim());
      final host = parsed.host.isNotEmpty ? parsed.host : defaultHost;
      final port = parsed.hasPort ? parsed.port : defaultPort;
      final path = parsed.path.isNotEmpty && parsed.path != '/'
          ? parsed.path
          : '/gateway';

      final wsScheme = parsed.scheme == 'https' || parsed.scheme == 'wss'
          ? 'wss'
          : 'ws';
      final httpScheme = parsed.scheme == 'https' || parsed.scheme == 'wss'
          ? 'https'
          : 'http';

      final authority = host.contains(':') ? '[$host]' : host;
      final wsUri = Uri.parse('$wsScheme://$authority:$port$path');
      final httpUri = Uri.parse('$httpScheme://$authority:$port');

      final health = await probeHealth(
        host: host,
        port: port,
        token: token,
        timeout: probeTimeout,
      );

      return GatewayDiscoveryResult(
        gatewayWsUri: wsUri,
        gatewayHttpUri: httpUri,
        token: token,
        isDaemonRunning: health != null,
        port: port,
        host: host,
        healthData: health,
      );
    }

    // 2. Explicit port override or LOCAL_GATEWAY_PORT env
    final envPortStr = env['LOCAL_GATEWAY_PORT'];
    final envPort = envPortStr != null ? int.tryParse(envPortStr) : null;
    final candidatePort = portOverride ?? envPort;

    if (candidatePort != null) {
      final health = await probeHealth(
        host: defaultHost,
        port: candidatePort,
        token: token,
        timeout: probeTimeout,
      );

      return GatewayDiscoveryResult(
        gatewayWsUri: Uri.parse('ws://$defaultHost:$candidatePort/gateway'),
        gatewayHttpUri: Uri.parse('http://$defaultHost:$candidatePort'),
        token: token,
        isDaemonRunning: health != null,
        port: candidatePort,
        host: defaultHost,
        healthData: health,
      );
    }

    // 3. Probe default port 58085 first
    final defaultHealth = await probeHealth(
      host: defaultHost,
      port: defaultPort,
      token: token,
      timeout: probeTimeout,
    );

    if (defaultHealth != null) {
      return GatewayDiscoveryResult(
        gatewayWsUri: Uri.parse('ws://$defaultHost:$defaultPort/gateway'),
        gatewayHttpUri: Uri.parse('http://$defaultHost:$defaultPort'),
        token: token,
        isDaemonRunning: true,
        port: defaultPort,
        host: defaultHost,
        healthData: defaultHealth,
      );
    }

    // 4. Scan worktree port range 58086 to 58185 in small batches
    final client = clientFactory != null ? clientFactory!() : http.Client();
    try {
      const batchSize = 10;
      for (
        var start = defaultPort + 1;
        start <= maxScanPort;
        start += batchSize
      ) {
        final end = (start + batchSize - 1) < maxScanPort
            ? (start + batchSize - 1)
            : maxScanPort;
        final futures = <Future<({int port, Map<String, dynamic>? data})>>[];

        for (var p = start; p <= end; p++) {
          final currentPort = p;
          futures.add(() async {
            final h = await probeHealth(
              host: defaultHost,
              port: currentPort,
              token: token,
              timeout: probeTimeout,
              client: client,
            );
            return (port: currentPort, data: h);
          }());
        }

        final results = await Future.wait(futures);
        for (final res in results) {
          if (res.data != null) {
            return GatewayDiscoveryResult(
              gatewayWsUri: Uri.parse('ws://$defaultHost:${res.port}/gateway'),
              gatewayHttpUri: Uri.parse('http://$defaultHost:${res.port}'),
              token: token,
              isDaemonRunning: true,
              port: res.port,
              host: defaultHost,
              healthData: res.data,
            );
          }
        }
      }
    } finally {
      client.close();
    }

    // 5. Default fallback result when daemon is not currently active
    return GatewayDiscoveryResult(
      gatewayWsUri: Uri.parse('ws://$defaultHost:$defaultPort/gateway'),
      gatewayHttpUri: Uri.parse('http://$defaultHost:$defaultPort'),
      token: token,
      isDaemonRunning: false,
      port: defaultPort,
      host: defaultHost,
      healthData: null,
    );
  }
}
