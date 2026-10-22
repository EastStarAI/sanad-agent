import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
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

/// What one `/health` probe learned about an endpoint.
///
/// The difference between "did not answer" and "answered and refused this
/// Home's credential" is security-relevant: an endpoint that never answered is
/// not running (so `--standalone` may proceed), while an endpoint that refused
/// the credential is running and has just proven it is *not* this Home's
/// daemon. Collapsing both into `null` is what let an explicit target fail
/// later with an opaque WebSocket `401` instead of a Home-aware refusal.
class HealthProbe {
  const HealthProbe({this.body, this.statusCode});

  /// The endpoint did not answer at all: refused connection, timeout, or an
  /// unparseable transport answer. Historical "no daemon here".
  static const HealthProbe noAnswer = HealthProbe();

  /// The decoded payload of a healthy answer, or null when the endpoint
  /// answered something else.
  final Map<String, dynamic>? body;

  /// The HTTP status the endpoint answered with, or null when it never
  /// answered.
  final int? statusCode;

  /// Whether the endpoint answered over HTTP at all.
  bool get answered => statusCode != null;

  /// Whether the endpoint returned the healthy daemon payload.
  bool get isHealthy => body != null;

  /// Whether the endpoint refused the presented credential.
  ///
  /// A local Sanad daemon authenticates before it routes `/health`, so this is
  /// the answer a *foreign* runtime gives to this Home's token.
  bool get rejectedAuthentication =>
      statusCode == HttpStatus.unauthorized ||
      statusCode == HttpStatus.forbidden;

  @override
  String toString() =>
      'HealthProbe(statusCode: $statusCode, healthy: $isHealthy)';
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
  ///
  /// A leading `~` is expanded first, so a literal `~/...` `SANAD_HOME` or
  /// `--home` names the same Home that the daemon reports over `/health`.
  String resolveSanadHome() {
    final explicit = sanadHomeOverride?.trim();
    if (explicit != null && explicit.isNotEmpty) {
      return _absoluteHome(explicit);
    }

    final env = environment ?? Platform.environment;
    final envHome = env['SANAD_HOME']?.trim();
    if (envHome != null && envHome.isNotEmpty) {
      return _absoluteHome(envHome);
    }

    try {
      return _absoluteHome(getSanadHome());
    } catch (_) {
      final defaultHome = _defaultHomePath();
      if (defaultHome == null) {
        throw const GatewayDiscoveryException(
          'Could not determine user home directory.',
          code: 'home_unavailable',
        );
      }
      return _absoluteHome(defaultHome);
    }
  }

  String _absoluteHome(String value) => p.normalize(
    p.absolute(expandLeadingTilde(value, environment: environment) ?? value),
  );

  /// The OS user's default Sanad Home, using the same resolution order as
  /// `defaultSanadHome()` — `%USERPROFILE%\.sanad` on Windows and
  /// `$HOME/.sanad` elsewhere — but reading the injected [environment] when a
  /// caller supplied one.
  ///
  /// Selection detection must compare against this and nothing else: any other
  /// order would classify a normal default-Home run as a selection on a
  /// platform where the two variables disagree (for example `HOME` set by
  /// Git Bash on Windows while the daemon uses `USERPROFILE`).
  String? _defaultHomePath() {
    final env = environment;
    if (env == null) return defaultSanadHome();
    final String? userHome;
    if (Platform.isWindows) {
      userHome = env['USERPROFILE'];
    } else {
      userHome = env['HOME'];
    }
    if (userHome == null || userHome.isEmpty) return null;
    return p.join(userHome, '.sanad');
  }

  /// Whether the caller selected a Home instead of relying on the OS user's
  /// default Home.
  ///
  /// `--home` reaches this class as [sanadHomeOverride] resolved by
  /// `SanadCommandRunner.selectedHome`; `SANAD_HOME` is the second selection
  /// source. Resolution order decides: an explicit `--home` that names the
  /// default Home is not a selection even when `SANAD_HOME` is also set,
  /// because the flag is what resolved the Home, and that Home keeps the
  /// historical default-port discovery.
  bool get homeIsSelected {
    final forced = homeSelected;
    if (forced != null) return forced;

    final override = sanadHomeOverride?.trim() ?? '';
    if (override.isNotEmpty) {
      final defaultHome = _defaultHomePath();
      if (defaultHome == null) return true;
      return !p.equals(
        canonicalSanadHomePath(override),
        canonicalSanadHomePath(defaultHome),
      );
    }

    final env = environment ?? Platform.environment;
    return env['SANAD_HOME']?.trim().isNotEmpty ?? false;
  }

  /// Reads the authentication secret token from `SANAD_HOME/.local_token`.
  ///
  /// Read-only by design: the token is issued and rotated by the daemon that
  /// owns the Home, never by a CLI or login call. Only the rejection reasons
  /// differ — a missing file, a file bound to another Home, an unsafe file mode
  /// and an unreadable file keep distinct codes so a caller can tell "start the
  /// Agent" from "fix the permissions".
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

      // A token any other user can read is not a credential. The desktop
      // Client and sanad-dev already refuse anything but 0600, so matching them
      // here keeps one rule instead of a lenient CLI that would still present a
      // credential no local server should trust.
      if (!SanadHomeBootstrap.isOwnerOnlyFile(tokenFile)) {
        throw GatewayDiscoveryException(
          'The local gateway token at ${tokenFile.path} is not owner-only '
          '(0600). Run: chmod 600 ${tokenFile.path}',
          code: 'token_permissions',
        );
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
  ///
  /// Returns what the endpoint *answered*, not only whether it is healthy, so a
  /// caller can tell an absent daemon from one that refused this credential.
  Future<HealthProbe> probeHealth({
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

      if (response.statusCode != HttpStatus.ok) {
        return HealthProbe(statusCode: response.statusCode);
      }
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic> && decoded['status'] == 'ok') {
        return HealthProbe(body: decoded, statusCode: response.statusCode);
      }
      return HealthProbe(statusCode: response.statusCode);
    } catch (_) {
      return HealthProbe.noAnswer;
    } finally {
      if (closeClient) {
        httpClient.close();
      }
    }
  }

  /// Discovers the active daemon port and credentials, with fallback support.
  ///
  /// Resolution order:
  /// 1. an explicit endpoint URL: `--gateway-url`, or — only when no Home is
  ///    selected — an inherited `SANAD_GATEWAY_URL` / `LOCAL_GATEWAY_URL`,
  /// 2. an explicit `--port`,
  /// 3. when a Home is selected, that Home's own runtime record — and only
  ///    that record; a Home without a live record fails closed instead of
  ///    probing the default port or scanning,
  /// 4. `LOCAL_GATEWAY_PORT` (default Home only),
  /// 5. the default port and then the worktree port range (default Home only),
  ///    where every candidate must prove the resolved Home identity.
  ///
  /// Every step that produces a healthy answer must prove the resolved Home
  /// identity, including an explicit URL or port. A selected Home also discards
  /// every inherited URL and port, so a parent process cannot point this Home's
  /// credential at another runtime. Because a daemon released before this
  /// contract reports no `home_id`, a *missing* identity is tolerated only on
  /// the default Home's default port `58085`; a reported identity that differs
  /// is rejected everywhere.
  ///
  /// With a selected Home, an explicit target that answers with an
  /// authentication rejection (`401`/`403`) is also a mismatch and fails closed
  /// before any WebSocket connect: the credential is that Home's, so a runtime
  /// that refuses it cannot be that Home's daemon. An explicit target that does
  /// not answer at all stays "not running", which keeps `--standalone` working.
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
    final env = environment ?? Platform.environment;

    // One Home resolution for the whole call: the token, the identity and the
    // endpoint all belong to the same Home, so nothing inherited from a parent
    // process can redirect this Home's token somewhere else.
    final resolvedHome = resolveSanadHome();
    final selectedHome = homeIsSelected ? resolvedHome : null;
    final expectedHomeId = sanadHomeIdentity(resolvedHome);

    final String token;
    if (tokenOverride != null && tokenOverride.trim().isNotEmpty) {
      token = tokenOverride.trim();
    } else {
      token = await readToken(customHome: resolvedHome);
    }

    // A daemon released before this change does not report `home_id` on
    // `/health`. Tolerating that absence is bounded to the default Home on the
    // default port, because that is the only pair an older desktop bundle
    // owns; a named Home must prove itself, and a *mismatching* identity is
    // never accepted anywhere.
    bool allowsLegacyDefaultDaemon(int port) =>
        selectedHome == null && port == defaultPort;

    // An explicit target is the only evidence that a specific endpoint is
    // served, so it gets the wider targeted bound; speculative probes stay on
    // the cheaper bound because their cost multiplies across the scan range.
    final targetedProbe = probeTimeout ?? targetedProbeTimeout;
    final speculativeProbe = probeTimeout ?? speculativeProbeTimeout;

    // 1. Explicit endpoint URL. Only `--gateway-url` is an explicit target: the
    //    inherited `SANAD_GATEWAY_URL` / `LOCAL_GATEWAY_URL` are parent-process
    //    hints, and a selected Home throws them away together with the
    //    inherited port so that a Home X token is never sent to a URL that was
    //    not chosen for that Home.
    final inheritedUrl = env['SANAD_GATEWAY_URL'] ?? env['LOCAL_GATEWAY_URL'];
    final effectiveUrl =
        urlOverride ?? (selectedHome == null ? inheritedUrl : null);
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

      _requireServesHome(
        health,
        expectedHomeId,
        allowLegacyDefaultHome: allowsLegacyDefaultDaemon(port),
        target: '$host:$port',
        // A selected Home's credential must never reach a runtime that has not
        // proven it serves that Home: an explicit target that answers with an
        // authentication rejection is a mismatch, not an absent daemon.
        refuseCredentialRejection: selectedHome != null,
      );

      return GatewayDiscoveryResult(
        gatewayWsUri: wsUri,
        gatewayHttpUri: httpUri,
        token: token,
        isDaemonRunning: health.isHealthy,
        port: port,
        host: host,
        healthData: health.body,
      );
    }

    // 2. Explicit `--port` override. Same requirement as an explicit URL: the
    //    target must prove it serves this Home.
    if (portOverride != null) {
      final health = await probeHealth(
        host: defaultHost,
        port: portOverride,
        token: token,
        timeout: targetedProbe,
      );

      _requireServesHome(
        health,
        expectedHomeId,
        allowLegacyDefaultHome: allowsLegacyDefaultDaemon(portOverride),
        target: '$defaultHost:$portOverride',
        refuseCredentialRejection: selectedHome != null,
      );

      return GatewayDiscoveryResult(
        gatewayWsUri: Uri.parse('ws://$defaultHost:$portOverride/gateway'),
        gatewayHttpUri: Uri.parse('http://$defaultHost:$portOverride'),
        token: token,
        isDaemonRunning: health.isHealthy,
        port: portOverride,
        host: defaultHost,
        healthData: health.body,
      );
    }

    // 3. A selected Home owns its endpoint: resolve the runtime record that
    //    this Home's daemon published before any default-port probe. A Home
    //    without a live record fails closed, because probing 58085 or scanning
    //    the range can attach the call to another Home's runtime.
    if (selectedHome != null) {
      final record = LocalGatewayEndpointRecord.tryRead(homePath: selectedHome);

      if (record == null) {
        throw GatewayDiscoveryException(
          'No live runtime record for Sanad Home $selectedHome. Start the '
          'Agent for this Home (`sanad daemon`), or pass --gateway-url to '
          'target an endpoint explicitly. If the Agent is running, its log '
          'reports whether it failed to publish this record.',
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
      // The record is filesystem evidence, not authentication: any process
      // running as this user can write it. A record whose owner is gone points
      // at a port that some other process may hold now, so it is stale and no
      // credential is sent to it.
      if (!record.ownerProcessIsAlive) {
        throw GatewayDiscoveryException(
          'The runtime record for Sanad Home $selectedHome was published by '
          'process ${record.ownerProcessId}, which is no longer running (or '
          'could not be verified), so it is stale. Start the Agent for this '
          'Home to publish a new endpoint.',
          code: 'home_runtime_stale',
        );
      }

      final health = await probeHealth(
        host: record.host,
        port: record.port,
        token: token,
        timeout: targetedProbe,
      );
      if (health.rejectedAuthentication) {
        // The record's endpoint answered and refused this Home's credential, so
        // something else now holds the port the record names. Connecting would
        // hand this Home's token to that runtime for nothing.
        throw GatewayDiscoveryException(
          'The endpoint recorded for Sanad Home $selectedHome '
          '(${record.host}:${record.port}) refused this Home\'s credential '
          '(HTTP ${health.statusCode}), so it is not this Home\'s daemon. Start '
          'or restart the Agent for this Home.',
          code: 'home_identity_mismatch',
        );
      }
      if (!health.isHealthy) {
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
        healthData: health.body,
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

      _requireServesHome(
        health,
        expectedHomeId,
        allowLegacyDefaultHome: allowsLegacyDefaultDaemon(envPort),
        target: '$defaultHost:$envPort',
      );

      return GatewayDiscoveryResult(
        gatewayWsUri: Uri.parse('ws://$defaultHost:$envPort/gateway'),
        gatewayHttpUri: Uri.parse('http://$defaultHost:$envPort'),
        token: token,
        isDaemonRunning: health.isHealthy,
        port: envPort,
        host: defaultHost,
        healthData: health.body,
      );
    }

    // 5. Probe default port 58085 first. The answering daemon must prove the
    //    active Home; a daemon that serves another Home is not this caller's
    //    runtime even when it accepts the presented token.
    final defaultHealth = await probeHealth(
      host: defaultHost,
      port: defaultPort,
      token: token,
      timeout: speculativeProbe,
    );

    if (_servesHome(
      defaultHealth,
      expectedHomeId,
      allowLegacyDefaultHome: allowsLegacyDefaultDaemon(defaultPort),
    )) {
      return GatewayDiscoveryResult(
        gatewayWsUri: Uri.parse('ws://$defaultHost:$defaultPort/gateway'),
        gatewayHttpUri: Uri.parse('http://$defaultHost:$defaultPort'),
        token: token,
        isDaemonRunning: true,
        port: defaultPort,
        host: defaultHost,
        healthData: defaultHealth.body,
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
        final futures = <Future<({int port, HealthProbe data})>>[];

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
          if (_servesHome(res.data, expectedHomeId)) {
            return GatewayDiscoveryResult(
              gatewayWsUri: Uri.parse('ws://$defaultHost:${res.port}/gateway'),
              gatewayHttpUri: Uri.parse('http://$defaultHost:${res.port}'),
              token: token,
              isDaemonRunning: true,
              port: res.port,
              host: defaultHost,
              healthData: res.data.body,
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

  /// Whether [probe] is a healthy answer from the daemon that serves
  /// [expectedHomeId].
  ///
  /// Token acceptance alone is not evidence: two Homes that ever shared a
  /// credential would otherwise be interchangeable.
  ///
  /// [allowLegacyDefaultHome] tolerates a *missing* `home_id`, which is what a
  /// daemon released before this contract reports. It is the caller's job to
  /// offer that tolerance only for the default Home on the default port; a
  /// reported identity that differs is always rejected.
  static bool _servesHome(
    HealthProbe? probe,
    String expectedHomeId, {
    bool allowLegacyDefaultHome = false,
  }) {
    if (probe == null || !probe.isHealthy) return false;
    final health = probe.body!;
    if (health['status'] != 'ok') return false;
    final servedHomeId = health[healthHomeIdKey];
    if (servedHomeId == expectedHomeId) return true;
    return allowLegacyDefaultHome && servedHomeId == null;
  }

  /// Rejects an explicit endpoint that does not serve [expectedHomeId].
  ///
  /// An endpoint that did not answer at all is not a mismatch: callers keep
  /// the historical "no daemon here" answer so an explicit target that is
  /// simply down still lets `--standalone` proceed.
  ///
  /// [refuseCredentialRejection] turns an authentication rejection into the
  /// same fail-closed answer. A caller sets it only when a Home is selected,
  /// because then the presented credential belongs to that Home and a runtime
  /// that refuses it is provably not that Home's daemon. Without a selected
  /// Home the historical answer is kept: the legacy default-Home flow lets the
  /// WebSocket handshake report a wrong token.
  static void _requireServesHome(
    HealthProbe probe,
    String expectedHomeId, {
    required bool allowLegacyDefaultHome,
    required String target,
    bool refuseCredentialRejection = false,
  }) {
    if (!probe.answered) return;
    if (_servesHome(
      probe,
      expectedHomeId,
      allowLegacyDefaultHome: allowLegacyDefaultHome,
    )) {
      return;
    }
    if (refuseCredentialRejection && probe.rejectedAuthentication) {
      throw GatewayDiscoveryException(
        'The daemon answering on $target refused this Sanad Home\'s credential '
        '(HTTP ${probe.statusCode}), so it is not this Home\'s runtime. '
        'Refusing to connect. Start the Agent for this Home, or target the '
        'endpoint this Home published.',
        code: 'home_identity_mismatch',
      );
    }
    throw GatewayDiscoveryException(
      'The daemon answering on $target does not serve this Sanad Home. '
      'Refusing to send this Home\'s credential to another runtime.',
      code: 'home_identity_mismatch',
    );
  }
}
