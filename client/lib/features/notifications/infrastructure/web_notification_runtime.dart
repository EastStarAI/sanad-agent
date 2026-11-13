import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_capability.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_display_policy.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_subscription.dart';
import 'package:sanad_client/features/notifications/domain/services/web_push_client.dart';
import 'package:web/web.dart' as web;

/// The browser side of the notification pipeline, in one place.
///
/// It owns the service worker registration, the permission read and prompt, the
/// push subscription, the notification presentation, and the message channel the
/// worker uses to report wake-ups, clicks, and rotations. It holds no display
/// rule: the page's `NotificationService` decides what to show, and the worker
/// only renders a notification when no tab is visible to decide.
class WebNotificationRuntime {
  WebNotificationRuntime() {
    // A browser without Service Worker support keeps every other read working
    // (availability reports unsupported) instead of failing composition.
    if (_globalExists('serviceWorker')) {
      _container = web.window.navigator.serviceWorker;
      _messageListener = _onWorkerMessage.toJS;
      _container?.addEventListener('message', _messageListener!);
    }
  }

  static final Logger _logger = Logger('notifications.web');

  static const String _policyCacheName = 'sanad-web-push-v1';
  static const String _policyCacheKey = '/__sanad_web_push_policy';
  static const Duration _workerTimeout = Duration(seconds: 10);

  final StreamController<Map<String, dynamic>> _pushEnvelopes = StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<WebPushInteraction> _interactions = StreamController<WebPushInteraction>.broadcast();
  final StreamController<WebPushSubscription> _rotations = StreamController<WebPushSubscription>.broadcast();

  web.ServiceWorkerContainer? _container;
  JSFunction? _messageListener;

  Stream<Map<String, dynamic>> get pushEnvelopes => _pushEnvelopes.stream;
  Stream<WebPushInteraction> get interactions => _interactions.stream;
  Stream<WebPushSubscription> get rotations => _rotations.stream;

  /// Whether the browser exposes the Notifications API at all.
  bool get hasNotifications => _globalExists('Notification');

  /// Whether the browser exposes the Push API. An iOS Safari tab exposes
  /// neither, which is why the install path is detected before this is read.
  bool get hasPush => _container != null && _globalExists('PushManager') && _globalExists('Notification');

  bool get isIos {
    final ua = web.window.navigator.userAgent;
    if (RegExp(r'iPad|iPhone|iPod').hasMatch(ua)) return true;
    // iPadOS 13 and later report a desktop Macintosh user agent.
    return ua.contains('Macintosh') && web.window.navigator.maxTouchPoints > 1;
  }

  /// Whether this page runs as an installed home-screen app.
  bool get isStandalone {
    final installed = web.window.matchMedia('(display-mode: standalone)').matches;
    if (installed) return true;
    final legacy = (web.window.navigator as JSObject).getProperty<JSAny?>('standalone'.toJS)?.dartify();
    return legacy == true;
  }

  WebPushAvailability get availability {
    // iOS receives web push only in a home-screen app. Safari cannot be asked
    // for permission in a tab, so the requirement is stated, not hidden.
    if (isIos && !isStandalone) return WebPushAvailability.installRequired;
    if (!hasNotifications || !hasPush) return WebPushAvailability.unsupported;
    return WebPushAvailability.ready;
  }

  Future<NotificationPermissionStatus> checkPermission() async {
    if (!hasNotifications) return NotificationPermissionStatus.unsupported;
    return _permissionFromWire(web.Notification.permission);
  }

  Future<NotificationPermissionStatus> requestPermission() async {
    if (!hasNotifications) return NotificationPermissionStatus.unsupported;
    final result = await web.Notification.requestPermission().toDart;
    return _permissionFromWire(result);
  }

  /// Registers the owned worker and waits for it to activate.
  Future<web.ServiceWorkerRegistration> register() async {
    final container = _container;
    if (container == null) {
      throw StateError('This browser has no Service Worker support.');
    }
    final base = Uri.parse(web.window.location.href);
    final scope = base.path.endsWith('/') ? base.path : '${base.path}/';
    final scriptUrl = base.resolve('sw.js').toString();
    try {
      await container.register(scriptUrl.toJS, web.RegistrationOptions(scope: scope)).toDart.timeout(_workerTimeout);
      return await container.ready.toDart.timeout(_workerTimeout);
    } on TimeoutException {
      _logger.warning('the Sanad service worker did not activate in time');
      rethrow;
    }
  }

  Future<web.ServiceWorkerRegistration?> activeRegistration() async {
    final container = _container;
    if (container == null) return null;
    try {
      final registration = await container.getRegistration(web.window.location.href).toDart.timeout(_workerTimeout);
      if (registration != null) return registration;
    } catch (error) {
      _logger.fine('could not read the worker registration: ${error.runtimeType}');
    }
    try {
      return await register();
    } catch (error) {
      _logger.warning('the Sanad service worker is unavailable: ${error.runtimeType}');
      return null;
    }
  }

  Future<WebPushSubscription?> currentSubscription() async {
    final registration = await activeRegistration();
    if (registration == null) return null;
    try {
      final subscription = await registration.pushManager.getSubscription().toDart;
      return subscription == null ? null : _serialize(subscription);
    } catch (error) {
      _logger.fine('could not read the push subscription: ${error.runtimeType}');
      return null;
    }
  }

  Future<WebPushSubscription?> subscribe({required String applicationServerKey}) async {
    final registration = await activeRegistration();
    if (registration == null) return null;
    final key = _decodeBase64Url(applicationServerKey);
    if (key == null) {
      _logger.warning('the configured VAPID public key is not valid base64url');
      return null;
    }
    final subscription = await registration.pushManager
        .subscribe(
          web.PushSubscriptionOptionsInit(
            userVisibleOnly: true,
            applicationServerKey: key.toJS,
          ),
        )
        .toDart;
    return _serialize(subscription);
  }

  Future<void> unsubscribe() async {
    final registration = await activeRegistration();
    if (registration == null) return;
    final subscription = await registration.pushManager.getSubscription().toDart;
    if (subscription == null) return;
    await subscription.unsubscribe().toDart;
  }

  /// Presents a page-decided notification through the owned worker.
  ///
  /// The worker is the presenter for both raisers so one collapse identity and
  /// one click path exist; the tag is the same numeric identity the worker
  /// derives from the canonical collapse key.
  Future<void> show({
    required int notificationId,
    required String title,
    required String body,
    required String presentationPayload,
  }) async {
    final registration = await activeRegistration();
    if (registration == null) {
      throw StateError('The Sanad service worker is not active.');
    }
    final options = web.NotificationOptions(
      body: body,
      tag: notificationId.toString(),
      renotify: false,
      requireInteraction: false,
      data: <String, dynamic>{'sanad': 1, 'payload': presentationPayload}.jsify(),
    );
    await registration.showNotification(title, options).toDart;
  }

  Future<bool> cancel(int notificationId) async {
    final registration = await activeRegistration();
    if (registration == null) return false;
    final notifications = await registration
        .getNotifications(web.GetNotificationOptions(tag: notificationId.toString()))
        .toDart;
    for (final notification in notifications.toDart) {
      notification.close();
    }
    return true;
  }

  /// Publishes the user's display policy where a worker with no page can read
  /// it. The Cache API is shared by the page and the worker, unlike
  /// `localStorage`, which does not exist in a worker.
  Future<void> publishDisplayPolicy(WebPushDisplayPolicy policy) async {
    final cache = await web.window.caches.open(_policyCacheName).toDart;
    final body = jsonEncode(policy.toJson());
    await cache
        .put(
          _policyCacheKey.toJS,
          web.Response(body.toJS, web.ResponseInit()),
        )
        .toDart;
  }

  /// Reads and clears the query a notification click opened the app with.
  ///
  /// The query is consumed rather than kept so a reload never re-opens the same
  /// session, and an action is never replayed from a URL.
  Map<String, String>? takePendingOpen() {
    final params = Uri.base.queryParameters;
    final sessionId = params['sanad_session_id']?.trim();
    if (sessionId == null || sessionId.isEmpty) return null;
    final requestId = params['sanad_request_id']?.trim();
    final remaining = Map<String, String>.from(params)
      ..remove('sanad_session_id')
      ..remove('sanad_request_id');
    final cleaned = remaining.isEmpty ? Uri.base.replace(query: '') : Uri.base.replace(queryParameters: remaining);
    try {
      web.window.history.replaceState(null, '', cleaned.toString());
    } catch (error) {
      _logger.fine('could not clear the notification query: ${error.runtimeType}');
    }
    return <String, String>{
      'session_id': sessionId,
      if (requestId != null && requestId.isNotEmpty) 'request_id': requestId,
    };
  }

  Future<void> dispose() async {
    final listener = _messageListener;
    if (listener != null) {
      _container?.removeEventListener('message', listener);
    }
    await _pushEnvelopes.close();
    await _interactions.close();
    await _rotations.close();
  }

  void _onWorkerMessage(web.MessageEvent event) {
    final raw = event.data?.dartify();
    if (raw is! Map) return;
    final data = Map<String, dynamic>.from(raw);
    switch (data['type']) {
      case 'sanad.push':
        final envelope = _asMap(data['envelope']);
        if (envelope != null) _pushEnvelopes.add(envelope);
      case 'sanad.notification-click':
        final interaction = WebPushInteraction(
          envelope: _asMap(data['envelope']),
          presented: _asMap(data['payload']),
          actionId: data['action'] is String ? data['action'] as String : null,
        );
        if (!interaction.isEmpty) _interactions.add(interaction);
      case 'sanad.subscription-changed':
        final subscription = WebPushSubscription.fromMessage(data['subscription']);
        if (subscription != null) _rotations.add(subscription);
    }
  }

  static Map<String, dynamic>? _asMap(Object? raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } on FormatException {
        return null;
      }
    }
    return null;
  }

  static NotificationPermissionStatus _permissionFromWire(Object? value) {
    return switch (value) {
      'granted' => NotificationPermissionStatus.granted,
      'denied' => NotificationPermissionStatus.denied,
      'default' => NotificationPermissionStatus.unknown,
      _ => NotificationPermissionStatus.unavailable,
    };
  }

  static WebPushSubscription? _serialize(web.PushSubscription subscription) {
    String? p256dh;
    String? auth;
    try {
      final keys = subscription.toJSON().keys;
      p256dh = keys.getProperty<JSString?>('p256dh'.toJS)?.toDart;
      auth = keys.getProperty<JSString?>('auth'.toJS)?.toDart;
    } catch (error) {
      _logger.fine('could not read the serialized push keys: ${error.runtimeType}');
    }
    p256dh ??= _base64UrlOf(subscription.getKey('p256dh'));
    auth ??= _base64UrlOf(subscription.getKey('auth'));
    final endpoint = subscription.endpoint.trim();
    if (endpoint.isEmpty || p256dh == null || auth == null) return null;
    return WebPushSubscription(endpoint: endpoint, p256dh: p256dh, auth: auth);
  }

  static String? _base64UrlOf(JSArrayBuffer? buffer) {
    if (buffer == null) return null;
    final bytes = buffer.toDart.asUint8List();
    if (bytes.isEmpty) return null;
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Decodes the application server key exactly as the Push API expects:
  /// unpadded base64url to bytes.
  static Uint8List? _decodeBase64Url(String value) {
    final normalized = value.trim().replaceAll('-', '+').replaceAll('_', '/');
    final padded = normalized.padRight((normalized.length + 3) ~/ 4 * 4, '=');
    try {
      return base64Decode(padded);
    } on FormatException {
      return null;
    }
  }

  static bool _globalExists(String name) {
    try {
      return (web.window as JSObject).getProperty<JSAny?>(name.toJS) != null;
    } catch (_) {
      return false;
    }
  }
}
