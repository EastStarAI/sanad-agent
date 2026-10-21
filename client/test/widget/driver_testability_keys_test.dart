import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart';
import 'package:sanad_client/driver/ui_inspection_state.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_entry.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_snapshot.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_permission_card.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/workspace_browser_dialog.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/utils/app_platform.dart';

class _RecordingInputCubit extends Cubit<ConversationInputState> implements ConversationInputCubit {
  _RecordingInputCubit() : super(const ConversationInputState());

  final List<String> approvedScopes = [];
  final List<String?> deniedComments = [];

  @override
  Future<void> approvePendingSuspendedRequest({
    required DeviceSuspendedRequest request,
    required String scope,
  }) async {
    approvedScopes.add(scope);
  }

  @override
  Future<void> denyPendingSuspendedRequest({
    required DeviceSuspendedRequest request,
    String? comment,
  }) async {
    deniedComments.add(comment);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _nestedSnapshot = WorkspaceTreeSnapshot(
  workspaceId: '/home/workspaces',
  rootPath: '/home/workspaces',
  path: '/home/workspaces/projects',
  parentPath: '/home/workspaces',
  entries: [
    WorkspaceTreeEntry(
      name: 'alpha',
      path: '/home/workspaces/projects/alpha',
      relativePath: 'projects/alpha',
      isDirectory: true,
    ),
    WorkspaceTreeEntry(
      name: 'beta',
      path: '/home/workspaces/projects/beta',
      relativePath: 'projects/beta',
      isDirectory: true,
    ),
  ],
  truncated: false,
);

Future<void> _pumpBrowser(
  WidgetTester tester, {
  required WorkspaceTreeSnapshot snapshot,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: kSupportedLocales,
      home: Scaffold(
        body: WorkspaceBrowserDialog(
          loader: ({path}) async => snapshot,
          onRenameFolder: (path, newName) async {},
          onDeleteFolder: (path) async {},
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

DeviceSuspendedRequest _permissionRequest() => const DeviceSuspendedRequest(
  requestId: 'permission-1',
  sessionId: 'session-1',
  toolName: 'shell_execute',
  permissionClass: 'shell',
  scope: 'once',
  workspaceId: 'workspace-1',
  workspaceName: 'workspace',
  workspacePath: '/workspace',
  toolInput: {'command': 'pwd'},
  tool: {'name': 'shell_execute'},
);

void main() {
  group('workspace browser driver keys', () {
    testWidgets('each folder row, rename, and delete button has a name-scoped key', (
      tester,
    ) async {
      await _pumpBrowser(tester, snapshot: _nestedSnapshot);

      for (final name in ['alpha', 'beta']) {
        final row = find.byKey(ValueKey('workspace_browser_folder_row:$name'));
        final rename = find.byKey(
          ValueKey('workspace_browser_rename_button:$name'),
        );
        final delete = find.byKey(
          ValueKey('workspace_browser_delete_button:$name'),
        );
        expect(row, findsOneWidget);
        expect(rename, findsOneWidget);
        expect(delete, findsOneWidget);
        expect(inspectableElementEnabled(tester.element(row)), isTrue);
        expect(inspectableElementEnabled(tester.element(rename)), isTrue);
        expect(inspectableElementEnabled(tester.element(delete)), isTrue);
      }
    });

    testWidgets('rename key opens the rename prompt for that folder', (
      tester,
    ) async {
      await _pumpBrowser(tester, snapshot: _nestedSnapshot);

      await tester.tap(
        find.byKey(const ValueKey('workspace_browser_rename_button:beta')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('workspace_folder_name_input')),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextField, 'beta'), findsOneWidget);
    });

    testWidgets('rows at the managed root expose no mutation buttons', (
      tester,
    ) async {
      await _pumpBrowser(
        tester,
        snapshot: const WorkspaceTreeSnapshot(
          workspaceId: '',
          rootPath: '/home/workspaces',
          path: '',
          parentPath: null,
          entries: [
            WorkspaceTreeEntry(
              name: 'alpha',
              path: '/home/workspaces/alpha',
              relativePath: 'alpha',
              isDirectory: true,
            ),
          ],
          truncated: false,
        ),
      );

      expect(
        find.byKey(const ValueKey('workspace_browser_folder_row:alpha')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('workspace_browser_rename_button:alpha')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('workspace_browser_delete_button:alpha')),
        findsNothing,
      );
    });
  });

  group('permission card driver keys', () {
    late _RecordingInputCubit cubit;

    setUp(() {
      AppPlatform.overrideIsMobile = null;
      cubit = _RecordingInputCubit();
    });

    tearDown(() async {
      AppPlatform.overrideIsMobile = null;
      await cubit.close();
    });

    Future<void> pumpCard(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlocProvider<ConversationInputCubit>.value(
              value: cubit,
              child: ConversationPermissionCard(
                request: _permissionRequest(),
                borderColor: Colors.grey,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('each approval option is keyed, enabled, and sends its scope', (
      tester,
    ) async {
      await pumpCard(tester);

      for (final scope in ['once', 'session', 'workspace']) {
        final option = find.byKey(ValueKey('permission_option_$scope'));
        expect(option, findsOneWidget);
        expect(inspectableElementEnabled(tester.element(option)), isTrue);
        await tester.tap(option);
        await tester.pump();
      }

      expect(cubit.approvedScopes, ['once', 'session', 'workspace']);
    });

    testWidgets('deny option reveals the keyed comment input and submit', (
      tester,
    ) async {
      await pumpCard(tester);

      final deny = find.byKey(const ValueKey('permission_option_deny'));
      expect(deny, findsOneWidget);
      expect(inspectableElementEnabled(tester.element(deny)), isTrue);
      expect(
        find.byKey(const ValueKey('permission_deny_submit_button')),
        findsNothing,
      );

      await tester.tap(deny);
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('permission_deny_comment_input')),
        'use ls instead',
      );
      final submit = find.byKey(const ValueKey('permission_deny_submit_button'));
      expect(inspectableElementEnabled(tester.element(submit)), isTrue);
      await tester.tap(submit);
      await tester.pump();

      expect(cubit.deniedComments, ['use ls instead']);
    });
  });

  group('inspectableWidgetEnabled', () {
    test('reports callback-driven enabled state for interactive widgets', () {
      void noop() {}

      expect(
        inspectableWidgetEnabled(
          const IconButton(onPressed: null, icon: Icon(Icons.edit)),
        ),
        isFalse,
      );
      expect(
        inspectableWidgetEnabled(
          IconButton(onPressed: noop, icon: const Icon(Icons.edit)),
        ),
        isTrue,
      );
      expect(
        inspectableWidgetEnabled(
          const FilledButton(onPressed: null, child: Text('Go')),
        ),
        isFalse,
      );
      expect(inspectableWidgetEnabled(const InkWell()), isFalse);
      expect(inspectableWidgetEnabled(InkWell(onTap: noop)), isTrue);
      expect(inspectableWidgetEnabled(ListTile(onTap: noop)), isTrue);
      expect(
        inspectableWidgetEnabled(ListTile(enabled: false, onTap: noop)),
        isFalse,
      );
      expect(inspectableWidgetEnabled(const TextField(enabled: false)), isFalse);
      expect(inspectableWidgetEnabled(const Text('plain')), isNull);
    });
  });
}
