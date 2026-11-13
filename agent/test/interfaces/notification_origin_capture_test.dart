// Plan 174 — where the originating Client instance is resolved.
//
// The notification policy can only name an origin target when the delivery
// envelope proves one. Two shapes exist: the Gateway-authored `origin_client`
// block on the cloud route, and the instance id a local adapter stamps from the
// socket's authenticated `client.hello`. Everything else resolves to null,
// which the policy escalates immediately.

import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/interfaces/gateway_manager.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:test/test.dart';

const _instance = '11111111-1111-4111-8111-111111111111';

GatewayEvent _event(Map<String, dynamic> metadata) => GatewayEvent(
  sessionId: 'session-1',
  platformId: 'local_gateway',
  message: Message(role: MessageRole.user, content: 'run'),
  metadata: metadata,
);

void main() {
  final manager = GatewayManager();

  test('a cloud origin_client block names the instance', () {
    expect(
      manager.clientInstanceIdFor(
        _event({
          'command': 'think',
          'origin_client': {
            'version': 1,
            'client_instance_id': _instance.toUpperCase(),
            'client_kind': 'mobile',
            'platform_family': 'ios',
          },
        }),
      ),
      _instance,
    );
  });

  test('a local hello-bound instance id names the instance', () {
    expect(
      manager.clientInstanceIdFor(_event({'client_instance_id': _instance})),
      _instance,
    );
  });

  test('an unprovable identity resolves to null', () {
    expect(manager.clientInstanceIdFor(_event(const {})), isNull);
    expect(
      manager.clientInstanceIdFor(
        _event({'client_instance_id': 'device-or-sid-substitution'}),
      ),
      isNull,
    );
    expect(
      manager.clientInstanceIdFor(
        _event({
          'origin_client': {'version': 1, 'client_instance_id': 'not-a-uuid'},
        }),
      ),
      isNull,
    );
  });
}
