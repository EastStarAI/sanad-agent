import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'mcp_server_config.dart';

enum McpOAuthStatus {
  pending,
  authorizationRequired,
  approved,
  error,
  cancelled,
  expired,
}

class McpOAuthGrant {
  const McpOAuthGrant({
    required this.accessToken,
    this.refreshToken,
    this.expiresIn,
    required this.clientId,
    this.clientSecret,
    required this.authorizationUrl,
    required this.tokenUrl,
  });

  final String accessToken;
  final String? refreshToken;
  final int? expiresIn;
  final String clientId;
  final String? clientSecret;
  final String authorizationUrl;
  final String tokenUrl;
}

class McpOAuthService {
  McpOAuthService({
    http.Client? client,
    this.flowLifetime = const Duration(minutes: 10),
    DateTime Function()? clock,
  }) : _client = client ?? http.Client(),
       _clock = clock ?? DateTime.now;

  final http.Client _client;
  final Duration flowLifetime;
  final DateTime Function() _clock;
  final Map<String, _McpOAuthFlow> _flows = {};

  Future<Map<String, dynamic>> start({
    required McpServerConfig config,
    String? clientSecret,
  }) async {
    if (config.authType != McpAuthType.oauth) {
      throw const FormatException('OAuth flow requires OAuth authentication.');
    }
    final resource = Uri.tryParse(config.serverUrl);
    if (resource == null ||
        (resource.scheme != 'http' && resource.scheme != 'https')) {
      throw const FormatException(
        'OAuth requires a valid HTTP or HTTPS server URL.',
      );
    }

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = Uri.parse(
      'http://${InternetAddress.loopbackIPv4.address}:${server.port}/callback',
    );
    try {
      final metadata = await _discover(config, resource);
      var clientId = config.oauthClientId;
      var resolvedSecret = clientSecret;
      if (clientId?.trim().isEmpty != false) {
        final registered = await _register(metadata, redirectUri);
        clientId = registered.clientId;
        resolvedSecret = registered.clientSecret;
      }
      if (clientId == null || clientId.trim().isEmpty) {
        throw const FormatException(
          'OAuth client ID is required when dynamic registration is unavailable.',
        );
      }

      final flowId = const Uuid().v4();
      final state = _randomUrlSafe(32);
      final verifier = _randomUrlSafe(64);
      final challenge = base64Url
          .encode(sha256.convert(ascii.encode(verifier)).bytes)
          .replaceAll('=', '');
      final authorizationUri = metadata.authorizationEndpoint.replace(
        queryParameters: {
          ...metadata.authorizationEndpoint.queryParameters,
          'response_type': 'code',
          'client_id': clientId,
          'redirect_uri': redirectUri.toString(),
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
          'state': state,
          'resource': resource.toString(),
        },
      );
      final flow = _McpOAuthFlow(
        id: flowId,
        resource: resource,
        server: server,
        redirectUri: redirectUri,
        verifier: verifier,
        state: state,
        clientId: clientId,
        clientSecret: resolvedSecret,
        authorizationEndpoint: metadata.authorizationEndpoint,
        tokenEndpoint: metadata.tokenEndpoint,
        authorizationUri: authorizationUri,
        expiresAt: _clock().add(flowLifetime),
      );
      _flows[flowId] = flow;
      flow.expiryTimer = Timer(flowLifetime, () {
        if (!_terminal(flow.status)) {
          flow.status = McpOAuthStatus.expired;
          flow.error = 'Authorization expired. Start a new flow.';
          unawaited(flow.server.close(force: true));
        }
      });
      unawaited(_listen(flow));
      flow.status = McpOAuthStatus.authorizationRequired;
      return _snapshot(flow);
    } catch (_) {
      await server.close(force: true);
      rethrow;
    }
  }

  Map<String, dynamic> status(String flowId) {
    final flow = _required(flowId);
    _expireIfNeeded(flow);
    return _snapshot(flow);
  }

  Future<Map<String, dynamic>> cancel(String flowId) async {
    final flow = _required(flowId);
    if (!_terminal(flow.status)) {
      flow.status = McpOAuthStatus.cancelled;
      flow.error = 'Authorization was cancelled.';
      flow.expiryTimer?.cancel();
      await flow.server.close(force: true);
    }
    return _snapshot(flow);
  }

  McpOAuthGrant consumeApproved(String flowId) {
    final flow = _required(flowId);
    _expireIfNeeded(flow);
    if (flow.status != McpOAuthStatus.approved || flow.grant == null) {
      throw StateError('OAuth flow is not approved.');
    }
    _flows.remove(flowId);
    flow.expiryTimer?.cancel();
    return flow.grant!;
  }

  Future<McpOAuthGrant> refresh({
    required McpServerConfig config,
    required String refreshToken,
    String? clientSecret,
  }) async {
    final tokenEndpoint = Uri.tryParse(config.oauthTokenUrl ?? '');
    final clientId = config.oauthClientId;
    if (!_isHttpUri(tokenEndpoint) || clientId?.trim().isEmpty != false) {
      throw const FormatException('OAuth refresh metadata is incomplete.');
    }
    final response = await _client
        .post(
          tokenEndpoint!,
          headers: const {'content-type': 'application/x-www-form-urlencoded'},
          body: {
            'grant_type': 'refresh_token',
            'refresh_token': refreshToken,
            'client_id': clientId!,
            'client_secret': ?clientSecret,
            'resource': config.serverUrl,
          },
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('OAuth refresh failed.');
    }
    final json = _jsonObject(response.body, 'OAuth refresh response');
    final accessToken = json['access_token']?.toString();
    if (accessToken == null || accessToken.isEmpty) {
      throw const FormatException(
        'OAuth refresh response omitted access_token.',
      );
    }
    return McpOAuthGrant(
      accessToken: accessToken,
      refreshToken: json['refresh_token']?.toString() ?? refreshToken,
      expiresIn: _int(json['expires_in']),
      clientId: clientId,
      clientSecret: clientSecret,
      authorizationUrl: config.oauthAuthUrl ?? '',
      tokenUrl: tokenEndpoint.toString(),
    );
  }

  Future<void> dispose() async {
    final flows = _flows.values.toList(growable: false);
    _flows.clear();
    for (final flow in flows) {
      flow.expiryTimer?.cancel();
    }
    await Future.wait(flows.map((flow) => flow.server.close(force: true)));
    _client.close();
  }

  Future<void> _listen(_McpOAuthFlow flow) async {
    try {
      await for (final request in flow.server) {
        if (request.uri.path != '/callback') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          continue;
        }
        if (_terminal(flow.status)) {
          request.response.statusCode = HttpStatus.gone;
          await request.response.close();
          continue;
        }
        final error = request.uri.queryParameters['error'];
        final returnedState = request.uri.queryParameters['state'];
        final code = request.uri.queryParameters['code'];
        if (error != null) {
          flow.status = McpOAuthStatus.error;
          flow.error = 'Authorization server rejected the request.';
        } else if (returnedState != flow.state ||
            code == null ||
            code.isEmpty) {
          flow.status = McpOAuthStatus.error;
          flow.error = 'OAuth callback validation failed.';
        } else {
          flow.status = McpOAuthStatus.pending;
          try {
            flow.grant = await _exchange(flow, code);
            flow.status = McpOAuthStatus.approved;
          } catch (_) {
            flow.status = McpOAuthStatus.error;
            flow.error = 'OAuth token exchange failed.';
          }
        }
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write(
            '<!doctype html><title>Sanad MCP authorization</title><p>You can return to Sanad.</p>',
          );
        await request.response.close();
        flow.expiryTimer?.cancel();
        await flow.server.close(force: true);
        break;
      }
    } catch (_) {
      if (!_terminal(flow.status)) {
        flow.status = McpOAuthStatus.error;
        flow.error = 'OAuth callback listener closed unexpectedly.';
      }
    }
  }

  Future<McpOAuthGrant> _exchange(_McpOAuthFlow flow, String code) async {
    final response = await _client
        .post(
          flow.tokenEndpoint,
          headers: const {'content-type': 'application/x-www-form-urlencoded'},
          body: {
            'grant_type': 'authorization_code',
            'code': code,
            'redirect_uri': flow.redirectUri.toString(),
            'client_id': flow.clientId,
            'code_verifier': flow.verifier,
            if (flow.clientSecret != null) 'client_secret': flow.clientSecret!,
            'resource': flow.resource.toString(),
          },
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('Token endpoint rejected the request.');
    }
    final json = _jsonObject(response.body, 'OAuth token response');
    final accessToken = json['access_token']?.toString();
    if (accessToken == null || accessToken.isEmpty) {
      throw const FormatException('OAuth token response omitted access_token.');
    }
    return McpOAuthGrant(
      accessToken: accessToken,
      refreshToken: json['refresh_token']?.toString(),
      expiresIn: _int(json['expires_in']),
      clientId: flow.clientId,
      clientSecret: flow.clientSecret,
      authorizationUrl: flow.authorizationEndpoint.toString(),
      tokenUrl: flow.tokenEndpoint.toString(),
    );
  }

  Future<_OAuthMetadata> _discover(McpServerConfig config, Uri resource) async {
    final explicitAuthorization = Uri.tryParse(config.oauthAuthUrl ?? '');
    final explicitToken = Uri.tryParse(config.oauthTokenUrl ?? '');
    if (_isHttpUri(explicitAuthorization) && _isHttpUri(explicitToken)) {
      return _OAuthMetadata(
        authorizationEndpoint: explicitAuthorization!,
        tokenEndpoint: explicitToken!,
      );
    }

    Uri authorizationServer = resource.replace(
      path: '/.well-known/oauth-authorization-server',
      query: null,
      fragment: null,
    );
    final protectedUri = resource.replace(
      path: '/.well-known/oauth-protected-resource',
      query: null,
      fragment: null,
    );
    final protected = await _getOptionalJson(protectedUri);
    final advertised = protected?['authorization_servers'];
    if (advertised is List && advertised.isNotEmpty) {
      final value = Uri.tryParse(advertised.first.toString());
      if (value != null) {
        authorizationServer = value.replace(
          path:
              '${value.path == '/' ? '' : value.path}/.well-known/oauth-authorization-server',
          query: null,
          fragment: null,
        );
      }
    }
    final metadata = await _getRequiredJson(
      authorizationServer,
      'OAuth discovery',
    );
    final authorization = Uri.tryParse(
      metadata['authorization_endpoint']?.toString() ?? '',
    );
    final token = Uri.tryParse(metadata['token_endpoint']?.toString() ?? '');
    if (authorization == null || token == null) {
      throw const FormatException(
        'OAuth discovery omitted required endpoints.',
      );
    }
    final registration = Uri.tryParse(
      metadata['registration_endpoint']?.toString() ?? '',
    );
    return _OAuthMetadata(
      authorizationEndpoint: authorization,
      tokenEndpoint: token,
      registrationEndpoint: _isHttpUri(registration) ? registration : null,
    );
  }

  Future<({String clientId, String? clientSecret})> _register(
    _OAuthMetadata metadata,
    Uri redirectUri,
  ) async {
    final endpoint = metadata.registrationEndpoint;
    if (endpoint == null) {
      throw const FormatException(
        'OAuth client ID is required; dynamic registration is unavailable.',
      );
    }
    final response = await _client
        .post(
          endpoint,
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({
            'client_name': 'Sanad Agent',
            'redirect_uris': [redirectUri.toString()],
            'grant_types': ['authorization_code', 'refresh_token'],
            'response_types': ['code'],
            'token_endpoint_auth_method': 'none',
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('OAuth dynamic registration failed.');
    }
    final json = _jsonObject(response.body, 'OAuth registration response');
    final clientId = json['client_id']?.toString();
    if (clientId == null || clientId.isEmpty) {
      throw const FormatException('OAuth registration omitted client_id.');
    }
    return (
      clientId: clientId,
      clientSecret: json['client_secret']?.toString(),
    );
  }

  Future<Map<String, dynamic>?> _getOptionalJson(Uri uri) async {
    try {
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      return _jsonObject(response.body, 'OAuth metadata');
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>> _getRequiredJson(Uri uri, String label) async {
    final response = await _client
        .get(uri)
        .timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('$label failed.');
    }
    return _jsonObject(response.body, label);
  }

  Map<String, dynamic> _snapshot(_McpOAuthFlow flow) => {
    'flow_id': flow.id,
    'status': _wireStatus(flow.status),
    if (flow.status == McpOAuthStatus.authorizationRequired)
      'authorization_url': flow.authorizationUri.toString(),
    if (flow.error != null) 'error': flow.error,
    'expires_at': flow.expiresAt.toUtc().toIso8601String(),
  };

  _McpOAuthFlow _required(String flowId) {
    final flow = _flows[flowId];
    if (flow == null) {
      throw StateError('OAuth flow not found or already consumed.');
    }
    return flow;
  }

  void _expireIfNeeded(_McpOAuthFlow flow) {
    if (!_terminal(flow.status) && !_clock().isBefore(flow.expiresAt)) {
      flow.status = McpOAuthStatus.expired;
      flow.error = 'Authorization expired. Start a new flow.';
      unawaited(flow.server.close(force: true));
    }
  }

  bool _terminal(McpOAuthStatus status) => const {
    McpOAuthStatus.approved,
    McpOAuthStatus.error,
    McpOAuthStatus.cancelled,
    McpOAuthStatus.expired,
  }.contains(status);

  String _wireStatus(McpOAuthStatus status) => switch (status) {
    McpOAuthStatus.authorizationRequired => 'authorization_required',
    _ => status.name,
  };

  String _randomUrlSafe(int bytes) {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(bytes, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  Map<String, dynamic> _jsonObject(String body, String label) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw FormatException('$label must be a JSON object.');
    return Map<String, dynamic>.from(decoded);
  }

  int? _int(Object? value) =>
      value is int ? value : int.tryParse(value?.toString() ?? '');

  bool _isHttpUri(Uri? value) =>
      value != null &&
      value.hasAuthority &&
      (value.scheme == 'http' || value.scheme == 'https');
}

class _OAuthMetadata {
  const _OAuthMetadata({
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    this.registrationEndpoint,
  });

  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
  final Uri? registrationEndpoint;
}

class _McpOAuthFlow {
  _McpOAuthFlow({
    required this.id,
    required this.resource,
    required this.server,
    required this.redirectUri,
    required this.verifier,
    required this.state,
    required this.clientId,
    required this.clientSecret,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.authorizationUri,
    required this.expiresAt,
  });

  final String id;
  final Uri resource;
  final HttpServer server;
  final Uri redirectUri;
  final String verifier;
  final String state;
  final String clientId;
  final String? clientSecret;
  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
  final Uri authorizationUri;
  final DateTime expiresAt;
  McpOAuthStatus status = McpOAuthStatus.pending;
  String? error;
  McpOAuthGrant? grant;
  Timer? expiryTimer;
}
