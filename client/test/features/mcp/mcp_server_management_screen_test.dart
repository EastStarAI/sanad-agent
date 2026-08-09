import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/mcp/data/mcp_runtime_client.dart';
import 'package:sanad_client/features/mcp/presentation/screens/mcp_server_management_screen.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_tool_runtime_context.dart';

import '../../mocks/mock_socket_service.dart';

void main() {
  late _McpManagementSocket localSocket;
  late FakeSanadSocketService cloudSocket;
  late DeviceConnectionCoordinator coordinator;
  late McpRuntimeClient client;
  late DeviceConfig device;
  String? copiedText;

  setUp(() async {
    copiedText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text']?.toString();
        }
        return null;
      },
    );
    await getIt.reset();
    getIt.registerSingleton<WorkspaceToolRuntimeContext>(
      WorkspaceToolRuntimeContext(),
    );
    localSocket = _McpManagementSocket()..setConnected(true);
    cloudSocket = FakeSanadSocketService();
    coordinator = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: localSocket,
      currentDeviceId: 'device-1',
    );
    device = DeviceConfig(
      id: 'agent-1',
      name: 'Test device',
      hardwareId: 'device-1',
      isOnline: true,
    );
    client = McpRuntimeClient(connectionCoordinator: coordinator);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
    await getIt.reset();
    coordinator.dispose();
    cloudSocket.dispose();
    localSocket.dispose();
  });

  Future<void> pumpManagement(
    WidgetTester tester, {
    Size size = const Size(900, 800),
    bool workspace = false,
    bool embedded = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      Provider<McpRuntimeClient>.value(
        value: client,
        child: MaterialApp(
          home: embedded
              ? Scaffold(
                  body: McpServerManagementScreen(
                    device: device,
                    workspaceId: workspace ? '/workspace' : null,
                    workspaceName: workspace ? 'Project Alpha' : null,
                    embedded: true,
                  ),
                )
              : McpServerManagementScreen(
                  device: device,
                  workspaceId: workspace ? '/workspace' : null,
                  workspaceName: workspace ? 'Project Alpha' : null,
                ),
        ),
      ),
    );
    await _pumpFrames(tester);
  }

  Future<void> expandServer(WidgetTester tester) async {
    await tester.tap(find.text('demo-server'));
    await _pumpFrames(tester);
  }

  Future<void> chooseAdvancedAction(
    WidgetTester tester,
    String action,
  ) async {
    await tester.tap(find.byTooltip('Advanced actions'));
    await _pumpFrames(tester);
    await tester.tap(find.text(action));
    await _pumpFrames(tester);
  }

  testWidgets('embedded Settings view exposes the Add server action', (
    tester,
  ) async {
    await pumpManagement(tester, embedded: true);

    final addButton = find.byKey(const ValueKey('add-mcp-server'));
    expect(addButton, findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Add server'), findsOneWidget);
    expect(tester.widget<FilledButton>(addButton).onPressed, isNotNull);
  });

  testWidgets('exports one redacted server and confirms credentials exclusion', (
    tester,
  ) async {
    await pumpManagement(tester);
    await expandServer(tester);
    await chooseAdvancedAction(tester, 'Export JSON');

    final command = localSocket.commandsNamed('export_mcp_servers').single;
    final payload = command['payload'] as Map<String, dynamic>;
    expect(payload['server_names'], ['demo-server']);
    expect(payload['scope'], 'global');
    expect(
      copiedText,
      '{"mcpServers":{"demo-server":{"url":"https://example.test/mcp"}}}',
    );
    expect(
      find.text('Copied redacted JSON. Credentials were excluded.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('Advanced JSON requires preview before scoped save', (
    tester,
  ) async {
    await pumpManagement(tester);
    await expandServer(tester);
    await chooseAdvancedAction(tester, 'Edit JSON');

    expect(find.text('Advanced JSON · demo-server'), findsOneWidget);
    expect(
      find.text('Credentials are excluded. Preview is required before Save.'),
      findsOneWidget,
    );
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save')).onPressed,
      isNull,
    );

    await tester.tap(find.text('Preview changes'));
    await _pumpFrames(tester);

    expect(find.text('1 fields changed'), findsOneWidget);
    expect(find.text('• description'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save')).onPressed,
      isNotNull,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await _pumpFrames(tester);

    final command = localSocket.commandsNamed('save_advanced_mcp_server').single;
    final payload = command['payload'] as Map<String, dynamic>;
    expect(payload['server_name'], 'demo-server');
    expect(payload['scope'], 'global');
    expect(payload['base_revision'], 'base-1');
    expect(payload['preview_revision'], 'preview-1');
    expect(find.text('Advanced JSON · demo-server'), findsNothing);
  });

  testWidgets('tool selection persists daemon-authoritative disabled tools', (
    tester,
  ) async {
    await pumpManagement(tester);
    await expandServer(tester);

    expect(find.text('search'), findsOneWidget);
    expect(find.text('Search indexed documents'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Disable tool search'));
    await _pumpFrames(tester);

    final command = localSocket.commandsNamed('save_mcp_server').single;
    final payload = command['payload'] as Map<String, dynamic>;
    final config = payload['config'] as Map<String, dynamic>;
    expect(config['disabledTools'], ['search']);
  });

  testWidgets('effective cards expose workspace origin and precedence', (
    tester,
  ) async {
    await pumpManagement(tester, workspace: true);
    await tester.tap(find.text('Effective'));
    await _pumpFrames(tester);

    expect(find.text('Workspace'), findsOneWidget);
    expect(
      find.textContaining(
        'Workspace definitions override same-name device servers',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('demo-server.'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch).first).onChanged, isNull);
  });

  testWidgets('compact card wraps actions without overflow', (tester) async {
    await pumpManagement(tester, size: const Size(320, 700));
    await expandServer(tester);
    await tester.scrollUntilVisible(
      find.text('Remove'),
      120,
      scrollable: find.byType(Scrollable).last,
    );
    await _pumpFrames(tester);

    expect(find.text('Test'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('card, expansion, server toggle, and tools expose semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpManagement(tester);

    expect(
      find.bySemanticsLabel('demo-server, Enabled, 1 tools'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Expand demo-server details'),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(find.byType(Switch).first).label,
      contains('Disable demo-server'),
    );

    await expandServer(tester);

    expect(
      find.bySemanticsLabel('Collapse demo-server details'),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(find.byType(Switch).last).label,
      contains('Disable tool search'),
    );
    semantics.dispose();
  });
}

Future<void> _pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

class _McpManagementSocket extends FakeSanadSocketService {
  List<Map<String, dynamic>> commandsNamed(String command) =>
      capturedCommands.where((entry) => entry['command'] == command).toList(growable: false);

  @override
  void sendDeviceCommand({
    required String deviceId,
    required String command,
    Map<String, dynamic>? payload,
  }) {
    super.sendDeviceCommand(
      deviceId: deviceId,
      command: command,
      payload: payload,
    );
    final request = payload ?? const <String, dynamic>{};
    unawaited(
      Future<void>.microtask(() {
        debugEmitEvent({
          'type': 'device_event',
          'event': _eventFor(command),
          'payload': {
            'request_id': request['request_id'],
            ..._responseFor(command, request),
          },
        });
      }),
    );
  }

  String _eventFor(String command) => switch (command) {
    'list_mcp_servers' => 'mcp_servers_list',
    'inspect_mcp_server' => 'mcp_server_inspected',
    'save_mcp_server' => 'mcp_server_saved',
    'export_mcp_servers' => 'mcp_servers_exported',
    'read_advanced_mcp_server' => 'mcp_advanced_read',
    'preview_advanced_mcp_server' => 'mcp_advanced_previewed',
    'save_advanced_mcp_server' => 'mcp_advanced_saved',
    _ => throw StateError('Unexpected MCP command: $command'),
  };

  Map<String, dynamic> _responseFor(
    String command,
    Map<String, dynamic> request,
  ) {
    if (command == 'list_mcp_servers' || command == 'save_mcp_server' || command == 'save_advanced_mcp_server') {
      return _snapshotPayload(
        workspaceId: request['workspace_id']?.toString(),
      );
    }
    if (command == 'inspect_mcp_server') {
      return {
        'name': request['server_name'],
        'scope': request['scope'],
        if (request['workspace_id'] != null) 'workspace_id': request['workspace_id'],
        'success': true,
        'transport': 'streamableHttp',
        'auth_state': 'approved',
        'tools': [
          {
            'name': 'search',
            'description': 'Search indexed documents',
            'input_schema': <String, dynamic>{},
          },
        ],
      };
    }
    if (command == 'export_mcp_servers') {
      return {
        'json': '{"mcpServers":{"demo-server":{"url":"https://example.test/mcp"}}}',
        'credentials_excluded': true,
      };
    }
    if (command == 'read_advanced_mcp_server') {
      return {
        'server_name': 'demo-server',
        'json': '{"name":"demo-server","url":"https://example.test/mcp"}',
        'base_revision': 'base-1',
        'credentials_excluded': true,
      };
    }
    if (command == 'preview_advanced_mcp_server') {
      return {
        'servers': [
          {
            'name': 'demo-server',
            'config': {
              'name': 'demo-server',
              'url': 'https://example.test/mcp',
            },
          },
        ],
        'warnings': <String>[],
        'unsupported_fields': <String>[],
        'revision': 'preview-1',
        'diff': [
          {'field': 'description', 'before': null, 'after': 'Updated'},
        ],
      };
    }
    throw StateError('Unexpected MCP command: $command');
  }
}

Map<String, dynamic> _snapshotPayload({String? workspaceId}) {
  final deviceEntry = {
    'name': 'demo-server',
    'source': 'global',
    'config': {
      'id': 'device-server',
      'name': 'demo-server',
      'url': 'https://example.test/mcp',
      'authType': 'bearer',
      'bearerConfigured': true,
    },
  };
  final workspaceEntry = {
    'name': 'demo-server',
    'source': 'workspace',
    'workspace_id': '/workspace',
    'config': {
      'id': 'workspace-server',
      'name': 'demo-server',
      'url': 'https://workspace.example.test/mcp',
    },
  };
  return {
    if (workspaceId != null) 'workspace_id': workspaceId,
    'global': {
      'scope': 'global',
      'document': const {'mcpServers': <String, dynamic>{}},
      'servers': [deviceEntry],
    },
    'workspace': {
      'scope': 'workspace',
      'document': const {'mcpServers': <String, dynamic>{}},
      'servers': [workspaceEntry],
    },
    'effective': {
      'scope': 'effective',
      'document': const {'mcpServers': <String, dynamic>{}},
      'servers': [workspaceEntry],
    },
  };
}
