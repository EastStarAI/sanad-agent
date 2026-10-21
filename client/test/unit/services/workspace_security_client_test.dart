import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/data/device_command_client.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/settings/data/workspace_security_client.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';

class _RecordingCommands implements DeviceCommandClient {
  final requests = <Map<String, Object?>>[];
  final broadcasts = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> events(DeviceConfig device) => broadcasts.stream;
  Map<String, dynamic> response = const {};

  @override
  Future<Map<String, dynamic>> request({
    required DeviceConfig device,
    required String command,
    required String expectedEvent,
    Set<String>? acceptedEvents,
    Map<String, dynamic> payload = const {},
    Duration timeout = const Duration(seconds: 10),
    bool Function(Map<String, dynamic> payload)? payloadMatches,
  }) async {
    requests.add({'command': command, 'expected': expectedEvent, ...payload});
    return response;
  }
}

void main() {
  final device = DeviceConfig(id: 'device-1', name: 'Laptop', isOnline: true);

  test('update sends only the changed axis and the seen revision', () async {
    final commands = _RecordingCommands()
      ..response = {
        'executionMode': 'protected',
        'hostDiscoveryPolicy': 'owner_only',
        'permissionMode': 'default',
        'revision': 4,
        'canWiden': false,
      };
    final policy = await WorkspaceSecurityClient(commands).update(
      device,
      'ws-1',
      expectedRevision: 3,
      executionMode: WorkspaceExecutionMode.protected,
    );
    expect(commands.requests.single, {
      'command': 'workspace.set_permission_mode',
      'expected': 'workspace.set_permission_mode',
      'workspace_id': 'ws-1',
      'expected_revision': 3,
      'execution_mode': 'protected',
    });
    expect(policy.executionMode, WorkspaceExecutionMode.protected);
    expect(policy.revision, 4);
    expect(policy.canWiden, isFalse);
  });

  test('read queries by workspace id', () async {
    final commands = _RecordingCommands();
    await WorkspaceSecurityClient(commands).read(device, 'ws-1');
    expect(commands.requests.single['command'], 'workspace.get_policy');
    expect(commands.requests.single['workspace_id'], 'ws-1');
  });

  test('unknown policy values parse to the restrictive posture', () {
    final policy = WorkspacePolicy.fromJson({
      'executionMode': 'host',
      'hostDiscoveryPolicy': 'everyone',
      'canWiden': 'true',
    });
    expect(policy.executionMode, WorkspaceExecutionMode.protected);
    expect(policy.hostDiscoveryPolicy, WorkspaceHostDiscoveryPolicy.disabled);
    expect(policy.canWiden, isFalse);
    final legacy = WorkspacePolicy.fromJson({'permissionMode': 'full_access'});
    expect(legacy.executionMode, WorkspaceExecutionMode.direct);
    expect(legacy.hostDiscoveryPolicy, WorkspaceHostDiscoveryPolicy.ownerOnly);
  });

  test('watch follows policy_changed for this workspace only', () async {
    final commands = _RecordingCommands();
    final seen = <WorkspacePolicy>[];
    final sub = WorkspaceSecurityClient(commands).watch(device, 'ws-1').listen(seen.add);
    commands.broadcasts
      ..add({'event': 'workspace.policy_changed', 'payload': {'workspace_id': 'ws-2', 'policy': {'executionMode': 'protected'}}})
      ..add({'event': 'workspace.policy_changed', 'payload': {'workspace_id': 'ws-1', 'policy': {'executionMode': 'protected', 'permissionMode': 'full_access', 'revision': 7}}})
      ..add({'event': 'other', 'payload': {'workspace_id': 'ws-1'}});
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(seen, hasLength(1));
    expect(seen.single.executionMode, WorkspaceExecutionMode.protected);
    expect(seen.single.permissionMode, WorkspacePermissionMode.fullAccess);
    expect(seen.single.revision, 7);
  });
}
