import 'package:sanad_client/features/devices/data/device_command_client.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';

/// Reads and changes the Agent-owned security policy of one workspace.
///
/// The Agent decides what this connection may change; the Client never
/// stores the policy or retries a rejected mutation on its own.
class WorkspaceSecurityClient {
  WorkspaceSecurityClient(this._commands);

  final DeviceCommandClient _commands;

  Future<WorkspacePolicy> read(DeviceConfig device, String workspaceId) async {
    final payload = await _commands.request(
      device: device,
      command: 'workspace.get_policy',
      expectedEvent: 'workspace.get_policy',
      payload: {'workspace_id': workspaceId},
    );
    return WorkspacePolicy.fromJson(payload);
  }

  /// Policy changes for [workspaceId] made by any client or the CLI
  /// (`workspace.policy_changed`). The broadcast carries no `canWiden`.
  Stream<WorkspacePolicy> watch(DeviceConfig device, String workspaceId) =>
      _commands
          .events(device)
          .where((event) {
            if (event['event'] != 'workspace.policy_changed') return false;
            final payload = event['payload'];
            return payload is Map && payload['workspace_id'] == workspaceId;
          })
          .map((event) {
            final payload = Map<String, dynamic>.from(event['payload'] as Map);
            final policy = payload['policy'];
            return WorkspacePolicy.fromJson(
              policy is Map ? Map<String, dynamic>.from(policy) : payload,
            );
          });

  /// Sends only the changed axes with the revision the user saw (omitted only
  /// when no policy has been read yet).
  Future<WorkspacePolicy> update(
    DeviceConfig device,
    String workspaceId, {
    int? expectedRevision,
    WorkspacePermissionMode? permissionMode,
    WorkspaceExecutionMode? executionMode,
    WorkspaceHostDiscoveryPolicy? hostDiscoveryPolicy,
  }) async {
    final payload = await _commands.request(
      device: device,
      command: 'workspace.set_permission_mode',
      expectedEvent: 'workspace.set_permission_mode',
      payload: {
        'workspace_id': workspaceId,
        'expected_revision': ?expectedRevision,
        'permission_mode': ?permissionMode?.value,
        'execution_mode': ?executionMode?.value,
        'host_discovery_policy': ?hostDiscoveryPolicy?.value,
      },
    );
    return WorkspacePolicy.fromJson(payload);
  }
}
