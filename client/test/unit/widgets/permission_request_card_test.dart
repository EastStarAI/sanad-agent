import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/permission_request_card.dart';

void main() {
  testWidgets('uses action-neutral copy for external file permission', (
    tester,
  ) async {
    const externalPath = '/external/project/file.txt';
    const request = DeviceSuspendedRequest(
      requestId: 'permission-1',
      sessionId: 'session-1',
      toolName: 'file_write',
      permissionClass: 'external_workspace_path',
      scope: 'once',
      workspaceId: 'workspace-1',
      workspaceName: 'workspace',
      workspacePath: '/workspace',
      toolInput: {'action': 'file_write', 'path': externalPath},
      tool: {'name': 'file_write'},
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: PermissionRequestCard(
            request: request,
            borderColor: Colors.grey,
          ),
        ),
      ),
    );

    expect(find.text('Allow this tool action?'), findsOneWidget);
    expect(find.textContaining(externalPath), findsOneWidget);
    expect(find.text('Allow running this command?'), findsNothing);
  });
}
