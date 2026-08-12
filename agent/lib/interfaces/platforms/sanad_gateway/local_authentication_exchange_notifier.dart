import 'dart:convert';

import 'package:http/http.dart' as http;

import 'local_gateway_credentials.dart';

enum LocalAuthenticationExchangeOutcome {
  notified,
  daemonUnavailable,
  daemonRejected,
}

class LocalAuthenticationExchangeNotifier {
  LocalAuthenticationExchangeNotifier({
    http.Client Function()? clientFactory,
    Future<LocalGatewayCredential> Function()? credentialLoader,
    Future<void> Function(Duration duration)? delay,
    this.maximumAttempts = 3,
    this.requestTimeout = const Duration(seconds: 2),
    this.retryDelay = const Duration(milliseconds: 150),
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _credentialLoader =
           credentialLoader ?? LocalGatewayCredentials.loadOrCreate,
       _delay = delay ?? Future<void>.delayed {
    if (maximumAttempts < 1) {
      throw ArgumentError.value(maximumAttempts, 'maximumAttempts');
    }
  }

  final http.Client Function() _clientFactory;
  final Future<LocalGatewayCredential> Function() _credentialLoader;
  final Future<void> Function(Duration duration) _delay;
  final int maximumAttempts;
  final Duration requestTimeout;
  final Duration retryDelay;

  Future<LocalAuthenticationExchangeOutcome> notify(
    String localGatewayUrl,
  ) async {
    final base = Uri.tryParse(localGatewayUrl);
    if (base == null || !base.hasScheme || base.host.isEmpty) {
      return LocalAuthenticationExchangeOutcome.daemonUnavailable;
    }

    final LocalGatewayCredential credential;
    try {
      credential = await _credentialLoader();
    } on Object {
      return LocalAuthenticationExchangeOutcome.daemonUnavailable;
    }

    final client = _clientFactory();
    var receivedHttpResponse = false;
    try {
      final exchangeUri = base.replace(
        path: '/authentication-exchange',
        query: null,
        fragment: null,
      );
      for (var attempt = 0; attempt < maximumAttempts; attempt++) {
        try {
          final response = await client
              .post(
                exchangeUri,
                headers: {LocalGatewayCredentials.headerName: credential.value},
              )
              .timeout(requestTimeout);
          receivedHttpResponse = true;
          if (_isAcknowledged(response)) {
            return LocalAuthenticationExchangeOutcome.notified;
          }
        } on Object {
          // A stopped or starting daemon is expected during installation.
        }
        if (attempt + 1 < maximumAttempts) {
          await _delay(retryDelay);
        }
      }

      if (receivedHttpResponse) {
        return LocalAuthenticationExchangeOutcome.daemonRejected;
      }

      try {
        await client
            .get(
              base.replace(path: '/health', query: null, fragment: null),
              headers: {LocalGatewayCredentials.headerName: credential.value},
            )
            .timeout(requestTimeout);
        return LocalAuthenticationExchangeOutcome.daemonRejected;
      } on Object {
        return LocalAuthenticationExchangeOutcome.daemonUnavailable;
      }
    } finally {
      client.close();
    }
  }

  bool _isAcknowledged(http.Response response) {
    if (response.statusCode != 200) return false;
    try {
      final payload = jsonDecode(response.body);
      return payload is Map<String, dynamic> && payload['success'] == true;
    } on FormatException {
      return false;
    }
  }
}
