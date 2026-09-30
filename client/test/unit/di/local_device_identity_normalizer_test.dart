import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/di/local_device_identity_normalizer.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/features/conversations/data/persistence/shared_preferences_conversation_cache_persistence.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_draft.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_cache_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_context.dart';
import 'package:sanad_client/features/devices/data/device_preferences_repository_impl.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _legacyId = LocalDeviceIdentityNormalizer.legacyDeviceId;
const _hardwareId = 'hardware-1';

ConversationDraft _draft(String text) => ConversationDraft(
  text: text,
  workspaceId: 'workspace-1',
  providerId: 'provider-1',
  model: 'model-1',
  thinkingMode: 'medium',
  permissionMode: 'ask',
  updatedAt: DateTime.utc(2026, 9, 9),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'moves legacy local state to hardware identity and rebinds destination',
    () async {
      final preferences = await SharedPreferences.getInstance();
      final conversations = SharedPreferencesConversationCachePersistence(
        preferences,
      );
      final routes = DevicePreferencesRepositoryImpl(preferences);
      final legacyContext = DeviceConversationContext.empty().copyWith(
        lastDestination: const ConversationDestination.session(
          deviceId: _legacyId,
          sessionId: 'session-1',
          workspaceId: 'workspace-1',
        ),
        newConversationDraftText: 'new conversation draft',
        newConversationDraftProviderId: 'provider-1',
        newConversationDraftModel: 'model-1',
        newConversationDraftThinkingMode: 'medium',
      );
      await conversations.save(
        DeviceConversationCacheSnapshot(
          activeDeviceId: _legacyId,
          contexts: {_legacyId: legacyContext},
          sessionDrafts: {
            DeviceConversationCacheSnapshot.sessionDraftKey(
              _legacyId,
              'session-1',
            ): _draft(
              'session draft',
            ),
          },
          sessionViewportAnchors: const {
            'local-agent|session-1': 'message-9',
          },
        ),
      );
      await routes.setLastProvider(_legacyId, 'provider-1');
      await routes.setLastModel(_legacyId, 'model-1');
      await routes.setLastThinkingMode(_legacyId, 'medium');
      await preferences.setString('active_device_id', _legacyId);

      await LocalDeviceIdentityNormalizer.normalize(
        preferences,
        _hardwareId,
      );

      final restored = await conversations.load();
      expect(restored.activeDeviceId, _hardwareId);
      expect(restored.contexts, isNot(contains(_legacyId)));
      final context = restored.contexts[_hardwareId]!;
      expect(context.lastDestination?.deviceId, _hardwareId);
      expect(context.lastDestination?.sessionId, 'session-1');
      expect(context.newConversationDraftText, 'new conversation draft');
      expect(
        restored.sessionDrafts['$_hardwareId|session-1']?.text,
        'session draft',
      );
      expect(
        restored.sessionViewportAnchors['$_hardwareId|session-1'],
        'message-9',
      );
      expect(routes.getLastProvider(_hardwareId), 'provider-1');
      expect(routes.getLastModel(_hardwareId), 'model-1');
      expect(routes.getLastThinkingMode(_hardwareId), 'medium');
      expect(preferences.getString('active_device_id'), _hardwareId);
      expect(preferences.getKeys(), isNot(contains('agent_route_${_legacyId}_provider')));
      expect(preferences.getKeys(), isNot(contains('agent_route_${_legacyId}_model')));
      expect(
        preferences.getKeys(),
        isNot(contains('agent_pref_aasd11sdfsdf${_legacyId}_thinking')),
      );
    },
  );

  test('keeps destination state on collision and is idempotent', () async {
    final preferences = await SharedPreferences.getInstance();
    final conversations = SharedPreferencesConversationCachePersistence(
      preferences,
    );
    final routes = DevicePreferencesRepositoryImpl(preferences);
    final targetContext = DeviceConversationContext.empty().copyWith(
      newConversationDraftText: 'target context',
    );
    await conversations.save(
      DeviceConversationCacheSnapshot(
        activeDeviceId: _hardwareId,
        contexts: {
          _legacyId: DeviceConversationContext.empty().copyWith(
            newConversationDraftText: 'legacy context',
          ),
          _hardwareId: targetContext,
        },
        sessionDrafts: {
          '$_legacyId|session-1': _draft('legacy draft'),
          '$_hardwareId|session-1': _draft('target draft'),
        },
        sessionViewportAnchors: const {
          'local-agent|session-1': 'legacy-anchor',
          'hardware-1|session-1': 'target-anchor',
        },
      ),
    );
    await routes.setLastProvider(_legacyId, 'legacy-provider');
    await routes.setLastProvider(_hardwareId, 'target-provider');

    await LocalDeviceIdentityNormalizer.normalize(preferences, _hardwareId);
    final once = await conversations.load();
    await LocalDeviceIdentityNormalizer.normalize(preferences, _hardwareId);
    final twice = await conversations.load();

    expect(twice, once);
    expect(twice.contexts, isNot(contains(_legacyId)));
    expect(
      twice.contexts[_hardwareId]?.newConversationDraftText,
      'target context',
    );
    expect(twice.sessionDrafts['$_hardwareId|session-1']?.text, 'target draft');
    expect(
      twice.sessionViewportAnchors['$_hardwareId|session-1'],
      'target-anchor',
    );
    expect(routes.getLastProvider(_hardwareId), 'target-provider');
    expect(routes.getLastProvider(_legacyId), isNull);
  });
}
