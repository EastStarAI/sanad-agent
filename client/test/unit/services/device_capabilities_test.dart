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

  test('capability parses model-scoped thinking source', () {
    final capability = Capability.fromJson({
      'supports_thinking_mode_change': true,
      'thinking_mode_source': 'model',
      'thinking_modes_list': ['fast', 'balanced', 'deep'],
    });

    expect(capability.usesModelThinkingControls, isTrue);
    expect(capability.thinkingModesList, isEmpty);
  });

  test('legacy capability payload keeps device thinking list', () {
    final capability = Capability.fromJson({
      'thinking_modes_list': ['fast', 'balanced', 'deep'],
    });

    expect(capability.usesModelThinkingControls, isFalse);
    expect(capability.thinkingModesList, ['fast', 'balanced', 'deep']);
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
