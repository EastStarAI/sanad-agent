import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_identity.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_endpoint_record.dart';

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

  /// Forces the Home-selection decision for [discover].
  ///
  /// Production callers leave this null: a Home is selected when `SANAD_HOME`
  /// is set or when the resolved Home differs from the OS user's default Home.
  /// Tests use it to exercise both branches deterministically.
  final bool? homeSelected;

  const LocalGatewayDiscovery({
    this.sanadHomeOverride,
    this.environment,
    this.clientFactory,
    this.homeSelected,
  });

  static const String defaultHost = '127.0.0.1';
  static const int defaultPort = 58085;
  static const int maxScanPort = 58185;

  /// Health payload key carrying the answering daemon's Home identity.
  ///
  /// A probe that cannot read this value, or reads a different value, is not
  /// evidence for the Home this discovery resolves.
  static const String healthHomeIdKey = 'home_id';

  /// Bounded deadline for the authoritative probe of an explicitly targeted
  /// endpoint (an explicit URL or port override).
  ///
  /// A healthy daemon can answer a cold first health request slower than the
  /// speculative deadline while it is busy, and this probe is the only
  /// evidence that the requested endpoint is served, so it must not be
  /// mistaken for an absent daemon. The bound stays far below the CLI's
  /// WebSocket connect timeout, and an unreachable loopback endpoint still
  /// fails fast with a refused connection.
  static const Duration targetedProbeTimeout = Duration(seconds: 2);

  /// Bounded deadline for speculative probes (the default port and the
  /// worktree port scan) whose worst-case cost multiplies across the scanned
  /// range.
  static const Duration speculativeProbeTimeout = Duration(milliseconds: 300);

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

  /// Whether the caller selected a Home instead of relying on the OS user's
  /// default Home.
  ///
  /// `--home` reaches this class as [sanadHomeOverride] resolved by
  /// `SanadCommandRunner.selectedHome`; `SANAD_HOME` is the second selection
  /// source. A Home that merely equals the default Home is not a selection and
  /// keeps the historical default-port discovery.
  bool get homeIsSelected {
    final forced = homeSelected;
    if (forced != null) return forced;

    final env = environment ?? Platform.environment;
    final envHome = env['SANAD_HOME']?.trim() ?? '';
    if (envHome.isNotEmpty) return true;

    final override = sanadHomeOverride?.trim() ?? '';
    if (override.isEmpty) return false;

    final userHome = env['HOME']?.trim().isNotEmpty == true
        ? env['HOME']!.trim()
        : env['USERPROFILE']?.trim().isNotEmpty == true
        ? env['USERPROFILE']!.trim()
        : null;
    if (userHome == null) return true;
    return !p.equals(
      canonicalSanadHomePath(override),
      canonicalSanadHomePath(p.join(userHome, '.sanad')),
    );
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
      final bindingFile = File(
        p.join(home, LocalGatewayCredentials.bindingRelativePath),
      );
      if (bindingFile.existsSync()) {
        final binding = (await bindingFile.readAsString()).trim();
        if (binding.isNotEmpty && binding != sanadHomeIdentity(home)) {
          throw GatewayDiscoveryException(
            'The local gateway token in $home is bound to a different Sanad '
            'Home. Start the Agent for this Home to issue its own token.',
            code: 'token_bound_to_other_home',
          );
        }
      }

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
    Duration timeout = speculativeProbeTimeout,
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
  ///
  /// Resolution order:
  /// 1. explicit endpoint URL (`--gateway-url`, `SANAD_GATEWAY_URL`,
  ///    `LOCAL_GATEWAY_URL`),
  /// 2. explicit `--port`,
  /// 3. when a Home is selected, that Home's own runtime record — and only
  ///    that record; a Home without a live record fails closed instead of
  ///    probing the default port or scanning,
  /// 4. `LOCAL_GATEWAY_PORT` (default Home only),
  /// 5. the default port and then the worktree port range (default Home only),
  ///    where every candidate must prove the resolved Home identity.
  ///
  /// [probeTimeout] overrides the deadline of every probe. When omitted,
  /// probes of an explicitly targeted endpoint (an explicit URL or port
  /// override) use [targetedProbeTimeout], while speculative probes (default
  /// port and worktree port scan) use [speculativeProbeTimeout].
  Future<GatewayDiscoveryResult> discover({
    String? urlOverride,
    int? portOverride,
    String? tokenOverride,
    Duration? probeTimeout,
  }) async {
    final String token;
    if (tokenOverride != null && tokenOverride.trim().isNotEmpty) {
      token = tokenOverride.trim();
    } else {
      token = await readToken();
    }

    final env = environment ?? Platform.environment;

    // An explicit target is the only evidence that a specific endpoint is
    // served, so it gets the wider targeted bound; speculative probes stay on
    // the cheaper bound because their cost multiplies across the scan range.
    final targetedProbe = probeTimeout ?? targetedProbeTimeout;
    final speculativeProbe = probeTimeout ?? speculativeProbeTimeout;

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
        timeout: targetedProbe,
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

    // 2. Explicit `--port` override
    if (portOverride != null) {
      final health = await probeHealth(
        host: defaultHost,
        port: portOverride,
        token: token,
        timeout: targetedProbe,
      );

      return GatewayDiscoveryResult(
        gatewayWsUri: Uri.parse('ws://$defaultHost:$portOverride/gateway'),
        gatewayHttpUri: Uri.parse('http://$defaultHost:$portOverride'),
        token: token,
        isDaemonRunning: health != null,
        port: portOverride,
        host: defaultHost,
        healthData: health,
      );
    }

    // 3. A selected Home owns its endpoint: resolve the runtime record that
    //    this Home's daemon published before any default-port probe. A Home
    //    without a live record fails closed, because probing 58085 or scanning
    //    the range can attach the call to another Home's runtime.
    final selectedHome = homeIsSelected ? resolveSanadHome() : null;
    if (selectedHome != null) {
      final expectedHomeId = sanadHomeIdentity(selectedHome);
      final record = LocalGatewayEndpointRecord.tryRead(homePath: selectedHome);

      if (record == null) {
        throw GatewayDiscoveryException(
          'No live runtime record for Sanad Home $selectedHome. Start the '
          'Agent for this Home (`sanad daemon`), or pass --gateway-url to '
          'target an endpoint explicitly.',
          code: 'home_runtime_missing',
        );
      }
      if (record.homeId != expectedHomeId) {
        throw GatewayDiscoveryException(
          'The runtime record in $selectedHome belongs to a different Sanad '
          'Home. Start the Agent for this Home to publish its own endpoint.',
          code: 'home_runtime_foreign',
        );
      }

      final health = await probeHealth(
        host: record.host,
        port: record.port,
        token: token,
        timeout: targetedProbe,
      );
      if (health == null) {
        throw GatewayDiscoveryException(
          'The runtime record for Sanad Home $selectedHome points at '
          '${record.host}:${record.port}, but no healthy daemon answered. '
          'Start or restart the Agent for this Home.',
          code: 'home_runtime_unhealthy',
        );
      }
      if (!_servesHome(health, expectedHomeId)) {
        throw GatewayDiscoveryException(
          'The daemon answering on ${record.host}:${record.port} does not '
          'serve Sanad Home $selectedHome. Start or restart the Agent for '
          'this Home.',
          code: 'home_identity_mismatch',
        );
      }

      return GatewayDiscoveryResult(
        gatewayWsUri: Uri.parse('ws://${record.host}:${record.port}/gateway'),
        gatewayHttpUri: Uri.parse('http://${record.host}:${record.port}'),
        token: token,
        isDaemonRunning: true,
        port: record.port,
        host: record.host,
        healthData: health,
      );
    }

    // 4. Inherited LOCAL_GATEWAY_PORT, honoured only when no Home is selected.
    //    A parent process's port must never redirect a Home-selected call away
    //    from that Home's own runtime record.
    final envPortStr = env['LOCAL_GATEWAY_PORT'];
    final envPort = envPortStr != null ? int.tryParse(envPortStr) : null;
    if (envPort != null) {
      final health = await probeHealth(
        host: defaultHost,
        port: envPort,
        token: token,
        timeout: targetedProbe,
      );

      return GatewayDiscoveryResult(
        gatewayWsUri: Uri.parse('ws://$defaultHost:$envPort/gateway'),
        gatewayHttpUri: Uri.parse('http://$defaultHost:$envPort'),
        token: token,
        isDaemonRunning: health != null,
        port: envPort,
        host: defaultHost,
        healthData: health,
      );
    }

    // 5. Probe default port 58085 first. The answering daemon must prove the
    //    active Home; a daemon that serves another Home is not this caller's
    //    runtime even when it accepts the presented token.
    final resolvedHomeId = sanadHomeIdentity(resolveSanadHome());
    final defaultHealth = await probeHealth(
      host: defaultHost,
      port: defaultPort,
      token: token,
      timeout: speculativeProbe,
    );

    if (_servesHome(defaultHealth, resolvedHomeId)) {
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

    // 6. Scan worktree port range 58086 to 58185 in small batches
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
              timeout: speculativeProbe,
              client: client,
            );
            return (port: currentPort, data: h);
          }());
        }

        final results = await Future.wait(futures);
        for (final res in results) {
          if (_servesHome(res.data, resolvedHomeId)) {
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

    // 7. Default fallback result when daemon is not currently active
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

  /// Whether [health] is a healthy answer from the daemon that serves
  /// [expectedHomeId].
  ///
  /// Token acceptance alone is not evidence: two Homes that ever shared a
  /// credential would otherwise be interchangeable.
  static bool _servesHome(Map<String, dynamic>? health, String expectedHomeId) {
    if (health == null || health['status'] != 'ok') return false;
    return health[healthHomeIdKey] == expectedHomeId;
  }
}
