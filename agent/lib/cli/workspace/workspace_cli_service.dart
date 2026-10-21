import 'dart:async';

import 'package:logging/logging.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';

import '../client/local_gateway_cli_client.dart';
import '../discovery/local_gateway_discovery.dart';
import '../fallback/standalone_fallback_strategy.dart';
import 'cli_workspace_state.dart';
import 'workspace_locator.dart';

/// Unified workspace service combining Local Gateway client connection with
/// in-process LocalWorkspaceRuntimeService fallback for offline/standalone execution.
class WorkspaceCliService {
  final LocalGatewayCliClient? gatewayClient;
  final LocalWorkspaceRuntimeService runtimeService;
  final WorkspacePolicyStore? _policyStoreOverride;

  /// Daemon-equivalent policy owner used when no Gateway is connected.
  late final WorkspacePolicyStore policyStore =
      _policyStoreOverride ?? _standalonePolicyStore(runtimeService);
  final CliWorkspaceStateStore stateStore;
  final String sanadHome;
  final bool isGatewayMode;

  final _logger = Logger('WorkspaceCliService');

  WorkspaceCliService({
    this.gatewayClient,
    LocalWorkspaceRuntimeService? runtimeService,
    WorkspacePolicyStore? policyStore,
    CliWorkspaceStateStore? stateStore,
    String? sanadHome,
    bool? isGatewayMode,
  }) : sanadHome =
           sanadHome ?? const LocalGatewayDiscovery().resolveSanadHome(),
       runtimeService =
           runtimeService ??
           LocalWorkspaceRuntimeService(
             sanadHomePath:
                 sanadHome ?? const LocalGatewayDiscovery().resolveSanadHome(),
           ),
       _policyStoreOverride = policyStore,
       stateStore =
           stateStore ??
           CliWorkspaceStateStore(
             sanadHomeOverride:
                 sanadHome ?? const LocalGatewayDiscovery().resolveSanadHome(),
           ),
       isGatewayMode =
           isGatewayMode ??
           (gatewayClient != null && gatewayClient.isConnected);

  static WorkspacePolicyStore _standalonePolicyStore(
    LocalWorkspaceRuntimeService runtimeService,
  ) => WorkspacePolicyStore(
    database: () => runtimeService.stateDatabase,
    resolveRegisteredPath: (id) async {
      final workspace = await runtimeService.describeWorkspaceById(id);
      if (workspace == null || workspace['is_missing'] == true) return null;
      return workspace['path']?.toString();
    },
  );

  WorkspaceLocator get locator => WorkspaceLocator(
    gatewayClient: gatewayClient,
    runtimeService: runtimeService,
    stateStore: stateStore,
  );

  /// Creates a [WorkspaceCliService] resolving runtime mode via discovery.
  static Future<WorkspaceCliService> create({
    bool forceStandalone = false,
    String? gatewayUrl,
    String? sanadHome,
    LocalGatewayCliClient? clientOverride,
    LocalWorkspaceRuntimeService? runtimeOverride,
    WorkspacePolicyStore? policyStoreOverride,
    CliWorkspaceStateStore? stateStoreOverride,
  }) async {
    final effectiveHome =
        sanadHome ?? const LocalGatewayDiscovery().resolveSanadHome();

    if (clientOverride != null) {
      return WorkspaceCliService(
        gatewayClient: clientOverride,
        runtimeService: runtimeOverride,
        policyStore: policyStoreOverride,
        stateStore: stateStoreOverride,
        sanadHome: effectiveHome,
        isGatewayMode: clientOverride.isConnected,
      );
    }

    if (forceStandalone) {
      return WorkspaceCliService(
        gatewayClient: null,
        runtimeService: runtimeOverride,
        policyStore: policyStoreOverride,
        stateStore: stateStoreOverride,
        sanadHome: effectiveHome,
        isGatewayMode: false,
      );
    }

    try {
      final strategy = StandaloneFallbackStrategy();
      final mode = await strategy.resolveMode(
        forceStandalone: forceStandalone,
        urlOverride: gatewayUrl,
      );

      if (mode == CliRuntimeMode.gateway) {
        final client = await LocalGatewayCliClient.discoverAndConnect(
          urlOverride: gatewayUrl,
          sanadHomeOverride: effectiveHome,
        );
        return WorkspaceCliService(
          gatewayClient: client,
          runtimeService: runtimeOverride,
          policyStore: policyStoreOverride,
          stateStore: stateStoreOverride,
          sanadHome: effectiveHome,
          isGatewayMode: true,
        );
      }
    } catch (_) {}

    return WorkspaceCliService(
      gatewayClient: null,
      runtimeService: runtimeOverride,
      policyStore: policyStoreOverride,
      stateStore: stateStoreOverride,
      sanadHome: effectiveHome,
      isGatewayMode: false,
    );
  }

  /// Lists all registered workspaces.
  Future<List<Map<String, dynamic>>> listWorkspaces() async {
    if (gatewayClient != null && gatewayClient!.isConnected) {
      try {
        return await gatewayClient!.listWorkspaces();
      } catch (e) {
        _logger.warning(
          'Failed to list workspaces via gateway: $e; using runtime service',
        );
      }
    }
    return await runtimeService.listWorkspaces();
  }

  /// Creates a new workspace or registers an existing folder.
  Future<Map<String, dynamic>> createWorkspace({
    required String name,
    String? path,
    String? description,
  }) async {
    if (gatewayClient != null && gatewayClient!.isConnected) {
      try {
        return await gatewayClient!.createWorkspace(
          name: name,
          path: path,
          description: description,
        );
      } catch (e) {
        _logger.warning(
          'Failed to create workspace via gateway: $e; using runtime service',
        );
      }
    }
    return await runtimeService.createWorkspace(
      name: name,
      path: path,
      description: description,
    );
  }

  /// Browses the tree structure of a workspace.
  Future<Map<String, dynamic>> browseWorkspaceTree({
    String? workspaceId,
    String? path,
    int maxEntries = 200,
  }) async {
    if (gatewayClient != null && gatewayClient!.isConnected) {
      try {
        return await gatewayClient!.browseWorkspaceTree(
          workspaceId: workspaceId,
          path: path,
          maxEntries: maxEntries,
        );
      } catch (e) {
        _logger.warning(
          'Failed to browse tree via gateway: $e; using runtime service',
        );
      }
    }
    return await runtimeService.browseWorkspaceTree(
      workspaceId: workspaceId,
      path: path,
      maxEntries: maxEntries,
    );
  }

  /// Reads the workspace security policy.
  ///
  /// The running daemon is authoritative; the local store is consulted only
  /// when no Gateway is connected.
  Future<WorkspacePolicy> getWorkspacePolicy(String workspacePath) async {
    if (gatewayClient != null && gatewayClient!.isConnected) {
      final raw = await gatewayClient!.getWorkspacePolicy(
        workspacePath: workspacePath,
      );
      return WorkspacePolicy.fromJson(raw);
    }
    final workspace = await runtimeService.describeWorkspace(workspacePath);
    return policyStore.readPolicy(workspace?['id']?.toString());
  }

  /// Updates the security permission mode (`default` or `full_access`).
  ///
  /// A Gateway rejection is final and never falls back to a local write.
  Future<void> setWorkspacePermissionMode({
    required String workspaceId,
    required String workspacePath,
    required WorkspacePermissionMode mode,
  }) async {
    if (gatewayClient != null && gatewayClient!.isConnected) {
      await gatewayClient!.setWorkspacePermissionMode(
        workspaceId: workspaceId,
        permissionMode: mode.value,
      );
      return;
    }
    await policyStore.updateModes(
      workspaceId,
      authority: CommandAuthority.current,
      permissionMode: mode,
    );
  }

  /// Retrieves list of MCP servers configured for a workspace.
  Future<List<Map<String, dynamic>>> listMcpServers({
    String? workspaceId,
    String? workspacePath,
  }) async {
    if (gatewayClient != null && gatewayClient!.isConnected) {
      try {
        final result = await gatewayClient!.listMcpServers(
          workspaceId: workspaceId,
        );
        final effective = result['effective'] as Map?;
        final servers = effective?['servers'] as List?;
        if (servers != null) {
          return servers
              .whereType<Map>()
              .map((s) => Map<String, dynamic>.from(s))
              .toList();
        }
      } catch (_) {}
    }

    try {
      final settings = SanadSettingsStore(homeDirectoryPath: sanadHome);
      final servers = await settings.readEffectiveMcpServers(
        workspacePath: workspacePath,
      );
      return servers
          .map(
            (s) => <String, dynamic>{
              'id': s.id,
              'name': s.name,
              'transport': s.transport.name,
              if (s.command != null) 'command': s.command,
              'enabled': s.enabled,
            },
          )
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Closes any underlying client connections.
  Future<void> dispose() async {
    if (gatewayClient != null) {
      await gatewayClient!.dispose();
    }
  }
}
