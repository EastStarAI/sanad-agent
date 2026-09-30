import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';

import '../client/local_gateway_cli_client.dart';
import 'cli_workspace_state.dart';

/// Result of locating a workspace for a directory.
class WorkspaceMatch {
  /// The matched registered workspace map.
  final Map<String, dynamic> workspace;

  /// The normalized path of the matched workspace root.
  final String matchedPath;

  /// The normalized path that was searched (e.g. CWD or child dir).
  final String searchPath;

  /// Whether [searchPath] is exactly [matchedPath], or a nested subfolder.
  final bool isExact;

  /// The relative subpath from workspace root to [searchPath] (empty if exact).
  final String relativeSubpath;

  const WorkspaceMatch({
    required this.workspace,
    required this.matchedPath,
    required this.searchPath,
    required this.isExact,
    required this.relativeSubpath,
  });

  String get workspaceId => workspace['id']?.toString() ?? '';
  String get workspaceName =>
      workspace['name']?.toString() ??
      workspace['display_name']?.toString() ??
      p.basename(matchedPath);
}

/// Discovers and resolves the active workspace for a given directory or command invocation.
class WorkspaceLocator {
  final LocalGatewayCliClient? gatewayClient;
  final LocalWorkspaceRuntimeService? runtimeService;
  final CliWorkspaceStateStore stateStore;

  const WorkspaceLocator({
    this.gatewayClient,
    this.runtimeService,
    this.stateStore = const CliWorkspaceStateStore(),
  });

  /// Normalizes a directory path resolving symlinks and relative segments where possible.
  static String normalizeDirectory(String path) {
    try {
      final dir = Directory(path);
      if (dir.existsSync()) {
        return p.canonicalize(dir.resolveSymbolicLinksSync());
      }
    } catch (_) {}
    return p.canonicalize(p.normalize(p.absolute(path)));
  }

  /// Finds if [directoryPath] or any of its parent directories matches any registered workspace.
  ///
  /// Traverses up from the directory to the filesystem root, returning the closest
  /// enclosing workspace match, or null if no registered workspace encloses the path.
  static WorkspaceMatch? findMatchingWorkspace({
    required List<Map<String, dynamic>> workspaces,
    String? directoryPath,
  }) {
    final target = normalizeDirectory(directoryPath ?? Directory.current.path);

    final normalizedWorkspaces = <String, Map<String, dynamic>>{};
    for (final ws in workspaces) {
      final wsPath = ws['path']?.toString();
      if (wsPath != null && wsPath.isNotEmpty) {
        normalizedWorkspaces[normalizeDirectory(wsPath)] = ws;
      }
    }

    var current = target;
    while (true) {
      if (normalizedWorkspaces.containsKey(current)) {
        final matchedWs = normalizedWorkspaces[current]!;
        final isExact = current == target;
        final rel = isExact ? '' : p.relative(target, from: current);
        return WorkspaceMatch(
          workspace: matchedWs,
          matchedPath: current,
          searchPath: target,
          isExact: isExact,
          relativeSubpath: rel,
        );
      }
      final parent = p.dirname(current);
      if (parent == current) {
        break;
      }
      current = parent;
    }

    return null;
  }

  /// Automatically discovers a registered workspace matching [cwd] (or CWD)
  /// using the provided workspace list, gateway client, or local runtime service.
  Future<WorkspaceMatch?> autoDiscover({
    String? cwd,
    List<Map<String, dynamic>>? knownWorkspaces,
  }) async {
    final workspaces = knownWorkspaces ?? await _fetchWorkspaces();
    return findMatchingWorkspace(workspaces: workspaces, directoryPath: cwd);
  }

  /// Resolves the active workspace considering explicit flags, CWD auto-discovery,
  /// and local state file persistence.
  ///
  /// Resolution order:
  /// 1. [explicitIdOrPath] (if provided via `-w` / `--workspace` or command argument).
  /// 2. CWD auto-discovery (if current directory or any parent is inside a registered workspace).
  /// 3. Stored active workspace from `cli_state.json`.
  /// 4. Fallback: null.
  Future<Map<String, dynamic>?> resolveActiveWorkspace({
    String? explicitIdOrPath,
    String? cwd,
    List<Map<String, dynamic>>? knownWorkspaces,
  }) async {
    final workspaces = knownWorkspaces ?? await _fetchWorkspaces();
    if (workspaces.isEmpty) return null;

    // 1. Explicit ID, name, or path provided
    if (explicitIdOrPath != null && explicitIdOrPath.trim().isNotEmpty) {
      final query = explicitIdOrPath.trim();
      final normalizedQueryPath = normalizeDirectory(query);

      for (final ws in workspaces) {
        final id = ws['id']?.toString();
        final name = (ws['name'] ?? ws['display_name'])?.toString();
        final path = ws['path']?.toString();

        if (id == query ||
            (name != null && name.toLowerCase() == query.toLowerCase()) ||
            (path != null && normalizeDirectory(path) == normalizedQueryPath)) {
          return ws;
        }
      }
      return null;
    }

    // 2. Auto-discovery from CWD
    final match = findMatchingWorkspace(
      workspaces: workspaces,
      directoryPath: cwd,
    );
    if (match != null) {
      return match.workspace;
    }

    // 3. Persistent state from cli_state.json
    final storedId = await stateStore.getActiveWorkspaceId();
    if (storedId != null && storedId.isNotEmpty) {
      for (final ws in workspaces) {
        if (ws['id']?.toString() == storedId) {
          return ws;
        }
      }
    }

    return null;
  }

  Future<List<Map<String, dynamic>>> _fetchWorkspaces() async {
    if (gatewayClient != null && gatewayClient!.isConnected) {
      try {
        return await gatewayClient!.listWorkspaces();
      } catch (_) {}
    }

    if (runtimeService != null) {
      try {
        return await runtimeService!.listWorkspaces();
      } catch (_) {}
    }

    try {
      final fallbackService = LocalWorkspaceRuntimeService();
      return await fallbackService.listWorkspaces();
    } catch (_) {}

    return const [];
  }
}
