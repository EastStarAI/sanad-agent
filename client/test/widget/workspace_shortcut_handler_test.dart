import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/core/navigation/navigation_history_controller.dart';
import 'package:sanad_client/features/home/presentation/widgets/workspace_shortcut_handler.dart';

void main() {
  testWidgets('handles mouse back and forward hardware buttons', (tester) async {
    final controller = ConversationHistoryController();
    controller.navigateTo(const ConversationDestination.newConversation(deviceId: 'd1'));
    controller.navigateTo(const ConversationDestination.newConversation(deviceId: 'd2'));

    ConversationDestination? navigatedTo;
    bool sidebarToggled = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceShortcutHandler(
            historyController: controller,
            onToggleSidebar: () => sidebarToggled = true,
            onNavigate: (dest) => navigatedTo = dest,
            child: const Center(child: Text('Workspace')),
          ),
        ),
      ),
    );

    expect(controller.snapshot.canGoBack, isTrue);

    // Simulate mouse button 4 (kBackMouseButton)
    final center = tester.getCenter(find.text('Workspace'));
    final gesture = await tester.startGesture(center, buttons: kBackMouseButton, kind: PointerDeviceKind.mouse);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(navigatedTo, isNotNull);
    expect(controller.snapshot.canGoForward, isTrue);

    // Simulate mouse button 5 (kForwardMouseButton)
    final gestureForward = await tester.startGesture(center, buttons: kForwardMouseButton, kind: PointerDeviceKind.mouse);
    await gestureForward.up();
    await tester.pumpAndSettle();

    expect(navigatedTo, isNotNull);
    expect(sidebarToggled, isFalse);

    controller.dispose();
  });
}
