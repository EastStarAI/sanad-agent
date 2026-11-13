import 'dart:async';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_message.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_token.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_transport.dart';
import 'package:sanad_client/utils/app_platform.dart';

/// The Android and iOS implementation of the push wake-up channel.
///
/// The provider SDK lives in the platform project, not in this package: the
/// public dependency graph carries no push provider and no provider
/// configuration, and the relay owns the credentials. This class is the whole
/// contract between the two sides:
///
/// - an event stream of `message`, `interaction`, and `token` events;
/// - methods to start registration, read the current token, consume the launch
///   message, and publish the session that is on screen.
///
/// Every call is defensive: a build whose native side has not implemented the
/// channel reports "unsupported" instead of failing startup, which is what lets
/// desktop and web compose the same code.
class MethodChannelMobilePushTransport implements MobilePushTransport {
  MethodChannelMobilePushTransport({
    MethodChannel? methods,
    EventChannel? events,
  })  : _methods = methods ?? const MethodChannel(methodChannelName),
        _events = events ?? const EventChannel(eventChannelName) {
    if (AppPlatform.isMobile) _listen();
  }

  static const String methodChannelName = 'com.eaststarai.sanad/mobilePush';
  static const String eventChannelName = 'com.eaststarai.sanad/mobilePushEvents';

  /// Message types the native side may emit.
  static const String messageType = 'message';
  static const String interactionType = 'interaction';
  static const String tokenType = 'token';

  static final Logger _logger = Logger('notifications.push');

  final MethodChannel _methods;
  final EventChannel _events;

  final StreamController<MobilePushMessage> _displays = StreamController<MobilePushMessage>.broadcast();
  final StreamController<MobilePushMessage> _interactions = StreamController<MobilePushMessage>.broadcast();
  final StreamController<MobilePushToken> _tokenRefreshes = StreamController<MobilePushToken>.broadcast();

  StreamSubscription<dynamic>? _subscription;
  bool _nativeUnavailable = false;
  bool _disposed = false;

  /// A push provider is wired only when the app runs on a mobile platform and
  /// the native side answered the channel at least once.
  @override
  bool get isSupported => AppPlatform.isMobile && !_nativeUnavailable;

  @override
  Stream<MobilePushMessage> get displays => _displays.stream;

  @override
  Stream<MobilePushMessage> get interactions => _interactions.stream;

  @override
  Stream<MobilePushToken> get tokenRefreshes => _tokenRefreshes.stream;

  void _listen() {
    try {
      _subscription = _events.receiveBroadcastStream().listen(
            _onEvent,
            onError: (Object error) {
              // A platform without the channel is a supported configuration,
              // not a failure: it just has no wake-up path.
              _nativeUnavailable = true;
              _logger.info('mobile push channel is not available on ${AppPlatform.name}');
            },
            cancelOnError: false,
          );
    } on MissingPluginException {
      _nativeUnavailable = true;
    }
  }

  void _onEvent(dynamic raw) {
    if (_disposed || raw is! Map) return;
    final event = Map<String, Object?>.from(raw);
    final type = event['type']?.toString();
    switch (type) {
      case messageType:
        _emit(_displays, event);
      case interactionType:
        _emit(_interactions, event);
      case tokenType:
        final token = _readToken(event);
        if (token != null && !_tokenRefreshes.isClosed) _tokenRefreshes.add(token);
      default:
        // An event this build does not know is dropped; it must never become a
        // notification with a guessed identity.
        _logger.fine('dropped an unknown mobile push event');
    }
  }

  void _emit(StreamController<MobilePushMessage> sink, Map<String, Object?> event) {
    final message = MobilePushMessage.fromData(event);
    if (message.payload == null) {
      _logger.fine('dropped an unreadable mobile push message');
      return;
    }
    if (!sink.isClosed) sink.add(message);
  }

  @override
  Future<MobilePushMessage?> takeInitialMessage() async {
    if (!isSupported) return null;
    try {
      final raw = await _methods.invokeMethod<Object?>('takeInitialMessage');
      if (raw == null) return null;
      final message = MobilePushMessage.decode(raw);
      if (message == null || message.payload == null) {
        _logger.fine('dropped an unreadable launch notification');
        return null;
      }
      return message;
    } on PlatformException catch (error) {
      _nativeUnavailable = true;
      _logger.info('mobile push launch message unavailable: ${error.code}');
      return null;
    } on MissingPluginException {
      _nativeUnavailable = true;
      return null;
    }
  }

  @override
  Future<MobilePushToken?> currentToken() => _tokenFrom('currentToken');

  @override
  Future<void> ensureRegistration() async {
    if (!isSupported) return;
    try {
      await _methods.invokeMethod<void>('ensureRegistration');
    } on PlatformException catch (error) {
      _logger.info('mobile push registration could not start: ${error.code}');
    } on MissingPluginException {
      _nativeUnavailable = true;
    }
  }

  @override
  Future<void> reportVisibleSession(String? sessionId) async {
    if (!isSupported) return;
    try {
      await _methods.invokeMethod<void>('setVisibleSession', <String, Object?>{
        'session_id': sessionId,
      });
    } on PlatformException catch (error) {
      _logger.fine('could not publish the visible session: ${error.code}');
    } on MissingPluginException {
      _nativeUnavailable = true;
    }
  }

  Future<MobilePushToken?> _tokenFrom(String method) async {
    if (!isSupported) return null;
    try {
      final raw = await _methods.invokeMethod<Object?>(method);
      if (raw is! Map) return null;
      return _readToken(Map<String, Object?>.from(raw));
    } on PlatformException catch (error) {
      _logger.info('mobile push token unavailable: ${error.code}');
      return null;
    } on MissingPluginException {
      _nativeUnavailable = true;
      return null;
    }
  }

  MobilePushToken? _readToken(Map<String, Object?> raw) {
    final provider = MobilePushProvider.fromWire(raw['provider']);
    final value = raw['value']?.toString() ?? '';
    if (provider == null) return null;
    final token = MobilePushToken(value: value, provider: provider);
    return token.isValid ? token : null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription?.cancel();
    _subscription = null;
    await _displays.close();
    await _interactions.close();
    await _tokenRefreshes.close();
  }
}

MobilePushTransport createMobilePushTransport() => MethodChannelMobilePushTransport();
