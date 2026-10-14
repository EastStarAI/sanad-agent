import 'package:get_it/get_it.dart';
import 'package:sanad_agent/core/appearance/appearance_store.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/appearance_command_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:test/test.dart';

import '../../../../support/isolated_sanad_test_home.dart';

class _FakeAuthManager implements AuthManager {
  @override
  String? get hardwareId => 'test-hardware-id';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  useIsolatedSanadTestHome();

  late AppearanceStore store;
  late SanadProtocolBridge bridge;
  late AppearanceCommandHandler handler;

  setUp(() {
    GetIt.instance.registerSingleton<AuthManager>(_FakeAuthManager());
    store = const AppearanceStore();
    bridge = SanadProtocolBridge();
    handler = AppearanceCommandHandler(store: store, bridge: bridge);
  });

  group('AppearanceCommandHandler', () {
    test('buildSnapshotEnvelope returns default appearance when empty', () async {
      final envelope = await handler.buildSnapshotEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.getAppearance,
          payload: {'request_id': 'req-123'},
        ),
      );

      expect(envelope['type'], 'event');
      expect(envelope['event'], CanonicalEventTypes.appearanceSnapshot);
      expect(envelope['request_id'], 'req-123');
      final payload = envelope['payload'] as Map<String, dynamic>;
      expect(payload['theme_style'], 'dark');
      expect(payload['primary_color'], 'blue');
      expect(payload['font_family'], 'system');
      expect(payload['font_size'], 'normal');
      expect(payload['background_option'], 'defaultTheme');
    });

    test('buildUpdateEnvelope writes appearance and returns updated snapshot', () async {
      final envelope = await handler.buildUpdateEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.updateAppearance,
          payload: {
            'request_id': 'req-456',
            'appearance': {
              'theme_style': 'midnight',
              'primary_color': 'teal',
              'font_family': 'cairo',
            },
          },
        ),
      );

      expect(envelope['type'], 'event');
      expect(envelope['event'], CanonicalEventTypes.appearanceUpdated);
      expect(envelope['request_id'], 'req-456');
      final payload = envelope['payload'] as Map<String, dynamic>;
      expect(payload['theme_style'], 'midnight');
      expect(payload['primary_color'], 'teal');
      expect(payload['font_family'], 'cairo');

      // Verify bridge dispatching via handleCommand
      final emitted = <Map<String, dynamic>>[];
      final handled = await bridge.handleCommand({
        'command': CanonicalEventTypes.getAppearance,
        'payload': {'request_id': 'req-789'},
      }, (env) async => emitted.add(env));

      expect(handled, isTrue);
      expect(emitted, hasLength(1));
      expect(emitted.first['event'], CanonicalEventTypes.appearanceSnapshot);
      final snapshotPayload = emitted.first['payload'] as Map<String, dynamic>;
      expect(snapshotPayload['primary_color'], 'teal');
      expect(snapshotPayload['theme_style'], 'midnight');
    });
  });
}
