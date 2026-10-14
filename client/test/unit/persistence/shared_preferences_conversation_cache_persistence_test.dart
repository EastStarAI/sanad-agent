import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/data/persistence/shared_preferences_conversation_cache_persistence.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_draft.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_cache_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_context.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('save and load round-trip through the platform backend', () async {
    final persistence = SharedPreferencesConversationCachePersistence(
      await SharedPreferences.getInstance(),
    );
    final snapshot = DeviceConversationCacheSnapshot(
      activeDeviceId: 'device-1',
      contexts: {'device-1': DeviceConversationContext.empty()},
      sessionDrafts: {
        DeviceConversationCacheSnapshot.sessionDraftKey(
          'device-1',
          's-1',
        ): ConversationDraft(
          text: 'persisted',
          workspaceId: null,
          providerId: null,
          model: null,
          thinkingMode: null,
          permissionMode: null,
          updatedAt: DateTime.utc(2026, 7, 13),
        ),
      },
      sessionViewportAnchors: const {'device-1|s-1': 'message-1'},
    );

    await persistence.save(snapshot);
    final restored = await persistence.load();

    expect(restored.activeDeviceId, 'device-1');
    expect(restored.contexts, contains('device-1'));
    expect(restored.sessionDrafts.values.single.text, 'persisted');
    expect(restored.sessionViewportAnchors['device-1|s-1'], 'message-1');
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('sanad_conversation_cache'), isNotNull);
  });

  test('device cleanup removes only matching viewport anchors', () async {
    final persistence = SharedPreferencesConversationCachePersistence(
      await SharedPreferences.getInstance(),
    );
    await persistence.save(
      DeviceConversationCacheSnapshot(
        activeDeviceId: 'device-1',
        contexts: {
          'device-1': DeviceConversationContext.empty(),
          'device-2': DeviceConversationContext.empty(),
        },
        sessionDrafts: const {},
        sessionViewportAnchors: const {
          'device-1|session-1': 'message-1',
          'device-2|session-2': 'message-2',
        },
      ),
    );

    await persistence.clearDevice('device-1');
    final restored = await persistence.load();

    expect(restored.activeDeviceId, isNull);
    expect(restored.contexts, isNot(contains('device-1')));
    expect(
      restored.sessionViewportAnchors,
      {'device-2|session-2': 'message-2'},
    );
  });

  test('cloud cleanup preserves local device data durably', () async {
    final persistence = SharedPreferencesConversationCachePersistence(
      await SharedPreferences.getInstance(),
    );
    await persistence.save(
      DeviceConversationCacheSnapshot(
        activeDeviceId: 'cloud-device',
        contexts: {
          'local-device': DeviceConversationContext.empty(),
          'cloud-device': DeviceConversationContext.empty(),
        },
        sessionDrafts: const {},
        sessionViewportAnchors: const {
          'local-device|local-session': 'local-message',
          'cloud-device|cloud-session': 'cloud-message',
        },
      ),
    );

    await persistence.clearCloudUserScope({'cloud-device'});
    final restored = await persistence.load();

    expect(restored.activeDeviceId, isNull);
    expect(restored.contexts, contains('local-device'));
    expect(restored.contexts, isNot(contains('cloud-device')));
    expect(
      restored.sessionViewportAnchors,
      {'local-device|local-session': 'local-message'},
    );
  });
}
