/// Local Gateway security policy: credential verification, Origin/Host
/// allowlist, and pre-auth upgrade budget (SEC-02 / Gate B).
library;

import 'dart:io';

import 'package:sanad_agent/core/sanad_home/loopback_policy.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';

enum LocalGatewayAuthOutcome {
  ok,
  missingCredential,
  invalidCredential,
  peerRejected,
  hostRejected,
  originRejected,
  budgetExhausted,
}

class LocalGatewayAuthResult {
  final LocalGatewayAuthOutcome outcome;
  final String? reason;
  const LocalGatewayAuthResult._(this.outcome, this.reason);

  factory LocalGatewayAuthResult.ok() =>
      const LocalGatewayAuthResult._(LocalGatewayAuthOutcome.ok, null);
  factory LocalGatewayAuthResult.missingCredential([String? reason]) =>
      LocalGatewayAuthResult._(
        LocalGatewayAuthOutcome.missingCredential,
        reason,
      );
  factory LocalGatewayAuthResult.invalidCredential([String? reason]) =>
      LocalGatewayAuthResult._(
        LocalGatewayAuthOutcome.invalidCredential,
        reason,
      );
  factory LocalGatewayAuthResult.peerRejected(String reason) =>
      LocalGatewayAuthResult._(LocalGatewayAuthOutcome.peerRejected, reason);
  factory LocalGatewayAuthResult.hostRejected(String reason) =>
      LocalGatewayAuthResult._(LocalGatewayAuthOutcome.hostRejected, reason);
  factory LocalGatewayAuthResult.originRejected(String reason) =>
      LocalGatewayAuthResult._(LocalGatewayAuthOutcome.originRejected, reason);
  factory LocalGatewayAuthResult.budgetExhausted([String? reason]) =>
      LocalGatewayAuthResult._(LocalGatewayAuthOutcome.budgetExhausted, reason);

  bool get isOk => outcome == LocalGatewayAuthOutcome.ok;
}

class LocalGatewaySecurityConfig {
  final int allowedPort;
  final Set<String> allowedOrigins;
  final Set<String> allowedHosts;
  final int preauthBudgetPerPeer;
  final Duration preauthCoolDown;

  const LocalGatewaySecurityConfig({
    required this.allowedPort,
    this.allowedOrigins = const {},
    this.allowedHosts = const {'127.0.0.0/8', '::1', 'localhost'},
    this.preauthBudgetPerPeer = 8,
    this.preauthCoolDown = const Duration(seconds: 30),
  });
}

class LocalGatewaySecurity {
  final LocalGatewaySecurityConfig config;
  final LocalGatewayCredential expectedToken;
  final Map<String, int> _inflight = <String, int>{};
  final Map<String, DateTime> _coolDown = <String, DateTime>{};
  final DateTime Function() _now;

  LocalGatewaySecurity({
    required this.config,
    required this.expectedToken,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    if (expectedToken.value.trim().isEmpty) {
      throw ArgumentError.value(
        expectedToken,
        'expectedToken',
        'Local Gateway credentials must never be empty.',
      );
    }
    if (config.preauthBudgetPerPeer < 1) {
      throw ArgumentError.value(
        config.preauthBudgetPerPeer,
        'preauthBudgetPerPeer',
        'The pre-auth handshake budget must be positive.',
      );
    }
    if (config.allowedPort < 1 || config.allowedPort > 65535) {
      throw ArgumentError.value(
        config.allowedPort,
        'allowedPort',
        'The Local Gateway port must be valid.',
      );
    }
  }

  /// Verifies a request or WebSocket upgrade against the full policy.
  /// The caller reserves a pre-auth handshake slot before invoking this
  /// method. This method then verifies the credential, mandatory Host
  /// allowlist, and optional Origin allowlist in that order.
  LocalGatewayAuthResult verify({
    required Map<String, String> headers,
    required InternetAddress? remoteAddress,
    String? origin,
  }) {
    return _verifyInternal(
      headers: headers,
      remoteAddress: remoteAddress,
      origin: origin,
    );
  }

  /// Verifies an HTTP request using the [HttpHeaders] map directly.
  /// The helper extracts the credential, the Origin header, and the
  /// Host header for the allowlist and credential checks.
  LocalGatewayAuthResult verifyHttp({
    required HttpHeaders headers,
    required InternetAddress? remoteAddress,
  }) {
    final headerMap = <String, String>{};
    final custom = headers.value(LocalGatewayCredentials.headerName);
    if (custom != null) {
      headerMap[LocalGatewayCredentials.headerName] = custom;
    }
    final auth =
        headers.value('authorization') ?? headers.value('Authorization');
    if (auth != null) {
      headerMap['authorization'] = auth;
    }
    final host = headers.value('host') ?? headers.value('Host');
    if (host != null) {
      headerMap['host'] = host;
    }
    return _verifyInternal(
      headers: headerMap,
      remoteAddress: remoteAddress,
      origin: headers.value('origin'),
    );
  }

  LocalGatewayAuthResult _verifyInternal({
    required Map<String, String> headers,
    required InternetAddress? remoteAddress,
    String? origin,
  }) {
    final normalizedHeaders = <String, String>{
      for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
    };
    final presented = LocalGatewayCredentials.extractFromHeaders(
      normalizedHeaders,
      expectedToken.value,
    );
    if (presented == null) {
      if (!normalizedHeaders.containsKey(LocalGatewayCredentials.headerName) &&
          !normalizedHeaders.containsKey('authorization')) {
        return LocalGatewayAuthResult.missingCredential();
      }
      return LocalGatewayAuthResult.invalidCredential();
    }
    if (remoteAddress == null || !remoteAddress.isLoopback) {
      return LocalGatewayAuthResult.peerRejected('peer_not_loopback');
    }
    final hostVerdict = evaluateHost(normalizedHeaders['host']);
    if (!hostVerdict.ok) {
      return LocalGatewayAuthResult.hostRejected(hostVerdict.reason);
    }
    if (origin != null && origin.isNotEmpty) {
      final verdict = evaluateOrigin(origin: origin);
      if (!verdict.ok) {
        return LocalGatewayAuthResult.originRejected(verdict.reason);
      }
    }
    return LocalGatewayAuthResult.ok();
  }

  /// Returns true if a new upgrade from [peerKey] is allowed. Callers
  /// MUST pair each `true` return with a matching [releaseUpgrade] when
  /// the upgrade completes (whether or not it succeeds).
  bool tryReserveUpgrade(String peerKey) {
    final coolDown = _coolDown[peerKey];
    if (coolDown != null && _now().isBefore(coolDown)) {
      return false;
    }
    if (!_hasBudget(peerKey)) {
      _coolDown[peerKey] = _now().add(config.preauthCoolDown);
      return false;
    }
    _inflight[peerKey] = (_inflight[peerKey] ?? 0) + 1;
    return true;
  }

  /// Releases a previously-reserved upgrade slot. Always call after
  /// [tryReserveUpgrade] returns true, including on error.
  void releaseUpgrade(String peerKey) {
    final current = _inflight[peerKey] ?? 0;
    if (current <= 0) return;
    _inflight[peerKey] = current - 1;
    if (_inflight[peerKey] == 0) {
      _inflight.remove(peerKey);
    }
  }

  OriginCheckResult evaluateOrigin({required String origin}) {
    final parsed = _parseOrigin(origin);
    if (parsed == null) {
      return const OriginCheckResult(false, 'origin missing or invalid');
    }
    final allowlist = config.allowedOrigins
        .map((o) => o.trim().toLowerCase())
        .where((o) => o.isNotEmpty)
        .toSet();
    if (allowlist.contains(parsed.origin)) {
      return const OriginCheckResult(true, 'allowlist');
    }
    return const OriginCheckResult(false, 'origin not allowed');
  }

  HostCheckResult evaluateHost(String? requestHost) {
    final parsed = _parseHost(requestHost);
    if (parsed == null) {
      return const HostCheckResult(false, 'host missing or invalid');
    }
    if (parsed.port != config.allowedPort) {
      return const HostCheckResult(false, 'host port not allowed');
    }
    final allowlist = config.allowedHosts
        .map((host) => host.trim().toLowerCase())
        .where((host) => host.isNotEmpty)
        .toSet();
    if (allowlist.contains(parsed.authority) ||
        allowlist.contains(parsed.hostname)) {
      return const HostCheckResult(true, 'allowlist');
    }
    if (allowlist.contains('127.0.0.0/8') &&
        parsed.hostname.startsWith('127.') &&
        LoopbackPolicy.isLoopbackHost(parsed.hostname)) {
      return const HostCheckResult(true, 'ipv4_loopback_range');
    }
    return const HostCheckResult(false, 'host not allowed');
  }

  bool _hasBudget(String peerKey) {
    final current = _inflight[peerKey] ?? 0;
    if (current >= config.preauthBudgetPerPeer) return false;
    return true;
  }

  static _ParsedOrigin? _parseOrigin(String origin) {
    final trimmed = origin.trim();
    if (trimmed.isEmpty || trimmed == 'null') return null;
    try {
      final uri = Uri.parse(trimmed);
      if (!uri.hasScheme) return null;
      if (uri.scheme != 'http' &&
          uri.scheme != 'https' &&
          uri.scheme != 'ws' &&
          uri.scheme != 'wss') {
        return null;
      }
      if (uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.path.isNotEmpty ||
          uri.query.isNotEmpty ||
          uri.fragment.isNotEmpty) {
        return null;
      }
      return _ParsedOrigin(
        origin:
            '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}'
                .toLowerCase(),
        host: uri.host.toLowerCase(),
        hostname: uri.host.toLowerCase(),
      );
    } catch (_) {
      return null;
    }
  }

  static _ParsedHost? _parseHost(String? host) {
    final trimmed = host?.trim().toLowerCase() ?? '';
    if (trimmed.isEmpty || trimmed.contains(',') || trimmed.contains('@')) {
      return null;
    }
    final uri = Uri.tryParse('http://$trimmed');
    if (uri == null || uri.host.isEmpty || uri.path.isNotEmpty) return null;
    if (uri.query.isNotEmpty || uri.fragment.isNotEmpty) return null;
    final hostname = uri.host.toLowerCase();
    final authority = uri.hasPort
        ? '${hostname.contains(':') ? '[$hostname]' : hostname}:${uri.port}'
        : hostname;
    return _ParsedHost(
      hostname: hostname,
      authority: authority,
      port: uri.hasPort ? uri.port : null,
    );
  }
}

class _ParsedHost {
  final String hostname;
  final String authority;
  final int? port;
  const _ParsedHost({
    required this.hostname,
    required this.authority,
    required this.port,
  });
}

class _ParsedOrigin {
  final String origin;
  final String host;
  final String hostname;
  const _ParsedOrigin({
    required this.origin,
    required this.host,
    required this.hostname,
  });
}

class OriginCheckResult {
  final bool ok;
  final String reason;
  const OriginCheckResult(this.ok, this.reason);
}

class HostCheckResult {
  final bool ok;
  final String reason;
  const HostCheckResult(this.ok, this.reason);
}
