import 'dart:async';

import 'package:logging/logging.dart';
import 'package:sanad_client/features/notifications/data/web_push_subscription_store.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_capability.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_display_policy.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_subscription.dart';
import 'package:sanad_client/features/notifications/domain/repositories/web_push_subscription_registrar.dart';
import 'package:sanad_client/features/notifications/domain/services/web_push_client.dart';

/// The single owner of the browser push subscription lifecycle.
///
/// Three laws hold here, and nothing above this class repeats them:
/// - Permission is requested only from [enable], which only an explicit user
///   action calls. Startup calls [synchronize], which never prompts.
/// - A subscription belongs to an authenticated account. [enable] refuses
///   without an access token, [synchronize] repairs the registration for the
///   current account, and [revokeForLogout] revokes before the tokens are gone.
/// - A delivery failure never removes a working browser permission: the local
///   subscription stays and [WebPushSettings.failure] states what happened.
/// - The reported status is the relay's acknowledgement, never the browser
///   subscription alone. The relay resolves the account's endpoints, so an
///   endpoint it did not accept delivers nothing; claiming `subscribed` from
///   `pushManager.getSubscription()` would report a pipeline that does not
///   exist. The acknowledgement record is the persisted subscription record,
///   which is written only after the relay answers.
class WebPushSubscriptionService {
  WebPushSubscriptionService({
    required WebPushClient client,
    required WebPushSubscriptionRegistrar registrar,
    required WebPushSubscriptionStore store,
    required String? Function() readAccessToken,
    required String? Function() readAccountId,
    required String Function() readClientInstanceId,
    required String? Function() readVapidPublicKey,
    DateTime Function()? clock,
  }) : _client = client,
       _registrar = registrar,
       _store = store,
       _readAccessToken = readAccessToken,
       _readAccountId = readAccountId,
       _readClientInstanceId = readClientInstanceId,
       _readVapidPublicKey = readVapidPublicKey,
       _clock = clock ?? DateTime.now,
       _settings = WebPushSettings(
         isWebPlatform: client.isWebPlatform,
         availability: client.availability,
       );

  final WebPushClient _client;
  final WebPushSubscriptionRegistrar _registrar;
  final WebPushSubscriptionStore _store;
  final String? Function() _readAccessToken;
  final String? Function() _readAccountId;
  final String Function() _readClientInstanceId;
  final String? Function() _readVapidPublicKey;
  final DateTime Function() _clock;

  final StreamController<WebPushSettings> _changes = StreamController<WebPushSettings>.broadcast();

  WebPushSettings _settings;
  bool _disposed = false;

  static final Logger _logger = Logger('notifications.web_push');

  WebPushSettings get settings => _settings;

  /// Emits on every state change so Settings re-renders without polling.
  Stream<WebPushSettings> get changes => _changes.stream;

  /// Whether this build can deliver a web notification at all right now.
  bool get isAvailable => _client.isWebPlatform && _settings.availability.canSubscribe;

  /// Wake-ups the worker forwarded because a visible tab decides for itself.
  Stream<Map<String, dynamic>> get pushEnvelopes => _client.pushEnvelopes;

  /// Clicks and action presses the worker reported.
  Stream<WebPushInteraction> get interactions => _client.interactions;

  /// Endpoint rotations the worker reported.
  Stream<WebPushSubscription> get rotations => _client.rotatedSubscriptions;

  /// Re-reads availability, the browser subscription, and the relay
  /// acknowledgement. Never prompts.
  ///
  /// A browser subscription the relay never acknowledged reports
  /// [WebPushFailure.registrationFailed] here, so reopening Settings cannot turn
  /// a refused registration into a working one.
  Future<WebPushSettings> refresh() async {
    if (!_client.isWebPlatform) return _emit(const WebPushSettings());
    WebPushSubscription? subscription;
    try {
      subscription = await _client.currentSubscription();
    } catch (error) {
      _logger.fine('could not read the browser push subscription: ${error.runtimeType}');
    }
    return _emit(
      _withDeliveryState(
        _settings.copyWith(availability: _effectiveAvailability()),
        subscription,
      ),
    );
  }

  /// Asks the browser and the relay, from an explicit user action only.
  ///
  /// The order matters: permission first, because a subscription cannot exist
  /// without it; the relay last, because a registration without a browser
  /// subscription is a delivery claim the Client cannot honour.
  Future<WebPushSettings> enable() async {
    if (_disposed) return _settings;
    final availability = _effectiveAvailability();
    if (!_client.isWebPlatform || !availability.canSubscribe) {
      return _emit(_settings.copyWith(availability: availability));
    }

    final accessToken = _readAccessToken();
    if (accessToken == null || accessToken.isEmpty) {
      _logger.info('web push enable refused: no authenticated account session');
      return _emit(
        _settings.copyWith(
          availability: availability,
          status: WebPushSubscriptionStatus.notSubscribed,
          failure: WebPushFailure.signInRequired,
        ),
      );
    }

    NotificationPermissionStatus permission;
    try {
      permission = await _client.checkPermission();
    } catch (error) {
      _logger.fine('could not read the browser permission: ${error.runtimeType}');
      permission = NotificationPermissionStatus.unknown;
    }
    if (permission == NotificationPermissionStatus.unknown) {
      try {
        permission = await _client.requestPermission();
      } catch (error) {
        _logger.warning('web push permission request failed: ${error.runtimeType}');
        permission = NotificationPermissionStatus.denied;
      }
    }
    if (!permission.canDisplay) {
      return _emit(
        _settings.copyWith(
          availability: availability,
          status: WebPushSubscriptionStatus.notSubscribed,
          failure: WebPushFailure.permissionDenied,
        ),
      );
    }

    _emit(
      _settings.copyWith(
        availability: availability,
        status: WebPushSubscriptionStatus.subscribing,
        failure: WebPushFailure.none,
      ),
    );

    final subscription = await _subscribe(accessToken);
    if (subscription == null) {
      return _emit(
        _settings.copyWith(
          status: WebPushSubscriptionStatus.notSubscribed,
          failure: WebPushFailure.registrationFailed,
        ),
      );
    }
    return _emit(_withDeliveryState(_settings, subscription));
  }

  /// Withdraws this browser from the account and drops the subscription.
  Future<WebPushSettings> disable() async {
    if (_disposed || !_client.isWebPlatform) return _settings;
    await _revokeAndUnsubscribe(_readAccessToken());
    return _emit(
      _settings.copyWith(
        status: WebPushSubscriptionStatus.notSubscribed,
        failure: WebPushFailure.none,
      ),
    );
  }

  /// Registers an existing subscription for the signed-in account. Never
  /// prompts, so it is safe on startup and after a reconnect.
  Future<WebPushSettings> synchronize() async {
    if (_disposed || !_client.isWebPlatform) return _settings;
    final settings = await refresh();
    if (!settings.availability.canSubscribe) return settings;

    final accessToken = _readAccessToken();
    WebPushSubscription? subscription;
    try {
      subscription = await _client.currentSubscription();
    } catch (error) {
      _logger.fine('could not read the browser push subscription: ${error.runtimeType}');
      return settings;
    }

    if (accessToken == null || accessToken.isEmpty) {
      // A browser that is signed out must not keep a subscription the previous
      // account could still be delivered to.
      if (subscription != null || _store.read() != null) {
        await _client.unsubscribe();
        await _store.clear();
      }
      return _emit(
        settings.copyWith(
          status: WebPushSubscriptionStatus.notSubscribed,
          failure: WebPushFailure.signInRequired,
        ),
      );
    }

    if (subscription == null) {
      if (_store.read() != null) await _store.clear();
      return _emit(
        settings.copyWith(status: WebPushSubscriptionStatus.notSubscribed),
      );
    }

    final accountId = _readAccountId();
    final clientInstanceId = _readClientInstanceId();
    final stored = _store.read();
    if (stored != null &&
        stored.endpoint == subscription.endpoint &&
        stored.belongsTo(accountId: accountId, clientInstanceId: clientInstanceId)) {
      return settings;
    }

    await _register(subscription, accessToken, accountId);
    return _emit(_withDeliveryState(settings, subscription));
  }

  /// Re-registers an endpoint the worker rotated.
  Future<void> onSubscriptionRotated(WebPushSubscription subscription) async {
    if (_disposed) return;
    final accessToken = _readAccessToken();
    if (accessToken == null || accessToken.isEmpty) {
      _logger.info('web push rotation deferred: no authenticated account session');
      return;
    }
    await _register(subscription, accessToken, _readAccountId());
    _emit(_withDeliveryState(_settings, subscription));
  }

  /// Revokes before the account tokens are cleared. Called on logout only.
  ///
  /// [accessToken] is the token captured while the session was still valid,
  /// because the Client clears its credentials before the logout is observable.
  Future<void> revokeForLogout({String? accessToken}) async {
    if (_disposed || !_client.isWebPlatform) return;
    await _revokeAndUnsubscribe(accessToken ?? _readAccessToken());
    _emit(
      _settings.copyWith(
        status: WebPushSubscriptionStatus.notSubscribed,
        failure: WebPushFailure.none,
      ),
    );
  }

  /// Mirrors the user's display policy for the closed-tab path.
  Future<void> publishDisplayPolicy(WebPushDisplayPolicy policy) async {
    if (_disposed || !_client.isWebPlatform) return;
    try {
      await _client.publishDisplayPolicy(policy);
    } catch (error) {
      _logger.fine('could not publish the web push display policy: ${error.runtimeType}');
    }
  }

  /// Consumes a launch URL a notification click produced.
  Map<String, String>? takePendingOpen() => _client.takePendingOpen();

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _changes.close();
  }

  /// Creates or reuses the browser subscription and asks the relay to accept
  /// it.
  ///
  /// Returns the browser subscription even when the relay refused it: the
  /// subscription survives a relay failure so a later attempt registers it
  /// without asking for permission again, and [_withDeliveryState] reports the
  /// refusal from the acknowledgement record instead of from this result.
  Future<WebPushSubscription?> _subscribe(String accessToken) async {
    final vapidPublicKey = _readVapidPublicKey();
    if (vapidPublicKey == null || vapidPublicKey.isEmpty) {
      _logger.warning('web push enable refused: this build has no VAPID public key');
      return null;
    }

    try {
      await _client.ensureServiceWorker();
    } catch (error) {
      _logger.warning('web push worker registration failed: ${error.runtimeType}');
      return null;
    }

    WebPushSubscription? subscription;
    try {
      subscription = await _client.currentSubscription();
    } catch (error) {
      _logger.fine('could not read the browser push subscription: ${error.runtimeType}');
    }
    subscription ??= await _subscribeNew(vapidPublicKey);
    if (subscription == null) return null;

    await _register(subscription, accessToken, _readAccountId());
    return subscription;
  }

  Future<WebPushSubscription?> _subscribeNew(String vapidPublicKey) async {
    try {
      final subscription = await _client.subscribe(applicationServerKey: vapidPublicKey);
      if (subscription == null) {
        _logger.warning('the browser did not create a push subscription');
      }
      return subscription;
    } catch (error) {
      _logger.warning('the browser rejected the push subscription: ${error.runtimeType}');
      return null;
    }
  }

  /// Asks the relay to accept [subscription] and, on an acknowledgement, records
  /// it as the delivery state.
  ///
  /// The store write is the acknowledgement: every reported status is projected
  /// from it, so a refused or unreachable relay leaves no record and therefore
  /// no claim of delivery.
  Future<void> _register(
    WebPushSubscription subscription,
    String accessToken,
    String? accountId,
  ) async {
    final clientInstanceId = _readClientInstanceId();
    WebPushRegistrationOutcome outcome;
    try {
      outcome = await _registrar.register(
        subscription,
        accessToken: accessToken,
        clientInstanceId: clientInstanceId,
        createdAt: _clock(),
      );
    } catch (error) {
      _logger.warning('web push registration failed: ${error.runtimeType}');
      return;
    }
    if (outcome != WebPushRegistrationOutcome.registered) {
      _logger.info('web push registration not acknowledged: ${outcome.name}');
      return;
    }
    await _store.write(
      WebPushSubscriptionRecord(
        endpoint: subscription.endpoint,
        accountId: accountId,
        clientInstanceId: clientInstanceId,
      ),
    );
  }

  Future<void> _revokeAndUnsubscribe(String? accessToken) async {
    final stored = _store.read();
    String? endpoint = stored?.endpoint;
    WebPushSubscription? subscription;
    try {
      subscription = await _client.currentSubscription();
    } catch (error) {
      _logger.fine('could not read the browser push subscription: ${error.runtimeType}');
    }
    endpoint ??= subscription?.endpoint;
    if (endpoint != null && accessToken != null && accessToken.isNotEmpty) {
      try {
        final outcome = await _registrar.revoke(endpoint, accessToken: accessToken);
        if (outcome != WebPushRegistrationOutcome.revoked) {
          _logger.info('web push revoke did not complete: ${outcome.name}');
        }
      } catch (error) {
        _logger.warning('web push revoke failed: ${error.runtimeType}');
      }
    }
    try {
      await _client.unsubscribe();
    } catch (error) {
      _logger.fine('could not unsubscribe the browser: ${error.runtimeType}');
    }
    await _store.clear();
  }

  /// Projects the Settings state from the relay acknowledgement.
  ///
  /// The browser subscription alone is not delivery: only the relay can reach
  /// this endpoint, so a subscription it never acknowledged is reported as
  /// [WebPushFailure.registrationFailed] with [WebPushSubscriptionStatus.notSubscribed]
  /// — the failure state that offers the retry — instead of a working pipeline.
  /// A later successful registration writes the record and clears it.
  WebPushSettings _withDeliveryState(WebPushSettings settings, WebPushSubscription? subscription) {
    if (!_hasAccountSession) {
      return settings.copyWith(
        status: WebPushSubscriptionStatus.notSubscribed,
        failure: WebPushFailure.signInRequired,
      );
    }
    if (subscription == null) {
      return settings.copyWith(
        status: WebPushSubscriptionStatus.notSubscribed,
        failure: WebPushFailure.none,
      );
    }
    if (_isAcknowledged(subscription)) {
      return settings.copyWith(
        status: WebPushSubscriptionStatus.subscribed,
        failure: WebPushFailure.none,
      );
    }
    return settings.copyWith(
      status: WebPushSubscriptionStatus.notSubscribed,
      failure: WebPushFailure.registrationFailed,
    );
  }

  /// Whether the relay accepted this exact endpoint for this account and Client
  /// instance.
  ///
  /// The store is written only after an acknowledgement, so the record is the
  /// acknowledgement. A record for another account is not this browser's
  /// delivery: the next synchronization re-registers the endpoint instead of
  /// inheriting the previous account's claim.
  bool _isAcknowledged(WebPushSubscription subscription) {
    final stored = _store.read();
    return stored != null &&
        stored.endpoint == subscription.endpoint &&
        stored.belongsTo(
          accountId: _readAccountId(),
          clientInstanceId: _readClientInstanceId(),
        );
  }

  bool get _hasAccountSession {
    final token = _readAccessToken();
    return token != null && token.isNotEmpty;
  }

  WebPushAvailability _effectiveAvailability() {
    final availability = _client.availability;
    if (availability != WebPushAvailability.ready) return availability;
    final key = _readVapidPublicKey();
    return key == null || key.isEmpty ? WebPushAvailability.unconfigured : WebPushAvailability.ready;
  }

  WebPushSettings _emit(WebPushSettings settings) {
    _settings = settings;
    if (!_changes.isClosed) _changes.add(settings);
    return settings;
  }
}
