import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_socket.dart';

void main() {
  test('store starts empty without hardcoded capabilities', () async {
    final socket = FakeSanadSocketService();
    socket.setConnected(true);
    final resolver = createTestResolver(cloudSocket: socket, localSocket: socket);
    final capabilities = DeviceCapabilitiesStore(resolver);

    expect(capabilities.capabilitiesByAgentId, isEmpty);
    expect(capabilities.getForAgent('agent-a'), const Capability());
    expect(capabilities.getForAgent('agent-b'), const Capability());

    capabilities.dispose();
    resolver.dispose();
    socket.dispose();
  });

  test('does not cache a correlated null response before a device is online', () async {
    final cloudSocket = FakeSanadSocketService()..setConnected(true);
    final localSocket = FakeSanadSocketService()..setConnected(true);
    final resolver = createTestResolver(
      cloudSocket: cloudSocket,
      localSocket: localSocket,
    );
    final capabilities = DeviceCapabilitiesStore(resolver);
    final remoteAgent = DeviceConfig(
      id: 'newly-paired-device',
      name: 'Remote',
      isOnline: false,
    );

    cloudSocket.autoCapabilitiesPayload = null;
    final beforeOnline = await capabilities.ensureFreshForAgent(remoteAgent);

    expect(beforeOnline, const Capability());
    expect(capabilities.capabilitiesByAgentId, isNot(contains(remoteAgent.id)));

    cloudSocket.autoCapabilitiesPayload = const {
      'supports_model_change': true,
      'supports_thinking_mode_change': true,
    };
    final afterOnline = await capabilities.ensureFreshForAgent(
      remoteAgent.copyWith(isOnline: true),
    );

    expect(afterOnline.supportsModelChange, isTrue);
    expect(afterOnline.supportsThinkingModeChange, isTrue);
    expect(capabilities.capabilitiesByAgentId, contains(remoteAgent.id));
    expect(
      cloudSocket.capturedCommands.where((command) => command['event'] == 'get_capabilities'),
      hasLength(2),
    );

    capabilities.dispose();
    resolver.dispose();
    cloudSocket.dispose();
    localSocket.dispose();
  });

  test('stores capabilities per agent id without overwriting siblings', () async {
    final cloudSocket = FakeSanadSocketService()..setConnected(true);
    final localSocket = FakeSanadSocketService()..setConnected(true);
    final resolver = createTestResolver(
      cloudSocket: cloudSocket,
      localSocket: localSocket,
      currentDeviceId: 'device-local',
    );
    final capabilities = DeviceCapabilitiesStore(resolver);

    final localAgent = DeviceConfig(id: 'agent-local', name: 'Local', hardwareId: 'device-local', isOnline: true);
    final remoteAgent = DeviceConfig(id: 'agent-remote', name: 'Remote', hardwareId: 'device-remote', isOnline: true);

    localSocket.autoCapabilitiesPayload = const {
      'supports_stop': true,
      'thinking_stream_mode': 'delta',
    };

    final localCaps = await capabilities.ensureFreshForAgent(localAgent, force: true);

    cloudSocket.autoCapabilitiesPayload = const {
      'supports_delete_session': true,
      'thinking_stream_mode': 'snapshot',
    };

    final remoteCaps = await capabilities.ensureFreshForAgent(remoteAgent, force: true);

    expect(localCaps.thinkingStreamMode, ThinkingStreamMode.delta);
    expect(remoteCaps.thinkingStreamMode, ThinkingStreamMode.snapshot);
    expect(capabilities.getForAgent('agent-local').supportsStop, isTrue);
    expect(capabilities.getForAgent('agent-remote').supportsDeleteSession, isTrue);

    capabilities.dispose();
    resolver.dispose();
    cloudSocket.dispose();
    localSocket.dispose();
  });

  test('capability equality includes list content', () {
    const first = Capability(
      supportsStop: true,
      thinkingModesList: ['fast', 'deep'],
      slashCommandsList: [SlashCommand(command: 'help', description: 'Help')],
    );
    const same = Capability(
      supportsStop: true,
      thinkingModesList: ['fast', 'deep'],
      slashCommandsList: [SlashCommand(command: 'help', description: 'Help')],
    );
    const changed = Capability(
      supportsStop: true,
      thinkingModesList: ['fast', 'balanced'],
      slashCommandsList: [SlashCommand(command: 'help', description: 'Help')],
    );

    expect(first, same);
    expect(first, isNot(changed));
  });

  test('capability parses thinking_stream_mode from JSON', () {
    final capability = Capability.fromJson({
      'supports_stop': true,
      'thinking_stream_mode': 'snapshot',
    });

    expect(capability.supportsStop, isTrue);
    expect(capability.thinkingStreamMode, ThinkingStreamMode.snapshot);
  });

  test('capability parses tools v2 workspace and permission fields from JSON', () {
    final capability = Capability.fromJson({
      'supports_workspaces': true,
      'workspace_required': true,
      'workspace_scope': 'session',
      'supports_workspace_selection': true,
      'supports_local_tool_runtime': true,
      'supports_tool_permissions': true,
      'supports_tool_approvals': true,
      'permission_modes': ['default', 'full_access'],
      'permission_categories': ['workspace_write', 'network', 'shell'],
      'approval_scopes': ['once', 'command', 'session', 'workspace'],
      'local_tool_runtime_scope': 'workspace',
      'tool_protocol_version': 'tools.v2',
    });

    expect(capability.supportsWorkspaces, isTrue);
    expect(capability.workspaceRequired, isTrue);
    expect(capability.workspaceScope, WorkspaceScope.session);
    expect(capability.supportsWorkspaceSelection, isTrue);
    expect(capability.supportsLocalToolRuntime, isTrue);
    expect(capability.supportsToolPermissions, isTrue);
    expect(capability.supportsToolApprovals, isTrue);
    expect(capability.permissionModes, ['default', 'full_access']);
    expect(capability.permissionCategories, ['workspace_write', 'network', 'shell']);
    expect(capability.approvalScopes, ['once', 'command', 'session', 'workspace']);
    expect(capability.localToolRuntimeScope, LocalToolRuntimeScope.workspace);
    expect(capability.toolProtocolVersion, 'tools.v2');
  });
}
