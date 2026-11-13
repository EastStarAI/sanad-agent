import 'dart:async';

import 'package:sanad_client/features/notifications/domain/models/mobile_push_message.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_token.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_transport.dart';

/// A total no-op for targets with no push provider.
///
/// Reporting [isSupported] as `false` is what keeps the rest of the feature
/// honest: nothing registers a token, nothing listens for a wake-up, and the
/// in-app pipeline keeps working exactly as it does on a desktop.
class UnsupportedMobilePushTransport implements MobilePushTransport {
  const UnsupportedMobilePushTransport();

  @override
  bool get isSupported => false;

  @override
  Stream<MobilePushMessage> get displays => const Stream<MobilePushMessage>.empty();

  @override
  Stream<MobilePushMessage> get interactions => const Stream<MobilePushMessage>.empty();

  @override
  Stream<MobilePushToken> get tokenRefreshes => const Stream<MobilePushToken>.empty();

  @override
  Future<MobilePushMessage?> takeInitialMessage() async => null;

  @override
  Future<MobilePushToken?> currentToken() async => null;

  @override
  Future<void> ensureRegistration() async {}

  @override
  Future<void> reportVisibleSession(String? sessionId) async {}

  @override
  Future<void> dispose() async {}
}

MobilePushTransport createMobilePushTransport() => const UnsupportedMobilePushTransport();
