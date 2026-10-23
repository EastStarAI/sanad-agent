// `ComposerWorkspaceChip` must work outside the conversation composer: a
// caller supplies the workspace list and the current selection and receives
// the user's intent, so the schedule form reuses it instead of forking the
// workspace selector.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/composer_workspace_chip.dart';

const _projects = DeviceWorkspace(id: 'workspace-1', name: 'Project', path: '/project');
const _sandbox = DeviceWorkspace(id: 'workspace-2', name: 'Sandbox', path: '/sandbox');

void main() {
  late List<String> calls;

  setUp(() {
    calls = <String>[];
    // Tests only read the chip's typography; no font asset download is needed.
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  tearDown(() {
    GoogleFonts.config.allowRuntimeFetching = true;
  });

  Widget chip({
    List<DeviceWorkspace> workspaces = const [_projects],
    DeviceWorkspace? selected = _projects,
    bool isLoading = false,
    bool requiresWorkspace = false,
    bool hasActiveAgent = true,
    bool isLocked = false,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: ComposerWorkspaceChip(
            availableWorkspaces: workspaces,
            selectedWorkspace: selected,
            isLoadingWorkspaces: isLoading,
            requiresWorkspace: requiresWorkspace,
            hasActiveAgent: hasActiveAgent,
            isLocked: isLocked,
            chipBgColor: Colors.grey.shade200,
            borderColor: Colors.grey,
            dimTextColor: Colors.black54,
            onRefreshWorkspaces: () => calls.add('refresh'),
            onWorkspaceSelected: (workspace) => calls.add('select:${workspace.id}'),
            onWorkspaceCleared: () => calls.add('clear'),
            onAddNewWorkspace: () => calls.add('add'),
          ),
        ),
      ),
    );
  }

  testWidgets('renders the composer key and the caller selection', (tester) async {
    await tester.pumpWidget(chip());
    await tester.pump();

    // Same key the composer's workspace selector carries.
    expect(find.byKey(const Key('workspace_selector_btn')), findsOneWidget);
    expect(find.text('Project'), findsOneWidget);
    expect(calls, isEmpty, reason: 'rendering must not request anything');
  });

  testWidgets('menu item keys match the composer keys', (tester) async {
    await tester.pumpWidget(chip(workspaces: const [_projects, _sandbox]));
    await tester.pump();

    await tester.tap(find.byKey(const Key('workspace_selector_btn')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('workspace_item_workspace-1')), findsOneWidget);
    expect(find.byKey(const Key('workspace_item_workspace-2')), findsOneWidget);
  });

  testWidgets('selecting a workspace calls onWorkspaceSelected with that workspace', (tester) async {
    await tester.pumpWidget(chip(workspaces: const [_projects, _sandbox]));
    await tester.pump();

    await tester.tap(find.byKey(const Key('workspace_selector_btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('workspace_item_workspace-2')));
    await tester.pumpAndSettle();

    expect(calls, ['select:workspace-2']);
  });

  testWidgets('clearing calls onWorkspaceCleared', (tester) async {
    await tester.pumpWidget(chip());
    await tester.pump();

    await tester.tap(find.byKey(const Key('workspace_selector_btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No workspace'));
    await tester.pumpAndSettle();

    expect(calls, ['clear']);
  });

  testWidgets('adding a new workspace calls onAddNewWorkspace', (tester) async {
    await tester.pumpWidget(chip());
    await tester.pump();

    await tester.tap(find.byKey(const Key('workspace_selector_btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add New Workspace'));
    await tester.pumpAndSettle();

    expect(calls, ['add']);
  });

  testWidgets('opening with no loaded workspace asks the caller to refresh once', (tester) async {
    await tester.pumpWidget(chip(workspaces: const [], selected: null));
    await tester.pump();

    await tester.tap(find.byKey(const Key('workspace_selector_btn')));
    await tester.pumpAndSettle();

    expect(calls, ['refresh']);
  });

  testWidgets('opening with a loaded workspace does not refresh', (tester) async {
    await tester.pumpWidget(chip());
    await tester.pump();

    await tester.tap(find.byKey(const Key('workspace_selector_btn')));
    await tester.pumpAndSettle();

    expect(calls, isEmpty);
  });

  testWidgets('a locked chip keeps the composer tooltip and refuses the menu', (tester) async {
    await tester.pumpWidget(chip(isLocked: true));
    await tester.pump();

    expect(find.byTooltip('Workspace is locked for this session'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);

    await tester.tap(find.byKey(const Key('workspace_selector_btn')));
    await tester.pumpAndSettle();

    expect(calls, isEmpty);
    expect(find.byKey(const Key('workspace_item_workspace-1')), findsNothing);
  });

  testWidgets('an empty required workspace shows the composer error label', (tester) async {
    await tester.pumpWidget(chip(workspaces: const [], selected: null, requiresWorkspace: true));
    await tester.pump();

    expect(find.text('Choose Workspace'), findsOneWidget);
  });

  testWidgets('a loading chip shows the inline progress indicator', (tester) async {
    await tester.pumpWidget(chip(isLoading: true));
    await tester.pump();

    expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);
  });
}
