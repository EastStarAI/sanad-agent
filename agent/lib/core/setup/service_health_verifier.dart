import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';

class ServiceHealthExpectation {
  const ServiceHealthExpectation({
    required this.expectedVersion,
    required this.requireCloudRegistration,
    this.timeout = const Duration(seconds: 60),
    this.pollInterval = const Duration(seconds: 1),
  });

  final String expectedVersion;
  final bool requireCloudRegistration;
  final Duration timeout;
  final Duration pollInterval;
}

class ServiceHealthResult {
  const ServiceHealthResult({
    required this.success,
    required this.attempts,
    this.error,
  });

  final bool success;
  final int attempts;
  final String? error;
}

class ServiceHealthVerifier {
  ServiceHealthVerifier({
    Config? config,
    HttpClient Function()? clientFactory,
    Future<void> Function(Duration)? delay,
  }) : _config = config ?? Config(),
       _clientFactory = clientFactory ?? HttpClient.new,
       _delay = delay ?? Future<void>.delayed;

  final Config _config;
  final HttpClient Function() _clientFactory;
  final Future<void> Function(Duration) _delay;

  Future<ServiceHealthResult> verify(
    ServiceHealthExpectation expectation,
  ) async {
    final credential = LocalGatewayCredentials.tryRead();
    if (credential == null) {
      return const ServiceHealthResult(
        success: false,
        attempts: 0,
        error: 'Local Gateway credential is unavailable.',
      );
    }
    final deadline = DateTime.now().add(expectation.timeout);
    var attempts = 0;
    String? lastError;
    do {
      attempts++;
      final client = _clientFactory();
      client.connectionTimeout = const Duration(seconds: 3);
      try {
        final request = await client
            .getUrl(Uri.parse('${_config.localGatewayUrl}/health'))
            .timeout(const Duration(seconds: 3));
        request.headers.set(
          LocalGatewayCredentials.headerName,
          credential.value,
        );
        final response = await request.close().timeout(
          const Duration(seconds: 3),
        );
        final payload = await utf8.decoder
            .bind(response)
            .join()
            .timeout(const Duration(seconds: 3));
        if (response.statusCode != HttpStatus.ok) {
          lastError = 'Local Gateway returned HTTP ${response.statusCode}.';
        } else {
          final decoded = jsonDecode(payload);
          if (decoded is! Map<String, dynamic> || decoded['status'] != 'ok') {
            lastError = 'Local Gateway returned an invalid health response.';
          } else if (decoded['version']?.toString() !=
              expectation.expectedVersion) {
            lastError =
                'Running Agent version does not match the installed artifact.';
          } else if (expectation.requireCloudRegistration &&
              decoded['cloud_registered'] != true) {
            lastError = 'Cloud Gateway registration is not complete.';
          } else {
            return ServiceHealthResult(success: true, attempts: attempts);
          }
        }
      } on Object catch (error) {
        lastError = _concise(error);
      } finally {
        client.close(force: true);
      }
      if (DateTime.now().isBefore(deadline)) {
        await _delay(expectation.pollInterval);
      }
    } while (DateTime.now().isBefore(deadline));

    return ServiceHealthResult(
      success: false,
      attempts: attempts,
      error: lastError,
    );
  }

  static String _concise(Object error) =>
      error.toString().replaceFirst(RegExp(r'^[^:]+: '), '').split('\n').first;
}
