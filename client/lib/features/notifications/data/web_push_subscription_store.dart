import 'package:equatable/equatable.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The locally remembered fact that this browser's endpoint belongs to an
/// account.
///
/// The endpoint itself is the capability; it is stored so a logout can revoke
/// it after the account tokens are already gone, and so a different account on
/// the same browser re-registers instead of inheriting the previous one.
class WebPushSubscriptionRecord extends Equatable {
  const WebPushSubscriptionRecord({
    required this.endpoint,
    required this.accountId,
    required this.clientInstanceId,
  });

  final String endpoint;
  final String? accountId;
  final String clientInstanceId;

  bool belongsTo({required String? accountId, required String clientInstanceId}) =>
      this.accountId == accountId && this.clientInstanceId == clientInstanceId;

  @override
  List<Object?> get props => [endpoint, accountId, clientInstanceId];
}

/// Persists the smallest state logout and account switching need.
///
/// No token, key, or credential is stored: the endpoint is the only identity,
/// and the relay holds the keys.
class WebPushSubscriptionStore {
  WebPushSubscriptionStore(this._preferences);

  static const String endpointKey = 'web_push_subscription_endpoint_v1';
  static const String accountKey = 'web_push_subscription_account_v1';
  static const String clientInstanceKey = 'web_push_subscription_client_instance_v1';

  final SharedPreferences _preferences;

  WebPushSubscriptionRecord? read() {
    final endpoint = _preferences.getString(endpointKey)?.trim();
    final clientInstanceId = _preferences.getString(clientInstanceKey)?.trim();
    if (endpoint == null || endpoint.isEmpty || clientInstanceId == null || clientInstanceId.isEmpty) {
      return null;
    }
    final accountId = _preferences.getString(accountKey)?.trim();
    return WebPushSubscriptionRecord(
      endpoint: endpoint,
      accountId: accountId == null || accountId.isEmpty ? null : accountId,
      clientInstanceId: clientInstanceId,
    );
  }

  Future<void> write(WebPushSubscriptionRecord record) async {
    await _preferences.setString(endpointKey, record.endpoint);
    await _preferences.setString(clientInstanceKey, record.clientInstanceId);
    final accountId = record.accountId;
    if (accountId == null || accountId.isEmpty) {
      await _preferences.remove(accountKey);
    } else {
      await _preferences.setString(accountKey, accountId);
    }
  }

  Future<void> clear() async {
    await _preferences.remove(endpointKey);
    await _preferences.remove(accountKey);
    await _preferences.remove(clientInstanceKey);
  }
}
