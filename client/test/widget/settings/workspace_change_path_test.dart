import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_command_failure.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_entry.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/workspace_browser_dialog.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/settings/data/workspace_security_client.dart';
import 'package:sanad_client/features/settings/presentation/widgets/settings_pages/workspace_change_path.dart';
import 'package:sanad_client/features/settings/presentation/widgets/settings_pages/workspace_page.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/utils/toast_utils.dart';
import 'package:sanad_client/utils/workspace_picker_helper.dart';

import '../../helpers/fake_conversation_repository.dart';
import '../../helpers/pump_app.dart';

/// The device's managed workspaces root, as the daemon reports it.
const _root = '/Users/agent/.sanad/workspaces';
const _currentFolder = '$_root/app';
const _targetFolder = '$_root/acc/target';

const _workspace = DeviceWorkspace(
  id: 'ws-1',
  name: 'app',
  path: _currentFolder,
);

const _rootSnapshot = WorkspaceTreeSnapshot(
  workspaceId: '',
  rootPath: _root,
  path: _root,
  parentPath: null,
  entries: [
    WorkspaceTreeEntry(
      name: 'acc',
      path: '$_root/acc',
      relativePath: 'acc',
      isDirectory: true,
    ),
  ],
  truncated: false,
);

const _currentFolderSnapshot = WorkspaceTreeSnapshot(
  workspaceId: '',
  rootPath: _root,
  path: _currentFolder,
  parentPath: _root,
  entries: [
    WorkspaceTreeEntry(
      name: 'target',
      path: _targetFolder,
      relativePath: 'app/target',
      isDirectory: true,
    ),
  ],
  truncated: false,
);

const _targetSnapshot = WorkspaceTreeSnapshot(
  workspaceId: '',
  rootPath: _root,
  path: _targetFolder,
  parentPath: '$_root/acc',
  entries: [],
  truncated: false,
);

class _FakeSecurityClient implements WorkspaceSecurityClient {
  final _changes = StreamController<WorkspacePolicy>.broadcast();

  Future<void> dispose() => _changes.close();

  @override
  Stream<WorkspacePolicy> watch(DeviceConfig device, String workspaceId) =>
      _changes.stream;

  @override
  Future<WorkspacePolicy> read(DeviceConfig device, String workspaceId) async =>
      const WorkspacePolicy(revision: 1, canWiden: true);

  @override
  Future<WorkspacePolicy> update(
    DeviceConfig device,
    String workspaceId, {
    int? expectedRevision,
    WorkspacePermissionMode? permissionMode,
    WorkspaceExecutionMode? executionMode,
    WorkspaceHostDiscoveryPolicy? hostDiscoveryPolicy,
  }) async => const WorkspacePolicy(revision: 2, canWiden: true);
}

void main() {
  late FakeConversationRepository transport;
  late ConversationCacheRepository cache;
  late DeviceConfig remote;
  late DeviceConfig offline;
  late DeviceConfig local;
  late List<String> toasts;
  late _FakeSecurityClient securityClient;

  setUp(() {
    transport = FakeConversationRepository();
    cache = ConversationCacheRepository(
      cache: ConversationCacheStore(),
      transport: transport,
    );
    // A device reached over the cloud: online, never locally reachable.
    remote = DeviceConfig(id: 'remote-1', name: 'Sanad Agent Test2', isOnline: true);
    offline = DeviceConfig(id: 'remote-1', name: 'Sanad Agent Test2');
    local = DeviceConfig(
      id: 'local-1',
      name: 'This Mac',
      isOnline: true,
      metadata: const {'is_local_reachable': true},
    );
    toasts = [];
    ToastUtils.debugOnShowError = toasts.add;
    securityClient = _FakeSecurityClient();
    getIt.registerSingleton<WorkspaceSecurityClient>(securityClient);
  });

  tearDown(() async {
    WorkspacePickerHelper.debugRemoteBrowserPick = null;
    WorkspacePickerHelper.debugOnRemoteDisabled = null;
    ToastUtils.debugOnShowError = null;
    await securityClient.dispose();
    cache.dispose();
    await transport.dispose();
    await getIt.reset();
  });

  WorkspaceTreeSnapshot snapshotFor(String? path) => switch (path) {
    null || '' => _rootSnapshot,
    _currentFolder => _currentFolderSnapshot,
    _targetFolder => _targetSnapshot,
    _ => throw WorkspaceCommandFailure(
      'That path is outside the managed workspaces root.',
      code: WorkspaceCommandFailure.pathNotAllowed,
    ),
  };

  /// Pages the Settings workspace overview with the real Change Path gate.
  Future<void> pumpWorkspacePage(WidgetTester tester, DeviceConfig device) async {
    await pumpTestApp(
      tester,
      child: WorkspacePage(
        device: device,
        workspace: _workspace,
        onRename: () {},
        onChangePath: workspaceChangePathAction(
          device: device,
          action: () {},
        ),
        onRemove: null,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Runs the real flow from a button so dialogs mount in a live navigator.
  Future<void> startChangePath(WidgetTester tester, DeviceConfig device) async {
    await pumpTestApp(
      tester,
      child: Builder(
        builder: (context) => Center(
          child: TextButton(
            key: const Key('start_change_path'),
            onPressed: () => showWorkspaceChangePathFlow(
              context: context,
              cache: cache,
              device: device,
              workspace: _workspace,
              browser: WorkspaceBrowserCallbacks.forDevice(cache, device),
            ),
            child: const Text('Change Path'),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('start_change_path')));
    await tester.pumpAndSettle();
  }

  testWidgets('offers Change Path for an online remote device and hides it offline', (
    tester,
  ) async {
    await pumpWorkspacePage(tester, remote);
    expect(find.byKey(const Key('workspace_change_path_button')), findsOneWidget);

    await pumpWorkspacePage(tester, offline);
    expect(find.byKey(const Key('workspace_change_path_button')), findsNothing);

    // D8: a same-desktop local device keeps offering Change Path.
    await pumpWorkspacePage(tester, local);
    expect(find.byKey(const Key('workspace_change_path_button')), findsOneWidget);
  });

  testWidgets('a local-reachable device never opens the confined browser', (
    tester,
  ) async {
    var browserOpened = false;
    WorkspacePickerHelper.debugRemoteBrowserPick = (callbacks) async {
      browserOpened = true;
      return null;
    };

    await pumpTestApp(
      tester,
      child: Builder(
        builder: (context) => Center(
          child: TextButton(
            key: const Key('pick_local'),
            onPressed: () => WorkspacePickerHelper.pickWorkspacePath(
              context: context,
              device: local,
              remoteBrowser: WorkspaceBrowserCallbacks.forDevice(cache, local),
              debugOverride: () async => '/Users/agent/Projects/app',
            ),
            child: const Text('Pick'),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('pick_local')));
    await tester.pumpAndSettle();

    expect(browserOpened, isFalse);
    expect(transport.browseWorkspaceTreeRequests, isEmpty);
    expect(transport.relocateRequests, isEmpty);
  });

  testWidgets(
    'opens the confined browser bound to the inspected device at the current folder, and cancel sends nothing',
    (tester) async {
      transport.browseWorkspaceTreeHandler = ({agent, workspaceId, path}) async =>
          snapshotFor(path);

      await startChangePath(tester, remote);

      final first = transport.browseWorkspaceTreeRequests.first;
      expect(first['device_id'], remote.id);
      expect(first['workspace_id'], isNull);
      expect(first['path'], _currentFolder);
      expect(
        find.byKey(const Key('workspace_browser_change_path_notice')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('workspace_browser_cancel_button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('workspace_change_path_confirm_dialog')), findsNothing);
      expect(transport.relocateRequests, isEmpty);
    },
  );

  testWidgets(
    'opens at the device root when the current folder is outside the workspaces root',
    (tester) async {
      transport.browseWorkspaceTreeHandler = ({agent, workspaceId, path}) async =>
          snapshotFor(path);
      const outsideRoot = DeviceWorkspace(
        id: 'ws-2',
        name: 'outside',
        path: '/Users/agent/Projects/outside',
      );

      await pumpTestApp(
        tester,
        child: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const Key('start_change_path'),
              onPressed: () => showWorkspaceChangePathFlow(
                context: context,
                cache: cache,
                device: remote,
                workspace: outsideRoot,
                browser: WorkspaceBrowserCallbacks.forDevice(cache, remote),
              ),
              child: const Text('Change Path'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('start_change_path')));
      await tester.pumpAndSettle();

      expect(
        transport.browseWorkspaceTreeRequests.map((request) => request['path']),
        ['/Users/agent/Projects/outside', null],
      );
      expect(find.byKey(const Key('workspace_browser_load_error')), findsNothing);
      expect(find.text(_root), findsOneWidget);
      // The root itself can never be the target, in either mode.
      final cta = tester.widget<FilledButton>(
        find.byKey(const Key('workspace_browser_use_folder_button')),
      );
      expect(cta.onPressed, isNull);
    },
  );

  testWidgets('a pick is confirmed by name before exactly one relocate', (
    tester,
  ) async {
    transport.browseWorkspaceTreeHandler = ({agent, workspaceId, path}) async =>
        snapshotFor(path);

    await startChangePath(tester, remote);
    await tester.tap(find.byKey(const ValueKey('workspace_browser_folder_row:target')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace_browser_use_folder_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workspace_change_path_confirm_dialog')), findsOneWidget);
    expect(find.text(_targetFolder), findsOneWidget);
    // Nothing is sent before the user confirms the resolved target.
    expect(transport.relocateRequests, isEmpty);

    await tester.tap(find.byKey(const Key('workspace_change_path_confirm_button')));
    await tester.pumpAndSettle();

    expect(transport.relocateRequests, [
      {
        'device_id': remote.id,
        'workspace_id': 'ws-1',
        'new_path': _targetFolder,
      },
    ]);
    expect(toasts, isEmpty);
  });

  testWidgets('cancelling the confirmation sends nothing', (tester) async {
    transport.browseWorkspaceTreeHandler = ({agent, workspaceId, path}) async =>
        snapshotFor(path);

    await startChangePath(tester, remote);
    await tester.tap(find.byKey(const ValueKey('workspace_browser_folder_row:target')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace_browser_use_folder_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace_change_path_cancel_button')));
    await tester.pumpAndSettle();

    expect(transport.relocateRequests, isEmpty);
  });

  testWidgets('an out-of-root rejection shows the specific message', (tester) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    transport.browseWorkspaceTreeHandler = ({agent, workspaceId, path}) async =>
        snapshotFor(path);
    transport.relocateWorkspaceHandler = (agent, workspaceId, newPath) async {
      throw WorkspaceCommandFailure(
        'Failed to change workspace path: That path is outside the managed workspaces root.',
        code: WorkspaceCommandFailure.pathNotAllowed,
      );
    };

    await startChangePath(tester, remote);
    await tester.tap(find.byKey(const ValueKey('workspace_browser_folder_row:target')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace_browser_use_folder_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace_change_path_confirm_button')));
    await tester.pumpAndSettle();

    expect(toasts, [l10n.workspaceChangePathOutsideRoot]);
  });

  testWidgets('any other rejection keeps the daemon reason', (tester) async {
    const reason = 'That folder is already connected to another workspace.';
    transport.browseWorkspaceTreeHandler = ({agent, workspaceId, path}) async =>
        snapshotFor(path);
    transport.relocateWorkspaceHandler = (agent, workspaceId, newPath) async {
      throw WorkspaceCommandFailure(reason);
    };

    await startChangePath(tester, remote);
    await tester.tap(find.byKey(const ValueKey('workspace_browser_folder_row:target')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace_browser_use_folder_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace_change_path_confirm_button')));
    await tester.pumpAndSettle();

    expect(toasts, [reason]);
  });
}
