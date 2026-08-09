import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/mcp/data/mcp_runtime_client.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_server_config.dart';
import 'package:sanad_client/features/mcp/presentation/screens/add_mcp_server_screen.dart';

import '../../mocks/mock_socket_service.dart';

void main() {
  late FakeSanadSocketService socket;
  late FakeSanadSocketService cloudSocket;
  late DeviceConnectionCoordinator coordinator;
  late McpRuntimeClient client;
  late DeviceConfig device;

  setUp(() {
    socket = FakeSanadSocketService()..setConnected(true);
    cloudSocket = FakeSanadSocketService();
    coordinator = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: socket,
      currentDeviceId: 'device-1',
    );
    device = DeviceConfig(
      id: 'agent-1',
      name: 'Test device',
      hardwareId: 'device-1',
      isOnline: true,
    );
    client = McpRuntimeClient(
      connectionCoordinator: coordinator,
      defaultDevice: () => device,
    );
  });

  tearDown(() {
    coordinator.dispose();
    cloudSocket.dispose();
    socket.dispose();
  });

  Future<void> pumpForm(
    WidgetTester tester, {
    McpServerConfig? initialConfig,
  }) async {
    await tester.pumpWidget(
      Provider<McpRuntimeClient>.value(
        value: client,
        child: MaterialApp(
          home: AddMcpServerScreen(
            device: device,
            initialConfig: initialConfig,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('branches between remote and structured local command fields', (
    tester,
  ) async {
    await pumpForm(tester);

    expect(find.text('Server URL'), findsOneWidget);
    expect(find.text('Authentication'), findsOneWidget);
    expect(find.text('Command'), findsNothing);
    expect(find.text('Import'), findsOneWidget);

    await tester.tap(find.text('Local command'));
    await tester.pumpAndSettle();

    expect(find.text('Server URL'), findsNothing);
    expect(find.text('Command'), findsOneWidget);
    expect(find.text('Arguments'), findsOneWidget);
    expect(find.text('Add argument'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Environment variables'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Environment variables'), findsOneWidget);
    expect(find.text('Add variable'), findsOneWidget);
  });

  testWidgets('edit projects configured secrets without exposing values', (
    tester,
  ) async {
    await pumpForm(
      tester,
      initialConfig: McpServerConfig(
        name: 'secure',
        serverUrl: 'https://example.test/mcp',
        authType: McpAuthType.bearer,
        bearerConfigured: true,
      ),
    );

    expect(find.text('Edit MCP server'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Bearer token configured'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Bearer token configured'), findsOneWidget);
    expect(find.text('Replace bearer token'), findsOneWidget);
    expect(find.textContaining('secret-value'), findsNothing);
    expect(find.text('Remove'), findsOneWidget);
  });

  testWidgets('import is secondary and requires preview before draft use', (
    tester,
  ) async {
    await pumpForm(tester);

    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(find.text('Import configuration'), findsOneWidget);
    expect(find.text('Preview'), findsOneWidget);
    final useDraft = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Use draft'),
    );
    expect(useDraft.onPressed, isNull);
  });
}
