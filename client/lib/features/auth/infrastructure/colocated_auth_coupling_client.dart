import 'dart:async';

import 'package:dio/dio.dart';
import 'package:sanad_client/core/config/app_config.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_credential_provider.dart';
import 'package:sanad_client/utils/app_platform.dart';

class ColocatedEnrollmentRequest {
  const ColocatedEnrollmentRequest({
    required this.requestId,
    required this.expiresIn,
  });

  final String requestId;
  final int expiresIn;
}

/// Credential-safe Desktop adapter for the Local Agent coupling endpoint.
class ColocatedAuthCouplingClient {
  ColocatedAuthCouplingClient({
    Dio? dio,
    LocalGatewayCredentialProvider? credentialProvider,
    Future<void> Function(Duration duration)? delay,
    Future<Map<String, dynamic>> Function(String method)? requestOverride,
    String? baseUrl,
    bool? isDesktop,
  }) : _dio = dio ?? Dio(),
       _credentialProvider =
           credentialProvider ?? const LocalGatewayCredentialProvider(),
       _delay = delay ?? Future<void>.delayed,
       _requestOverride = requestOverride,
       _baseUrlOverride = baseUrl,
       _isDesktop = isDesktop ?? AppPlatform.isDesktop;

  static const _pollInterval = Duration(milliseconds: 500);
  static const _maximumCompletionWait = Duration(minutes: 5);

  final Dio _dio;
  final LocalGatewayCredentialProvider _credentialProvider;
  final Future<void> Function(Duration duration) _delay;
  final Future<Map<String, dynamic>> Function(String method)? _requestOverride;
  final String? _baseUrlOverride;
  final bool _isDesktop;
  String get _gatewayBaseUrl => (_baseUrlOverride ?? AppConfig.localGatewayUrl)
      .replaceAll(RegExp(r'/+$'), '');
  String get _url => '$_gatewayBaseUrl/auth/coupling';
  String get _logoutUrl => '$_gatewayBaseUrl/auth/logout';

  Future<Map<String, dynamic>> _request(String method) async {
    final override = _requestOverride;
    if (override != null) return override(method);
    final options = Options(
      headers: await _credentialProvider.headers(),
      sendTimeout: const Duration(seconds: 3),
      receiveTimeout: method == 'POST'
          ? const Duration(seconds: 8)
          : const Duration(seconds: 5),
    );
    final response = switch (method) {
      'POST' => await _dio.post<Map<String, dynamic>>(_url, options: options),
      'DELETE' => await _dio.delete<Map<String, dynamic>>(
        _url,
        options: options,
      ),
      _ => await _dio.get<Map<String, dynamic>>(_url, options: options),
    };
    return response.data ?? const <String, dynamic>{};
  }

  Future<void> logoutAgent() async {
    if (!_isDesktop) return;
    try {
      await _dio.post<void>(
        _logoutUrl,
        options: Options(
          headers: await _credentialProvider.headers(),
          sendTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 3),
        ),
      );
    } on Object {
      // Client logout remains authoritative when the optional Local Agent is
      // absent or temporarily unreachable. The persisted pending marker makes
      // the old Agent credential fail closed on its next startup.
    }
  }

  Future<ColocatedEnrollmentRequest?> start() async {
    if (!_isDesktop) return null;
    try {
      final data = await _request('POST');
      if (data['status'] == 'already_authorized') return null;
      if (data['status'] != 'pending') return null;
      final requestId = data['enrollment_request_id']?.toString() ?? '';
      if (requestId.isEmpty) return null;
      return ColocatedEnrollmentRequest(
        requestId: requestId,
        expiresIn: (data['expires_in'] as num?)?.toInt() ?? 300,
      );
    } on Object {
      // Absence or temporary failure of the optional Local Agent must not block
      // Client-only authentication.
      return null;
    }
  }

  Future<void> cancel() async {
    if (!_isDesktop) return;
    await _request('DELETE');
  }

  Future<void> waitForCompletion(ColocatedEnrollmentRequest request) async {
    final requested = Duration(seconds: request.expiresIn);
    final timeout = requested < _maximumCompletionWait
        ? requested
        : _maximumCompletionWait;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final data = await _request('GET');
      final returnedId = data['enrollment_request_id']?.toString();
      if (returnedId != null && returnedId != request.requestId) {
        throw StateError('Local Agent coupling request changed.');
      }
      switch (data['status']) {
        case 'completed':
        case 'already_authorized':
          return;
        case 'failed':
          throw StateError('Local Agent could not complete sign-in.');
      }
      await _delay(_pollInterval);
    }
    throw TimeoutException('Local Agent sign-in completion timed out.');
  }
}
