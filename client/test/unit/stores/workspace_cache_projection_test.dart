import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_resource_state.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_context.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/stores/cache_generation_guard.dart';
import 'package:sanad_client/features/conversations/domain/stores/workspace_cache_projection.dart';

void main() {
  late CacheGenerationGuard guard;
  late WorkspaceCacheProjection projection;
  late Map<String, DeviceConversationContext> contexts;
  var notifyCount = 0;

  setUp(() {
    guard = CacheGenerationGuard();
    contexts = {};
    notifyCount = 0;

    projection = WorkspaceCacheProjection(
      generationGuard: guard,
      getContext: (id) => contexts[id] ?? DeviceConversationContext.empty(),
      updateContext: (id, ctx) => contexts[id] = ctx,
      ensureDeviceContext: (id) => contexts.putIfAbsent(id, () => DeviceConversationContext.empty()),
      notify: () => notifyCount++,
    );
  });

  group('WorkspaceCacheProjection', () {
    test('setWorkspacesLoading sets loading or refreshing state', () {
      projection.setWorkspacesLoading('dev-1');
      expect(contexts['dev-1']?.workspaces.state, ConversationResourceState.loading);
      expect(notifyCount, 1);
    });

    test('applyWorkspaceCreated inserts at front and expands workspace', () {
      const ws = DeviceWorkspace(id: 'ws-1', name: 'Ws 1', path: '/path/1');
      projection.applyWorkspaceCreated('dev-1', ws);

      expect(contexts['dev-1']?.workspaces.workspaces.first, ws);
      expect(contexts['dev-1']?.workspaceExpansion['ws-1'], isTrue);
      expect(contexts['dev-1']?.workspaces.state, ConversationResourceState.ready);
      expect(notifyCount, 1);
    });

    test('applyWorkspaceUpdated updates workspace and session metadata in pages', () {
      const ws1 = DeviceWorkspace(id: 'ws-1', name: 'Old Name', path: '/path/1');
      projection.applyWorkspaceCreated('dev-1', ws1);
      notifyCount = 0;

      const wsUpdated = DeviceWorkspace(id: 'ws-1', name: 'New Name', path: '/path/1');
      projection.applyWorkspaceUpdated('dev-1', wsUpdated);

      expect(contexts['dev-1']?.workspaces.workspaces.first.name, 'New Name');
      expect(notifyCount, 1);
    });

    test('applyWorkspaceRemoved removes workspace and cleans up destination and expansion', () {
      const ws = DeviceWorkspace(id: 'ws-1', name: 'Ws 1', path: '/path/1');
      projection.applyWorkspaceCreated('dev-1', ws);
      notifyCount = 0;

      projection.applyWorkspaceRemoved('dev-1', 'ws-1');
      expect(contexts['dev-1']?.workspaces.workspaces, isEmpty);
      expect(contexts['dev-1']?.workspaceExpansion.containsKey('ws-1'), isFalse);
      expect(notifyCount, 1);
    });

    test('applyWorkspacesRefreshed rejects stale generation and accepts current', () {
      final gen1 = guard.advanceWorkspacesGeneration('dev-1');
      final gen2 = guard.advanceWorkspacesGeneration('dev-1');

      // Stale refresh (gen1 != gen2) is rejected
      const wsStale = [DeviceWorkspace(id: 'ws-stale', name: 'Stale', path: '/stale')];
      projection.applyWorkspacesRefreshed('dev-1', wsStale, generation: gen1);

      expect(contexts['dev-1']?.workspaces.workspaces ?? const [], isEmpty);
      expect(notifyCount, 0);

      // Current refresh (gen2) is accepted
      const wsCurrent = [DeviceWorkspace(id: 'ws-current', name: 'Current', path: '/current')];
      projection.applyWorkspacesRefreshed('dev-1', wsCurrent, generation: gen2);

      expect(contexts['dev-1']?.workspaces.workspaces, wsCurrent);
      expect(contexts['dev-1']?.workspaces.state, ConversationResourceState.ready);
      expect(notifyCount, 1);
    });

    test('applyWorkspacesError rejects stale generation and accepts current', () {
      final gen1 = guard.advanceWorkspacesGeneration('dev-1');
      final gen2 = guard.advanceWorkspacesGeneration('dev-1');

      // Stale error is rejected
      projection.applyWorkspacesError('dev-1', 'old error', generation: gen1);
      expect(notifyCount, 0);
      expect(contexts['dev-1']?.workspaces.lastError, isNull);

      // Current error is accepted
      projection.applyWorkspacesError('dev-1', 'current error', generation: gen2);
      expect(notifyCount, 1);
      expect(contexts['dev-1']?.workspaces.lastError, 'current error');
    });

    test('setWorkspaceExpansion toggles expansion flag', () {
      projection.setWorkspaceExpansion('dev-1', 'ws-1', false);
      expect(contexts['dev-1']?.workspaceExpansion['ws-1'], isFalse);
      expect(notifyCount, 1);
    });
  });
}
