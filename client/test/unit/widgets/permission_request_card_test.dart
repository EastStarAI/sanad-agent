import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/permission_request_card.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/permission_request_presentation.dart';

void main() {
  group('PermissionRequestPresentation', () {
    test('formats shell execution as a labeled command', () {
      final presentation = PermissionRequestPresentation.fromRequest(
        request(toolName: 'shell_execute', toolInput: const {'command': 'pwd'}),
      );

      expect(presentation.title, 'Allow Sanad to run this command?');
      expect(presentation.details.single.label, isNull);
      expect(presentation.details.single.value, 'pwd');
    });

    test('formats external file reads without raw map syntax', () {
      final presentation = PermissionRequestPresentation.fromRequest(
        request(
          toolName: 'file_read',
          toolInput: const {
            'action': 'file_read',
            'path': '/external/project/file.txt',
          },
        ),
      );

      expect(presentation.title, 'Allow Sanad to read this file?');
      expect(presentation.details.single.label, isNull);
      expect(presentation.details.single.value, '/external/project/file.txt');
      expect(presentation.details.single.value, isNot(contains('{')));
    });

    test('classifies safe write and edit inputs without inventing content', () {
      final writePresentation = PermissionRequestPresentation.fromRequest(
        request(
          toolName: 'file_write',
          toolInput: const {
            'action': 'file_write',
            'path': '/external/output.txt',
          },
        ),
      );
      final editPresentation = PermissionRequestPresentation.fromRequest(
        request(
          toolName: 'file_edit',
          toolInput: const {
            'action': 'file_edit',
            'path': '/external/output.txt',
          },
        ),
      );

      expect(writePresentation.title, 'Allow Sanad to write to this file?');
      expect(editPresentation.title, 'Allow Sanad to edit this file?');
      expect(writePresentation.details.map((detail) => detail.label), [null]);
      expect(editPresentation.details.map((detail) => detail.label), [null]);
      expect(
        [...writePresentation.details, ...editPresentation.details].map((detail) => detail.value).join(),
        isNot(contains('content')),
      );
    });

    test('shows MCP server, tool, and readable nested inputs', () {
      final presentation = PermissionRequestPresentation.fromRequest(
        request(
          toolName: 'mcp__github__create_issue',
          toolInput: const {
            'title': 'Bug',
            'metadata': {'priority': 'high'},
            'labels': ['client', 'ux'],
          },
          tool: const {
            'display_name': 'create_issue',
            'server_name': 'github',
            'category': 'mcp',
            'source': {
              'type': 'mcp_server',
              'id': 'github',
              'original_name': 'create_issue',
            },
          },
        ),
      );

      expect(presentation.title, 'Allow Sanad to use this MCP tool?');
      expect(presentation.details[0].label, isNull);
      expect(presentation.details[0].value, 'github / create_issue');
      expect(
        presentation.details.singleWhere((detail) => detail.label == 'Metadata').value,
        'Priority: high',
      );
      expect(
        presentation.details.singleWhere((detail) => detail.label == 'Labels').value,
        '• client\n• ux',
      );
    });

    test('falls back to a generic title and humanized labels', () {
      final presentation = PermissionRequestPresentation.fromRequest(
        request(
          toolName: 'custom_tool',
          toolInput: const {'target_id': '42', 'dryRun': true},
          tool: const {'display_name': 'Custom Tool'},
        ),
      );

      expect(presentation.title, 'Allow Sanad to use this tool?');
      expect(presentation.details[0].label, isNull);
      expect(presentation.details[0].value, 'Custom Tool');
      expect(presentation.details[1].label, 'Target id');
      expect(presentation.details[2].label, 'Dry Run');
    });
  });

  testWidgets('renders an action-specific title and labeled path', (
    tester,
  ) async {
    final externalRead = request(
      toolName: 'file_read',
      toolInput: const {
        'action': 'file_read',
        'path': '/external/project/file.txt',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PermissionRequestCard(
            request: externalRead,
            borderColor: Colors.grey,
          ),
        ),
      ),
    );

    expect(find.text('Allow Sanad to read this file?'), findsOneWidget);
    expect(find.textContaining('Path: '), findsNothing);
    expect(find.textContaining('/external/project/file.txt'), findsOneWidget);
    expect(find.textContaining('{action:'), findsNothing);
  });
}

DeviceSuspendedRequest request({
  required String toolName,
  required Map<String, dynamic> toolInput,
  Map<String, dynamic>? tool,
}) {
  return DeviceSuspendedRequest(
    requestId: 'permission-1',
    sessionId: 'session-1',
    toolName: toolName,
    permissionClass: 'test',
    scope: 'once',
    workspaceId: 'workspace-1',
    workspaceName: 'workspace',
    workspacePath: '/workspace',
    toolInput: toolInput,
    tool: tool ?? {'name': toolName},
  );
}
