import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../discovery/local_gateway_discovery.dart';

/// Manages persistent CLI state (such as active workspace) in `SANAD_HOME/cli_state.json`.
class CliWorkspaceStateStore {
  final String? sanadHomeOverride;

  const CliWorkspaceStateStore({this.sanadHomeOverride});

  File get _stateFile {
    final home =
        sanadHomeOverride ?? const LocalGatewayDiscovery().resolveSanadHome();
    return File(p.join(home, 'cli_state.json'));
  }

  /// Reads the entire CLI state map.
  Future<Map<String, dynamic>> readState() async {
    final file = _stateFile;
    if (!await file.exists()) {
      return {};
    }
    try {
      final content = await file.readAsString();
      if (content.trim().isEmpty) return {};
      final decoded = jsonDecode(content);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return {};
  }

  /// Writes the CLI state map.
  Future<void> writeState(Map<String, dynamic> state) async {
    final file = _stateFile;
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }
    await file.writeAsString(jsonEncode(state), flush: true);
  }

  /// Returns the ID of the active workspace stored in the state file.
  Future<String?> getActiveWorkspaceId() async {
    final state = await readState();
    return state['active_workspace_id'] as String?;
  }

  /// Returns the path of the active workspace stored in the state file.
  Future<String?> getActiveWorkspacePath() async {
    final state = await readState();
    return state['active_workspace_path'] as String?;
  }

  /// Sets the active workspace ID and path in the state file.
  Future<void> setActiveWorkspace({
    required String workspaceId,
    required String workspacePath,
    String? workspaceName,
  }) async {
    final state = await readState();
    state['active_workspace_id'] = workspaceId;
    state['active_workspace_path'] = workspacePath;
    if (workspaceName != null) {
      state['active_workspace_name'] = workspaceName;
    }
    state['updated_at'] = DateTime.now().toUtc().toIso8601String();
    await writeState(state);
  }

  /// Clears the active workspace entry from the state file.
  Future<void> clearActiveWorkspace() async {
    final state = await readState();
    state.remove('active_workspace_id');
    state.remove('active_workspace_path');
    state.remove('active_workspace_name');
    state['updated_at'] = DateTime.now().toUtc().toIso8601String();
    await writeState(state);
  }
}
