import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/secrets/user_secret_vault.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/system/secret_tools.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';

import '../interactive_user_input.dart';

/// Plan 84 secret tools, offered only on a turn with daemon-stamped owner
/// authority. Every authenticated client (local or cloud) is the owner.
///
/// The owner gate stays inside this builder so the catalog cannot add the tools
/// on a turn that never proved owner authority.
List<BaseTool> buildSecretTools({
  required AgentTurnRequest request,
  required InteractiveUserInput userInput,
  required UserSecretVault? userSecrets,
  required PermissionManager permissionManager,
}) {
  final authority = CommandAuthority.fromStamped(
    request.metadata[CommandAuthority.payloadKey],
  );
  if (!authority.isOwner) return const [];
  return [
    RequestSecretTool(userInput: userInput, userSecrets: userSecrets),
    ListSecretsTool(userSecrets: userSecrets),
    DeleteSecretTool(
      permissionManager: permissionManager,
      userSecrets: userSecrets,
    ),
  ];
}
