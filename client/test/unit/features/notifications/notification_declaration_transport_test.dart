// Plan 174f — how this device's notification choices reach the Agent.
//
// The declaration rides the Client's own authenticated registration envelope,
// the same one that carries identity, platform family, and locale. These tests
// pin the envelope shape so the Agent-side parser and the Client-side writer
// cannot drift, and they pin that the payload carries no choice the relay would
// have to read.

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/auth/domain/client_instance_identity.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_preferences.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_urgency.dart';
import 'package:sanad_client/infrastructure/socket/socket_connection_controller.dart';

const String _instanceId = '3b0f3a52-5c6f-4a1c-8c14-2f2f0e6f9a10';

SocketConnectionController _controller({
  Map<String, dynamic>? Function()? declaration,
}) {
  return SocketConnectionController.local(
    url: 'ws://127.0.0.1:58085/ws',
    hardwareId: 'hw-1',
    clientInstanceId: _instanceId,
    clientMetadata: const ClientDisplayMetadata(
      clientKind: 'desktop',
      platformFamily: 'macos',
      osFamily: 'macos',
      appVersion: '1.0.0',
    ),
    notificationDeclaration: declaration,
  );
}

void main() {
  test('the registration envelope carries this device declaration', () {
    final preferences = const NotificationPreferences()
        .withKind(NotificationKind.failed, false)
        .withKindUrgency(NotificationKind.completed, NotificationUrgency.normal);

    final envelope = _controller(
      declaration: preferences.toAgentDeclaration,
    ).localHelloEnvelope();

    expect(envelope, isNotNull);
    expect(envelope!['type'], 'client.hello');
    expect(envelope['protocol'], 'sanad.identity_presence');
    expect(envelope['client_instance_id'], _instanceId);
    expect(envelope['notifications'], <String, dynamic>{
      'enabled': true,
      'kinds': <String, String>{'failed': 'off', 'completed': 'normal'},
    });
  });

  test('an untouched device registers the product default', () {
    final envelope = _controller(
      declaration: const NotificationPreferences().toAgentDeclaration,
    ).localHelloEnvelope();

    expect(envelope!['notifications'], <String, dynamic>{
      'enabled': true,
      'kinds': <String, String>{},
    });
  });

  test('a Client with no declaration omits the field rather than inventing one', () {
    final envelope = _controller().localHelloEnvelope();

    expect(envelope, isNotNull);
    expect(envelope!.containsKey('notifications'), isFalse);
  });

  test('a Client with no instance identity registers nothing', () {
    final controller = SocketConnectionController.local(
      url: 'ws://127.0.0.1:58085/ws',
      hardwareId: 'hw-1',
      notificationDeclaration: const NotificationPreferences().toAgentDeclaration,
    );

    expect(controller.localHelloEnvelope(), isNull);
  });

  test('the declaration is read at registration time, not captured at boot', () {
    var preferences = const NotificationPreferences();
    final controller = _controller(declaration: () => preferences.toAgentDeclaration());

    expect(controller.localHelloEnvelope()!['notifications'], <String, dynamic>{
      'enabled': true,
      'kinds': <String, String>{},
    });

    preferences = preferences.withKind(NotificationKind.blocked, false);

    expect(controller.localHelloEnvelope()!['notifications'], <String, dynamic>{
      'enabled': true,
      'kinds': <String, String>{'blocked': 'off'},
    });
  });

  test('publishing while disconnected sends nothing and throws nothing', () {
    final controller = _controller(
      declaration: const NotificationPreferences().toAgentDeclaration,
    );

    expect(controller.publishNotificationPreferences, returnsNormally);
  });
}
