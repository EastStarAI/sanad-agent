import 'package:dio/dio.dart';
import 'package:logging/logging.dart';

import 'package:sanad_client/core/config/app_config.dart';
import 'package:sanad_client/features/auth/domain/client_instance_identity.dart';

class PortalClientTransaction {
  final String transactionId;
  final String authorizationUrl;
  final int expiresIn;

  const PortalClientTransaction({
    required this.transactionId,
    required this.authorizationUrl,
    required this.expiresIn,
  });

  factory PortalClientTransaction.fromJson(Map<String, dynamic> json) {
    return PortalClientTransaction(
      transactionId: json['transaction_id'] as String,
      authorizationUrl: json['authorization_url'] as String,
      expiresIn: (json['expires_in'] as num?)?.toInt() ?? 300,
    );
  }
}

class PortalAuthTokens {
  final String accessToken;
  final String? refreshToken;
  final String tokenType;

  const PortalAuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.tokenType,
  });

  factory PortalAuthTokens.fromJson(Map<String, dynamic> json) {
    return PortalAuthTokens(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      tokenType: (json['token_type'] as String?) ?? 'bearer',
    );
  }
}

class PortalAuthRefresh extends PortalAuthTokens {
  const PortalAuthRefresh({
    required super.accessToken,
    required super.refreshToken,
    required super.tokenType,
  });

  factory PortalAuthRefresh.fromJson(Map<String, dynamic> json) {
    final tokens = PortalAuthTokens.fromJson(json);
    return PortalAuthRefresh(
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
      tokenType: tokens.tokenType,
    );
  }
}

/// Provider-neutral SEC-01E Portal client.
class PortalAuthClient {
  static final _logger = Logger('PortalAuthClient');
  final Dio _dio;
  final Future<Map<String, dynamic>> Function(
    String path,
    Map<String, dynamic> data,
  )?
  _postOverride;

  PortalAuthClient({
    Dio? dio,
    Future<Map<String, dynamic>> Function(
      String path,
      Map<String, dynamic> data,
    )?
    postOverride,
  }) : _dio =
           dio ??
           (Dio()
             ..options.connectTimeout = const Duration(seconds: 5)
             ..options.receiveTimeout = const Duration(seconds: 5)),
       _postOverride = postOverride;

  static String get portalUrl => AppConfig.portalUrl;

  String _url(String path) => '${portalUrl.replaceAll(RegExp(r'/+$'), '')}$path';

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> data,
  ) async {
    final override = _postOverride;
    if (override != null) return override(path, data);
    final response = await _dio.post(_url(path), data: data);
    return response.data as Map<String, dynamic>;
  }

  Future<PortalClientTransaction> createClientTransaction({
    required String clientId,
    required String redirectUri,
    required String codeChallenge,
    String? enrollmentRequestId,
    String? clientInstanceId,
    ClientDisplayMetadata? metadata,
  }) async {
    final data = await _post('/auth/client/transactions', {
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
      if (enrollmentRequestId != null) 'enrollment_request_id': enrollmentRequestId,
      if (clientInstanceId != null) 'client_instance_id': clientInstanceId,
      if (metadata != null) 'metadata': metadata.toJson(),
      if (clientInstanceId != null) 'capabilities': const ['account_sessions_v1'],
    });
    return PortalClientTransaction.fromJson(data);
  }

  Future<PortalAuthTokens> redeemAuthorizationCode({
    required String clientId,
    required String redirectUri,
    required String code,
    required String codeVerifier,
  }) async {
    final data = await _post('/auth/client/token', {
      'grant_type': 'authorization_code',
      'client_id': clientId,
      'redirect_uri': redirectUri,
      'code': code,
      'code_verifier': codeVerifier,
    });
    return PortalAuthTokens.fromJson(data);
  }

  Future<PortalAuthRefresh> refresh({required String refreshToken}) async {
    final data = await _post('/auth/refresh', {'refresh_token': refreshToken});
    return PortalAuthRefresh.fromJson(data);
  }

  Future<Map<String, dynamic>> listAccountSessions({
    required String accessToken,
    String? cursor,
    int limit = 100,
  }) {
    return _post('/auth/account/sessions', {
      'access_token': accessToken,
      'cursor': cursor,
      'limit': limit,
    });
  }

  Future<Map<String, dynamic>> revokeAccountPrincipal({
    required String accessToken,
    required String targetKind,
    required String targetId,
    required String requestId,
  }) {
    return _post('/auth/account/revoke', {
      'access_token': accessToken,
      'target_kind': targetKind,
      'target_id': targetId,
      'request_id': requestId,
      'mode': 'target_only',
    });
  }

  Future<void> logout({String? accessToken, String? refreshToken}) async {
    try {
      await _post('/auth/logout', {
        if (accessToken != null) 'access_token': accessToken,
        if (refreshToken != null) 'refresh_token': refreshToken,
      });
    } catch (error) {
      _logger.warning('Portal auth logout failed: ${error.runtimeType}');
    }
  }
}
