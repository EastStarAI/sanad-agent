import 'dart:async';

import 'package:sanad_client/features/conversations/domain/models/workspace_tree_entry.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_snapshot.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/workspace_browser_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_command_failure.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

void main() {
  testWidgets('navigates folders and returns the selected path', (tester) async {
    final requests = <String?>[];

    Future<WorkspaceTreeSnapshot> loader({String? path}) async {
      requests.add(path);
      if (path == '/repo/apps') {
        return const WorkspaceTreeSnapshot(
          workspaceId: '/repo',
          rootPath: '/repo',
          path: '/repo/apps',
          parentPath: '/repo',
          entries: [
            WorkspaceTreeEntry(
              name: 'sanad-client',
              path: '/repo/apps/sanad-client',
              relativePath: 'apps/sanad-client',
              isDirectory: true,
            ),
          ],
          truncated: false,
        );
      }

      return const WorkspaceTreeSnapshot(
        workspaceId: '/repo',
        rootPath: '/repo',
        path: '/repo',
        parentPath: null,
        entries: [
          WorkspaceTreeEntry(name: 'apps', path: '/repo/apps', relativePath: 'apps', isDirectory: true),
        ],
        truncated: false,
      );
    }

    String? selectedPath;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: kSupportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  selectedPath = await showDialog<String>(
                    context: context,
                    builder: (_) => WorkspaceBrowserDialog(loader: loader),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump();

    expect(requests, [null]);
    expect(find.byType(ListTile), findsOneWidget);

    await tester.tap(find.byType(ListTile));
    await tester.pump();
    await tester.pump();

    expect(requests, [null, '/repo/apps']);
    expect(find.text('sanad-client'), findsOneWidget);

    await tester.tap(find.text('Use This Folder'));
    await tester.pumpAndSettle();

    expect(selectedPath, '/repo/apps');
  });

  testWidgets('uses daemon-provided parent path to navigate back', (tester) async {
    final requests = <String?>[];

    Future<WorkspaceTreeSnapshot> loader({String? path}) async {
      requests.add(path);
      if (path == '/repo/apps') {
        return const WorkspaceTreeSnapshot(
          workspaceId: '/repo',
          rootPath: '/repo',
          path: '/repo/apps',
          parentPath: '',
          entries: [
            WorkspaceTreeEntry(
              name: 'sanad-client',
              path: '/repo/apps/sanad-client',
              relativePath: 'sanad-client',
              isDirectory: true,
            ),
          ],
          truncated: false,
        );
      }

      return const WorkspaceTreeSnapshot(
        workspaceId: '',
        rootPath: '',
        path: '',
        parentPath: null,
        entries: [
          WorkspaceTreeEntry(name: 'repo', path: '/repo/apps', relativePath: '/repo/apps', isDirectory: true),
        ],
        truncated: false,
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: kSupportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  unawaited(
                    showDialog<String>(
                      context: context,
                      builder: (_) => WorkspaceBrowserDialog(loader: loader),
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('repo'));
    await tester.pump();
    await tester.pump();

    expect(requests, [null, '/repo/apps']);

    await tester.tap(find.text('..'));
    await tester.pump();
    await tester.pump();

    expect(requests, [null, '/repo/apps', '']);
    expect(find.text('repo'), findsOneWidget);
  });

  testWidgets('creates and renames folders then refreshes the current path', (
    tester,
  ) async {
    final loadRequests = <String?>[];
    final createRequests = <(String, String)>[];
    final renameRequests = <(String, String)>[];

    await _openBrowser(
      tester,
      loader: ({path}) async {
        loadRequests.add(path);
        return _repoSnapshot;
      },
      onCreateFolder: (parentPath, name) async {
        createRequests.add((parentPath, name));
      },
      onRenameFolder: (path, name) async {
        renameRequests.add((path, name));
      },
    );

    await tester.tap(find.byTooltip('New Folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'new-child');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(createRequests, [('/repo', 'new-child')]);
    expect(loadRequests, [null, '/repo']);

    await tester.tap(find.byTooltip('Rename Folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'renamed-apps');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(renameRequests, [('/repo/apps', 'renamed-apps')]);
    expect(loadRequests, [null, '/repo', '/repo']);
  });

  testWidgets('deletes only after confirmation and refreshes', (tester) async {
    final loadRequests = <String?>[];
    final deleteRequests = <String>[];

    await _openBrowser(
      tester,
      loader: ({path}) async {
        loadRequests.add(path);
        return _repoSnapshot;
      },
      onDeleteFolder: (path) async => deleteRequests.add(path),
    );

    await tester.tap(find.byTooltip('Delete Folder'));
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot be undone'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
    await tester.pumpAndSettle();
    expect(deleteRequests, isEmpty);

    await tester.tap(find.byTooltip('Delete Folder'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(deleteRequests, ['/repo/apps']);
    expect(loadRequests, [null, '/repo']);
  });

  testWidgets('keeps the snapshot visible and reports mutation failures', (
    tester,
  ) async {
    await _openBrowser(
      tester,
      loader: ({path}) async => _repoSnapshot,
      onCreateFolder: (parentPath, name) async {
        throw StateError('permission denied');
      },
    );

    await tester.tap(find.byTooltip('New Folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'blocked');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('workspace-folder-mutation-error')),
      findsOneWidget,
    );
    // An uncoded failure keeps the Agent's reason under the localized line.
    expect(
      find.text('The device could not complete this folder action.\npermission denied'),
      findsOneWidget,
    );
    expect(find.text('apps'), findsWidgets);
  });

  testWidgets('rejects multi-segment names before calling the daemon', (
    tester,
  ) async {
    var createCalls = 0;
    await _openBrowser(
      tester,
      loader: ({path}) async => _repoSnapshot,
      onCreateFolder: (parentPath, name) async => createCalls++,
    );

    await tester.tap(find.byTooltip('New Folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '../outside');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(createCalls, 0);
    expect(find.textContaining('single path segment'), findsOneWidget);
  });

  testWidgets('does not offer mutations on an abstract system-roots snapshot', (
    tester,
  ) async {
    await _openBrowser(
      tester,
      loader: ({path}) async => const WorkspaceTreeSnapshot(
        workspaceId: '',
        rootPath: '',
        path: '',
        parentPath: null,
        entries: [
          WorkspaceTreeEntry(
            name: 'C:',
            path: r'C:\',
            relativePath: r'C:\',
            isDirectory: true,
          ),
        ],
        truncated: false,
      ),
      onCreateFolder: (parentPath, name) async {},
      onRenameFolder: (path, name) async {},
      onDeleteFolder: (path) async {},
    );

    expect(find.byTooltip('New Folder'), findsNothing);
    expect(find.byTooltip('Rename Folder'), findsNothing);
    expect(find.byTooltip('Delete Folder'), findsNothing);
  });

  testWidgets('disables Use This Folder at the managed root', (tester) async {
    await _openBrowser(tester, loader: ({path}) async {
      return path == '/root/apps' ? _nestedSnapshot : _rootSnapshot;
    });

    FilledButton useButton() => tester.widget<FilledButton>(
      find.byKey(const Key('workspace_browser_use_folder_button')),
    );
    expect(useButton().onPressed, isNull);
    expect(find.byKey(const Key('workspace_browser_parent_row')), findsNothing);
    expect(find.byKey(const Key('workspace_browser_root_hint')), findsOneWidget);

    await tester.tap(find.text('apps').first);
    await tester.pumpAndSettle();
    expect(useButton().onPressed, isNotNull);
    expect(find.byKey(const Key('workspace_browser_parent_row')), findsOneWidget);
    expect(find.byKey(const Key('workspace_browser_root_hint')), findsNothing);
  });

  testWidgets('explains workspace_in_use and path_not_allowed rejections', (
    tester,
  ) async {
    await _openBrowser(
      tester,
      loader: ({path}) async => _rootSnapshot,
      onRenameFolder: (path, name) async {
        throw WorkspaceCommandFailure(
          'Failed to rename folder: in use.',
          code: WorkspaceCommandFailure.workspaceInUse,
        );
      },
      onDeleteFolder: (path) async {
        throw WorkspaceCommandFailure(
          'Failed to delete folder: outside.',
          code: WorkspaceCommandFailure.pathNotAllowed,
        );
      },
    );

    await tester.tap(find.byTooltip('Rename Folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'moved');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'This folder is or contains a workspace. Remove that workspace first.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('Delete Folder'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        "This folder is outside the device's workspaces folder or cannot be used.",
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Failed to'), findsNothing);
  });

  testWidgets('a rejected browse shows a localized load error', (tester) async {
    await _openBrowser(
      tester,
      loader: ({path}) async {
        throw WorkspaceCommandFailure(
          'Failed to browse workspace: outside.',
          code: WorkspaceCommandFailure.pathNotAllowed,
        );
      },
    );

    expect(find.byKey(const Key('workspace_browser_load_error')), findsOneWidget);
    expect(
      find.text(
        "This folder is outside the device's workspaces folder or cannot be used.",
      ),
      findsOneWidget,
    );
  });

  testWidgets('renders Arabic strings with an LTR path line', (tester) async {
    await _openBrowser(
      tester,
      locale: const Locale('ar'),
      loader: ({path}) async {
        return path == '/root/apps' ? _nestedSnapshot : _rootSnapshot;
      },
      onCreateFolder: (parentPath, name) async {},
      onRenameFolder: (path, name) async {},
      onDeleteFolder: (path) async {},
    );

    final ar = await AppLocalizations.delegate.load(const Locale('ar'));
    expect(find.text(ar.workspaceBrowserTitle), findsOneWidget);
    expect(find.text(ar.workspaceBrowserUseFolder), findsOneWidget);
    expect(find.text(ar.cancel), findsOneWidget);
    expect(find.byTooltip(ar.workspaceBrowserNewFolder), findsOneWidget);
    expect(find.byTooltip(ar.workspaceBrowserRenameFolder), findsOneWidget);
    expect(find.byTooltip(ar.workspaceBrowserDeleteFolder), findsOneWidget);
    expect(find.text('Choose Workspace'), findsNothing);

    final dialogDirection = Directionality.of(
      tester.element(find.text(ar.workspaceBrowserTitle)),
    );
    expect(dialogDirection, TextDirection.rtl);
    final pathDirection = Directionality.of(
      tester.element(find.byKey(const Key('workspace_browser_current_path'))),
    );
    expect(pathDirection, TextDirection.ltr);

    await tester.tap(find.text('apps').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('workspace_browser_parent_row')), findsOneWidget);
    expect(find.text('..'), findsOneWidget);

    await tester.tap(find.byTooltip(ar.workspaceBrowserDeleteFolder));
    await tester.pumpAndSettle();
    expect(find.text(ar.workspaceBrowserDeleteConfirmation('child')), findsOneWidget);
  });
  testWidgets('change mode offers to change the workspace to the picked folder', (
    tester,
  ) async {
    final requests = <String?>[];
    final en = await AppLocalizations.delegate.load(const Locale('en'));

    await _openBrowser(
      tester,
      mode: WorkspaceBrowserMode.changePath,
      initialPath: '/root/apps',
      loader: ({path}) async {
        requests.add(path);
        return path == '/root/apps' ? _nestedSnapshot : _rootSnapshot;
      },
      onCreateFolder: (parentPath, name) async {},
    );

    expect(requests, ['/root/apps']);
    expect(find.text(en.workspaceBrowserChangeToFolder), findsOneWidget);
    expect(find.text(en.workspaceBrowserUseFolder), findsNothing);
    expect(
      find.byKey(const Key('workspace_browser_change_path_notice')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('workspace_browser_root_hint')), findsNothing);

    await tester.tap(find.text(en.workspaceBrowserChangeToFolder));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('workspace_browser_change_path_notice')), findsNothing);
  });

  testWidgets('change mode keeps the call to action disabled at the root', (
    tester,
  ) async {
    await _openBrowser(
      tester,
      mode: WorkspaceBrowserMode.changePath,
      initialPath: '/outside/workspaces-root-foreign',
      loader: ({path}) async {
        if (path != null && path.isNotEmpty) throw StateError('Not allowed.');
        return _rootSnapshot;
      },
    );

    final cta = tester.widget<FilledButton>(
      find.byKey(const Key('workspace_browser_use_folder_button')),
    );
    expect(cta.onPressed, isNull);
    expect(find.byKey(const Key('workspace_browser_load_error')), findsNothing);
  });

  testWidgets('change mode renders Arabic copy right-to-left', (tester) async {
    final ar = await AppLocalizations.delegate.load(const Locale('ar'));

    await _openBrowser(
      tester,
      mode: WorkspaceBrowserMode.changePath,
      initialPath: '/root/apps',
      locale: const Locale('ar'),
      loader: ({path}) async => _nestedSnapshot,
    );

    expect(find.text(ar.workspaceBrowserChangeToFolder), findsOneWidget);
    expect(
      find.byKey(const Key('workspace_browser_change_path_notice')),
      findsOneWidget,
    );
    expect(
      Directionality.of(
        tester.element(find.byKey(const Key('workspace_browser_change_path_notice'))),
      ),
      TextDirection.rtl,
    );
    expect(
      Directionality.of(
        tester.element(find.byKey(const Key('workspace_browser_current_path'))),
      ),
      TextDirection.ltr,
    );
  });
}

const _repoSnapshot = WorkspaceTreeSnapshot(
  workspaceId: '/repo',
  rootPath: '/repo',
  path: '/repo',
  parentPath: null,
  entries: [
    WorkspaceTreeEntry(
      name: 'apps',
      path: '/repo/apps',
      relativePath: 'apps',
      isDirectory: true,
    ),
  ],
  truncated: false,
);

Future<void> _openBrowser(
  WidgetTester tester, {
  required WorkspaceTreeLoader loader,
  WorkspaceFolderCreator? onCreateFolder,
  WorkspaceFolderRenamer? onRenameFolder,
  WorkspaceFolderDeleter? onDeleteFolder,
  WorkspaceBrowserMode mode = WorkspaceBrowserMode.createWorkspace,
  String? initialPath,
  Locale? locale,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: kSupportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () {
                unawaited(
                  showDialog<String>(
                    context: context,
                    builder: (_) => WorkspaceBrowserDialog(
                      loader: loader,
                      onCreateFolder: onCreateFolder,
                      onRenameFolder: onRenameFolder,
                      onDeleteFolder: onDeleteFolder,
                      mode: mode,
                      initialPath: initialPath,
                    ),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

const _rootSnapshot = WorkspaceTreeSnapshot(
  workspaceId: '',
  rootPath: '/root',
  path: '/root',
  parentPath: null,
  entries: [
    WorkspaceTreeEntry(
      name: 'apps',
      path: '/root/apps',
      relativePath: 'apps',
      isDirectory: true,
    ),
  ],
  truncated: false,
);

const _nestedSnapshot = WorkspaceTreeSnapshot(
  workspaceId: '',
  rootPath: '/root',
  path: '/root/apps',
  parentPath: '/root',
  entries: [
    WorkspaceTreeEntry(
      name: 'child',
      path: '/root/apps/child',
      relativePath: 'apps/child',
      isDirectory: true,
    ),
  ],
  truncated: false,
);
