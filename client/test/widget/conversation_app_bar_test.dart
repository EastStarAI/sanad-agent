import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_visual_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_state.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_app_bar.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/sidebar/sidebar_composition.dart';
import 'package:sanad_client/utils/app_platform.dart';

void main() {
  test('an existing empty session is active while a null session is new', () {
    expect(
      const SessionMessagesState(activeSessionId: 'session-1').visualState,
      ConversationVisualState.activeSession,
    );
    expect(
      const SessionMessagesState().visualState,
      ConversationVisualState.newConversation,
    );
    expect(
      const SessionMessagesState(requestedSessionId: 'session-1', isHistoryLoading: true).visualState,
      ConversationVisualState.loadingTransition,
    );
    expect(
      const SessionMessagesState(historyLoadError: 'Could not load').visualState,
      ConversationVisualState.loadingTransition,
    );
  });

  test('showAppBar is true for active and loading transition, false only for new conversation', () {
    expect(ConversationVisualState.newConversation.showAppBar, isFalse);
    expect(ConversationVisualState.loadingTransition.showAppBar, isTrue);
    expect(ConversationVisualState.activeSession.showAppBar, isTrue);
  });


  testWidgets('desktop app bar constrains long workspace and session titles', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 240));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConversationAppBar(
            sessionTitle: 'A very long conversation title that must remain inside the available width',
            workspace: DeviceWorkspace(
              id: 'workspace-1',
              name: 'A very long workspace name that must be truncated safely',
              path: '/workspace',
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final workspaceText = tester.widget<Text>(
      find.text('A very long workspace name that must be truncated safely'),
    );
    expect(workspaceText.overflow, TextOverflow.ellipsis);
  });

  testWidgets('mobile app bar omits workspace subtitle when unscoped', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationAppBar(
            sessionTitle: 'Unscoped session',
            isMobile: true,
            onMenuPressed: () {},
          ),
        ),
      ),
    );

    expect(find.text('Unscoped session'), findsOneWidget);
    expect(find.byKey(const Key('mobile_compact_window_btn')), findsOneWidget);
    expect(find.byTooltip('Open navigation menu'), findsOneWidget);
    expect(find.byType(Text), findsOneWidget);
  });

  testWidgets('narrow desktop actions use neutral color and macOS alignment', (
    tester,
  ) async {
    const scheme = ColorScheme.dark();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: scheme),
        home: Scaffold(
          body: ConversationAppBar(
            sessionTitle: 'Conversation',
            isMobile: true,
            onMenuPressed: () {},
          ),
        ),
      ),
    );

    final actionIcons = tester.widgetList<Icon>(
      find.descendant(
        of: find.byKey(const Key('conversation_header_actions_alignment')),
        matching: find.byType(Icon),
      ),
    );
    expect(actionIcons, isNotEmpty);
    for (final icon in actionIcons) {
      expect(icon.color, scheme.onSurface.withValues(alpha: 0.6));
    }

    final alignment = tester.widget<Transform>(
      find.byKey(const Key('conversation_header_actions_alignment')),
    );
    expect(
      alignment.transform.getTranslation().y,
      AppPlatform.isMacOS ? SidebarBreakpoints.macOSHeaderActionsVerticalOffset : 0,
    );
  });

  testWidgets('compact menu button reports pointer entry and exit', (tester) async {
    var enterCount = 0;
    var exitCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: 80,
              child: ConversationAppBar(
                sessionTitle: 'Conversation',
                isMobile: true,
                onMenuPressed: () {},
                onMenuHoverEnter: () => enterCount += 1,
                onMenuHoverExit: () => exitCount += 1,
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(400, 400));
    await gesture.moveTo(
      tester.getCenter(
        find.byKey(const Key('conversation_menu_hover_region')),
      ),
    );
    await tester.pump();
    expect(enterCount, 1);
    expect(exitCount, 0);

    await gesture.moveTo(const Offset(400, 400));
    await tester.pump();
    expect(exitCount, 1);
    await gesture.removePointer();
  });

  testWidgets('app bar applies RTL text direction for Arabic titles in desktop layout', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConversationAppBar(
            sessionTitle: 'محادثة جديدة',
            workspace: DeviceWorkspace(
              id: 'workspace-1',
              name: 'مساحة العمل',
              path: '/workspace',
            ),
          ),
        ),
      ),
    );

    final workspaceText = tester.widget<Text>(find.text('مساحة العمل'));
    expect(workspaceText.textDirection, TextDirection.rtl);

    final titleText = tester.widget<Text>(find.text('محادثة جديدة'));
    expect(titleText.textDirection, TextDirection.rtl);
  });

  testWidgets('app bar applies RTL text direction and alignments in mobile layout', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConversationAppBar(
            sessionTitle: 'محادثة جديدة',
            isMobile: true,
            workspace: DeviceWorkspace(
              id: 'workspace-1',
              name: 'مساحة العمل',
              path: '/workspace',
            ),
          ),
        ),
      ),
    );

    final titleText = tester.widget<Text>(find.text('محادثة جديدة'));
    expect(titleText.textDirection, TextDirection.rtl);
    expect(titleText.textAlign, TextAlign.right);

    final workspaceText = tester.widget<Text>(find.text('مساحة العمل'));
    expect(workspaceText.textDirection, TextDirection.rtl);
    expect(workspaceText.textAlign, TextAlign.right);

    final column = tester.widget<Column>(find.byType(Column));
    expect(column.crossAxisAlignment, CrossAxisAlignment.end);
  });

  testWidgets('mobile app bar renders default Conversation title and menu button when sessionTitle is null', (
    tester,
  ) async {
    bool menuPressed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationAppBar(
            sessionTitle: null,
            isMobile: true,
            onMenuPressed: () {
              menuPressed = true;
            },
          ),
        ),
      ),
    );

    expect(find.text('Conversation'), findsOneWidget);
    expect(find.byTooltip('Open navigation menu'), findsOneWidget);

    await tester.tap(find.byTooltip('Open navigation menu'));
    expect(menuPressed, isTrue);
  });
}

