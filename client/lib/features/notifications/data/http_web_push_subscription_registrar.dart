import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_subscription.dart';
import 'package:sanad_client/features/notifications/domain/repositories/web_push_subscription_registrar.dart';

/// The public half of the hosted push-registration contract (Plan 174e).
///
/// `POST {backend}/api/notifications/web-push/subscriptions` and
/// `DELETE {backend}/api/notifications/web-push/subscriptions` with the account
/// bearer token. The relay stores the opaque endpoint against the account and
/// resolves it when the Agent names this Client instance or the whole account.
/// It never parses a notification, and this class never sees one.
///
/// Failure is contained: an unreachable or undeployed route leaves the local
/// subscription in place and reports an outcome, so the Client never loses its
/// browser permission because the hosted side was unavailable. The endpoint and
/// the keys are never logged.
class HttpWebPushSubscriptionRegistrar implements WebPushSubscriptionRegistrar {
  HttpWebPushSubscriptionRegistrar({
    required Uri baseUrl,
    http.Client? client,
    Duration timeout = const Duration(seconds: 12),
  }) : _baseUrl = baseUrl,
       _client = client ?? http.Client(),
       _timeout = timeout;

  static final Logger _logger = Logger('notifications.web_push.relay');

  final Uri _baseUrl;
  final http.Client _client;
  final Duration _timeout;

  Uri get _endpoint => _baseUrl.resolve('/api/notifications/web-push/subscriptions');

  @override
  Future<WebPushRegistrationOutcome> register(
    WebPushSubscription subscription, {
    required String accessToken,
    required String clientInstanceId,
    DateTime? createdAt,
  }) {
    return _send(
      request: (headers) => http.Request('POST', _endpoint)
        ..headers.addAll(headers)
        ..body = jsonEncode(
          subscription.toRegistrationJson(
            clientInstanceId: clientInstanceId,
            createdAt: createdAt,
          ),
        ),
      accessToken: accessToken,
      success: WebPushRegistrationOutcome.registered,
      action: 'register',
    );
  }

  @override
  Future<WebPushRegistrationOutcome> revoke(
    String endpoint, {
    required String accessToken,
  }) {
    return _send(
      request: (headers) => http.Request('DELETE', _endpoint)
        ..headers.addAll(headers)
        ..body = jsonEncode(<String, String>{'endpoint': endpoint}),
      accessToken: accessToken,
      success: WebPushRegistrationOutcome.revoked,
      action: 'revoke',
    );
  }

  Future<WebPushRegistrationOutcome> _send({
    required http.Request Function(Map<String, String> headers) request,
    required String accessToken,
    required WebPushRegistrationOutcome success,
    required String action,
  }) async {
    final headers = <String, String>{
      'authorization': 'Bearer $accessToken',
      'content-type': 'application/json',
      'accept': 'application/json',
    };
    try {
      final response = await http.Response.fromStream(
        await _client.send(request(headers)).timeout(_timeout),
      ).timeout(_timeout);
      final status = response.statusCode;
      if (status >= 200 && status < 300) return success;
      if (status == 401 || status == 403) {
        _logger.info('web push $action rejected by the relay: unauthorized');
        return WebPushRegistrationOutcome.unauthorized;
      }
      if (status == 404 || status == 405 || status == 501) {
        _logger.info('web push $action is not served by this deployment');
        return WebPushRegistrationOutcome.unavailable;
      }
      _logger.warning('web push $action failed with status $status');
      return WebPushRegistrationOutcome.failed;
    } on TimeoutException {
      _logger.warning('web push $action timed out');
      return WebPushRegistrationOutcome.failed;
    } catch (error) {
      _logger.warning('web push $action failed: ${error.runtimeType}');
      return WebPushRegistrationOutcome.failed;
    }
  }
}
