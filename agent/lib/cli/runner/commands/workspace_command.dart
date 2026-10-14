import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';

import '../../workspace/workspace_cli_service.dart';
import '../../workspace/workspace_locator.dart';
import '../sanad_command.dart';

/// Command to manage and inspect Sanad workspaces.
class WorkspaceCommand extends SanadCommand {
  final WorkspaceCliService? serviceOverride;

  WorkspaceCommand({super.customAction, this.serviceOverride}) {
    addCommonOptions(argParser);
    addSubcommand(WorkspaceListCommand(serviceOverride: serviceOverride));
    addSubcommand(WorkspaceCurrentCommand(serviceOverride: serviceOverride));
    addSubcommand(WorkspaceSwitchCommand(serviceOverride: serviceOverride));
    addSubcommand(WorkspaceSelectCommand(serviceOverride: serviceOverride));
    addSubcommand(WorkspaceAddCommand(serviceOverride: serviceOverride));
    addSubcommand(WorkspaceCreateCommand(serviceOverride: serviceOverride));
    addSubcommand(WorkspaceTreeCommand(serviceOverride: serviceOverride));
    addSubcommand(WorkspacePolicyCommand(serviceOverride: serviceOverride));
  }

  @override
  String get name => 'workspace';

  @override
  List<String> get aliases => const ['ws'];

  @override
  String get description =>
      'Manage, inspect, and auto-discover Sanad workspaces';

  @override
  String get invocation => 'sanad workspace <subcommand> [options]';

  @override
  Future<int> execute() async {
    // Default action when no subcommand is provided: list workspaces.
    final listCmd = subcommands['list'] as WorkspaceListCommand?;
    if (listCmd != null) {
      listCmd.overrideGlobalResults = overrideGlobalResults ?? globalResults;
      return await listCmd.execute();
    }
    printUsage();
    return 0;
  }
}

abstract class _BaseWorkspaceSubcommand extends SanadCommand {
  final WorkspaceCliService? serviceOverride;

  _BaseWorkspaceSubcommand({this.serviceOverride, super.customAction}) {
    addCommonOptions(argParser);
  }

  Future<WorkspaceCliService> getService() async {
    if (serviceOverride != null) return serviceOverride!;
    final parent = this.parent;
    if (parent is WorkspaceCommand && parent.serviceOverride != null) {
      return parent.serviceOverride!;
    }
    return await WorkspaceCliService.create(
      forceStandalone: standalone,
      gatewayUrl: gatewayUrl,
      sanadHome: sanadHome,
    );
  }
}

/// Lists all registered workspaces in a formatted table with policy and active marker.
class WorkspaceListCommand extends _BaseWorkspaceSubcommand {
  WorkspaceListCommand({super.serviceOverride, super.customAction});

  @override
  String get name => 'list';

  @override
  String get description =>
      'List all registered workspaces with policy and active status';

  @override
  Future<int> execute() async {
    final service = await getService();
    final workspaces = await service.listWorkspaces();

    if (workspaces.isEmpty) {
      stdoutSink.writeln('No registered workspaces found.');
      stdoutSink.writeln(
        "Run 'sanad ws add [path]' to register an existing directory as a workspace.",
      );
      return 0;
    }

    // Resolve active workspace
    final activeWs = await service.locator.resolveActiveWorkspace(
      explicitIdOrPath: workspace,
      knownWorkspaces: workspaces,
    );
    final activeId = activeWs?['id']?.toString();

    // Check if CWD is inside a workspace
    final cwdMatch = await service.locator.autoDiscover(
      knownWorkspaces: workspaces,
    );

    // Read policies for all workspaces
    final policyModes = <String, String>{};
    for (final ws in workspaces) {
      final wsPath = ws['path']?.toString() ?? '';
      try {
        final pol = await service.getWorkspacePolicy(wsPath);
        policyModes[wsPath] = pol.permissionMode.value;
      } catch (_) {
        policyModes[wsPath] = WorkspacePermissionMode.defaultMode.value;
      }
    }

    stdoutSink.writeln('Registered Workspaces:');
    stdoutSink.writeln('');

    const nameHeader = 'NAME';
    const policyHeader = 'POLICY';
    const pathHeader = 'PATH';

    var maxNameLen = nameHeader.length;
    var maxPolicyLen = policyHeader.length;

    for (final ws in workspaces) {
      final name = (ws['name'] ?? ws['display_name'] ?? '').toString();
      final path = ws['path']?.toString() ?? '';
      final policy = policyModes[path] ?? 'default';
      if (name.length > maxNameLen) maxNameLen = name.length;
      if (policy.length > maxPolicyLen) maxPolicyLen = policy.length;
    }

    final header =
        '   ${nameHeader.padRight(maxNameLen + 2)}${policyHeader.padRight(maxPolicyLen + 2)}$pathHeader';
    stdoutSink.writeln(header);
    stdoutSink.writeln(
      '   ${''.padRight(maxNameLen, '-')}  ${''.padRight(maxPolicyLen, '-')}  ${''.padRight(30, '-')}',
    );

    for (final ws in workspaces) {
      final wsId = ws['id']?.toString() ?? '';
      final name = (ws['name'] ?? ws['display_name'] ?? '').toString();
      final path = ws['path']?.toString() ?? '';
      final policy = policyModes[path] ?? 'default';
      final isActive =
          (activeId != null && activeId == wsId) ||
          (activeWs != null && activeWs['path'] == path);

      final marker = isActive ? '* ' : '  ';
      final row =
          ' $marker${name.padRight(maxNameLen + 2)}${policy.padRight(maxPolicyLen + 2)}$path';
      stdoutSink.writeln(row);
    }

    stdoutSink.writeln('');
    if (cwdMatch == null) {
      stdoutSink.writeln(
        "(Current directory '${Directory.current.path}' is not a registered workspace. Run 'sanad ws add .' to register it.)",
      );
    } else {
      stdoutSink.writeln("(Active workspace indicated by '*')");
    }

    return 0;
  }
}

/// Shows details of the currently active workspace and connected MCP servers.
class WorkspaceCurrentCommand extends _BaseWorkspaceSubcommand {
  WorkspaceCurrentCommand({super.serviceOverride, super.customAction});

  @override
  String get name => 'current';

  @override
  String get description => 'Show details of the currently active workspace';

  @override
  Future<int> execute() async {
    final service = await getService();
    final workspaces = await service.listWorkspaces();
    final cwd = Directory.current.path;

    final cwdMatch = await service.locator.autoDiscover(
      cwd: cwd,
      knownWorkspaces: workspaces,
    );

    final activeWs = await service.locator.resolveActiveWorkspace(
      explicitIdOrPath: workspace,
      cwd: cwd,
      knownWorkspaces: workspaces,
    );

    if (activeWs == null) {
      stdoutSink.writeln(
        'No active workspace detected for current directory: $cwd',
      );
      stdoutSink.writeln(
        "Run 'sanad ws add .' to register this directory as a workspace,",
      );
      stdoutSink.writeln(
        "or 'sanad ws switch <name|id>' to select a registered workspace.",
      );
      return 0;
    }

    final wsPath = activeWs['path']?.toString() ?? '';
    final wsName =
        (activeWs['name'] ?? activeWs['display_name'] ?? p.basename(wsPath))
            .toString();
    final wsId = activeWs['id']?.toString() ?? 'unknown';

    WorkspacePolicy policy;
    try {
      policy = await service.getWorkspacePolicy(wsPath);
    } catch (_) {
      policy = const WorkspacePolicy();
    }

    final isAvailable = Directory(wsPath).existsSync();
    String discoveryMode;
    if (workspace != null && workspace!.isNotEmpty) {
      discoveryMode = 'Explicitly specified via --workspace';
    } else if (cwdMatch != null && cwdMatch.workspace['id'] == wsId) {
      discoveryMode = cwdMatch.isExact
          ? 'Auto-discovered (exact CWD match)'
          : 'Auto-discovered (parent workspace enclosing CWD: /${cwdMatch.relativeSubpath})';
    } else {
      discoveryMode = 'Selected from local CLI state';
    }

    stdoutSink.writeln('Active Workspace:');
    stdoutSink.writeln('  Name:        $wsName');
    stdoutSink.writeln('  ID:          $wsId');
    stdoutSink.writeln('  Path:        $wsPath');
    stdoutSink.writeln(
      '  Status:      ${isAvailable ? 'available' : 'missing (folder unavailable)'}',
    );
    stdoutSink.writeln('  Discovery:   $discoveryMode');
    stdoutSink.writeln('  Policy:      ${policy.permissionMode.value}');

    final mcpServers = await service.listMcpServers(
      workspaceId: wsId,
      workspacePath: wsPath,
    );

    stdoutSink.writeln('');
    stdoutSink.writeln('Connected MCP Servers:');
    if (mcpServers.isEmpty) {
      stdoutSink.writeln('  (No workspace-specific MCP servers configured)');
    } else {
      for (final s in mcpServers) {
        final sName = s['name']?.toString() ?? 'unnamed';
        final transport = s['transport']?.toString() ?? 'stdio';
        final command = s['command']?.toString();
        final detail = command != null ? '$transport: $command' : transport;
        stdoutSink.writeln('  - $sName ($detail)');
      }
    }

    return 0;
  }
}

/// Switches the active workspace in the local state file.
class WorkspaceSwitchCommand extends _BaseWorkspaceSubcommand {
  WorkspaceSwitchCommand({super.serviceOverride, super.customAction});

  @override
  String get name => 'switch';

  @override
  List<String> get aliases => const [];

  @override
  String get description =>
      'Switch or select the active workspace in local state';

  @override
  String get invocation => 'sanad workspace switch <workspace-path-or-id>';

  @override
  Future<int> execute() async {
    final target = argResults?.rest.firstOrNull;
    if (target == null || target.trim().isEmpty) {
      stderrSink.writeln('Error: Workspace path or ID is required.');
      stderrSink.writeln('Usage: $invocation');
      return 1;
    }

    final service = await getService();
    final workspaces = await service.listWorkspaces();
    final query = target.trim();
    final normalizedQueryPath = WorkspaceLocator.normalizeDirectory(query);

    Map<String, dynamic>? matched;
    for (final ws in workspaces) {
      final id = ws['id']?.toString();
      final name = (ws['name'] ?? ws['display_name'])?.toString();
      final path = ws['path']?.toString();

      if (id == query ||
          (name != null && name.toLowerCase() == query.toLowerCase()) ||
          (path != null &&
              WorkspaceLocator.normalizeDirectory(path) ==
                  normalizedQueryPath)) {
        matched = ws;
        break;
      }
    }

    if (matched == null) {
      stderrSink.writeln('Error: Workspace "$target" not found.');
      stderrSink.writeln(
        "Run 'sanad ws list' to see all registered workspaces.",
      );
      return 1;
    }

    final wsId = matched['id']?.toString() ?? '';
    final wsPath = matched['path']?.toString() ?? '';
    final wsName =
        (matched['name'] ?? matched['display_name'] ?? p.basename(wsPath))
            .toString();

    await service.stateStore.setActiveWorkspace(
      workspaceId: wsId,
      workspacePath: wsPath,
      workspaceName: wsName,
    );

    stdoutSink.writeln('Switched active workspace to: $wsName ($wsPath)');
    return 0;
  }
}

/// Backward compatibility alias for switch command.
class WorkspaceSelectCommand extends WorkspaceSwitchCommand {
  WorkspaceSelectCommand({super.serviceOverride, super.customAction});

  @override
  String get name => 'select';

  @override
  List<String> get aliases => const [];

  @override
  String get invocation => 'sanad workspace select <workspace-path-or-id>';
}

/// Registers an existing directory as a workspace.
class WorkspaceAddCommand extends _BaseWorkspaceSubcommand {
  WorkspaceAddCommand({super.serviceOverride, super.customAction}) {
    argParser.addOption(
      'name',
      abbr: 'n',
      help: 'Custom display name for the registered workspace',
    );
  }

  @override
  String get name => 'add';

  @override
  String get description => 'Register an existing directory as a workspace';

  @override
  String get invocation => 'sanad workspace add [path] [--name <name>]';

  @override
  Future<int> execute() async {
    final rawPath = argResults?.rest.firstOrNull ?? '.';
    final targetPath = WorkspaceLocator.normalizeDirectory(rawPath);
    final dir = Directory(targetPath);

    if (!await dir.exists()) {
      stderrSink.writeln('Error: Target directory does not exist: $targetPath');
      return 1;
    }

    final service = await getService();
    final customName = argResults?['name'] as String?;
    final defaultName = p.basename(targetPath).isNotEmpty
        ? p.basename(targetPath)
        : 'workspace';
    final name = (customName != null && customName.trim().isNotEmpty)
        ? customName.trim()
        : defaultName;

    // Check if already registered
    final existingWorkspaces = await service.listWorkspaces();
    for (final ws in existingWorkspaces) {
      final wsPath = ws['path']?.toString();
      if (wsPath != null &&
          WorkspaceLocator.normalizeDirectory(wsPath) == targetPath) {
        final existingId = ws['id']?.toString() ?? '';
        final existingName = (ws['name'] ?? ws['display_name'] ?? name)
            .toString();
        await service.stateStore.setActiveWorkspace(
          workspaceId: existingId,
          workspacePath: targetPath,
          workspaceName: existingName,
        );
        stdoutSink.writeln(
          'Workspace already registered: "$existingName" ($targetPath)',
        );
        return 0;
      }
    }

    final created = await service.createWorkspace(name: name, path: targetPath);

    final wsId = created['id']?.toString() ?? '';
    final wsName = (created['name'] ?? created['display_name'] ?? name)
        .toString();

    await service.stateStore.setActiveWorkspace(
      workspaceId: wsId,
      workspacePath: targetPath,
      workspaceName: wsName,
    );

    stdoutSink.writeln('Registered workspace: "$wsName" at $targetPath');
    return 0;
  }
}

/// Creates a new directory and registers it as a workspace.
class WorkspaceCreateCommand extends _BaseWorkspaceSubcommand {
  WorkspaceCreateCommand({super.serviceOverride, super.customAction}) {
    argParser.addOption(
      'path',
      help: 'Parent directory or target path for the new workspace',
    );
  }

  @override
  String get name => 'create';

  @override
  String get description =>
      'Create a new directory and register it as a workspace';

  @override
  String get invocation => 'sanad workspace create <name> [--path <dir>]';

  @override
  Future<int> execute() async {
    final name = argResults?.rest.firstOrNull?.trim();
    if (name == null || name.isEmpty) {
      stderrSink.writeln('Error: Workspace name is required.');
      stderrSink.writeln('Usage: $invocation');
      return 1;
    }

    final pathOption = argResults?['path'] as String?;
    String targetPath;
    if (pathOption != null && pathOption.trim().isNotEmpty) {
      final parentDir = WorkspaceLocator.normalizeDirectory(pathOption.trim());
      if (await Directory(parentDir).exists()) {
        targetPath = p.join(parentDir, name);
      } else {
        targetPath = parentDir;
      }
    } else {
      targetPath = p.join(Directory.current.path, name);
    }
    targetPath = WorkspaceLocator.normalizeDirectory(targetPath);

    final dir = Directory(targetPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final service = await getService();
    final created = await service.createWorkspace(name: name, path: targetPath);

    final wsId = created['id']?.toString() ?? '';
    final wsName = (created['name'] ?? created['display_name'] ?? name)
        .toString();

    await service.stateStore.setActiveWorkspace(
      workspaceId: wsId,
      workspacePath: targetPath,
      workspaceName: wsName,
    );

    stdoutSink.writeln('Created workspace "$wsName" at $targetPath');
    return 0;
  }
}

/// Browses and prints the file and folder tree of a workspace.
class WorkspaceTreeCommand extends _BaseWorkspaceSubcommand {
  WorkspaceTreeCommand({super.serviceOverride, super.customAction}) {
    argParser.addOption(
      'max-entries',
      abbr: 'n',
      help: 'Maximum number of directory entries to display',
      defaultsTo: '100',
    );
  }

  @override
  String get name => 'tree';

  @override
  String get description =>
      'Display file and directory tree of the active workspace';

  @override
  String get invocation => 'sanad workspace tree [subpath] [options]';

  @override
  Future<int> execute() async {
    final subpath = argResults?.rest.firstOrNull;
    final maxEntries =
        int.tryParse(argResults?['max-entries'] as String? ?? '100') ?? 100;

    final service = await getService();
    final activeWs = await service.locator.resolveActiveWorkspace(
      explicitIdOrPath: workspace,
    );

    String? wsId;
    String targetPath;

    if (activeWs != null) {
      wsId = activeWs['id']?.toString();
      final root = activeWs['path']?.toString() ?? Directory.current.path;
      targetPath = (subpath != null && subpath.trim().isNotEmpty)
          ? p.normalize(p.isAbsolute(subpath) ? subpath : p.join(root, subpath))
          : root;
    } else {
      targetPath = (subpath != null && subpath.trim().isNotEmpty)
          ? WorkspaceLocator.normalizeDirectory(subpath)
          : Directory.current.path;
    }

    final snapshot = await service.browseWorkspaceTree(
      workspaceId: wsId,
      path: targetPath,
      maxEntries: maxEntries,
    );

    final entries =
        (snapshot['entries'] as List?)
            ?.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList() ??
        [];
    final rootPath = snapshot['root_path']?.toString() ?? targetPath;
    final isTruncated = snapshot['truncated'] == true;

    stdoutSink.writeln('${p.basename(rootPath)}/ ($rootPath)');

    if (entries.isEmpty) {
      stdoutSink.writeln('  (empty directory)');
      return 0;
    }

    _renderTree(entries, stdoutSink);

    if (isTruncated) {
      stdoutSink.writeln('... (truncated, displaying top $maxEntries entries)');
    }

    return 0;
  }

  void _renderTree(List<Map<String, dynamic>> entries, StringSink sink) {
    // Sort entries alphabetically with directories first
    final sorted = List<Map<String, dynamic>>.from(entries)
      ..sort((a, b) {
        final aIsDir = a['type'] == 'directory' ? 0 : 1;
        final bIsDir = b['type'] == 'directory' ? 0 : 1;
        if (aIsDir != bIsDir) return aIsDir.compareTo(bIsDir);
        final aName = (a['name'] ?? a['relative_path'] ?? '')
            .toString()
            .toLowerCase();
        final bName = (b['name'] ?? b['relative_path'] ?? '')
            .toString()
            .toLowerCase();
        return aName.compareTo(bName);
      });

    for (var i = 0; i < sorted.length; i++) {
      final entry = sorted[i];
      final isLast = i == sorted.length - 1;
      final prefix = isLast ? '└── ' : '├── ';
      final name = entry['name'] ?? entry['relative_path'] ?? '';
      final isDir = entry['type'] == 'directory';
      sink.writeln('$prefix$name${isDir ? '/' : ''}');
    }
  }
}

/// Views or updates the security permission policy of the active workspace.
class WorkspacePolicyCommand extends _BaseWorkspaceSubcommand {
  WorkspacePolicyCommand({super.serviceOverride, super.customAction});

  @override
  String get name => 'policy';

  @override
  String get description =>
      'View or change workspace security permission mode (default, full_access)';

  @override
  String get invocation => 'sanad workspace policy [default|full_access]';

  @override
  Future<int> execute() async {
    final modeArg = argResults?.rest.firstOrNull?.toLowerCase().trim();

    final service = await getService();
    final activeWs = await service.locator.resolveActiveWorkspace(
      explicitIdOrPath: workspace,
    );

    if (activeWs == null) {
      stderrSink.writeln('Error: No active workspace found.');
      stderrSink.writeln(
        "Run 'sanad ws list' to inspect available workspaces or 'sanad ws switch <name|id>' to select one.",
      );
      return 1;
    }

    final wsId = activeWs['id']?.toString() ?? '';
    final wsPath = activeWs['path']?.toString() ?? '';
    final wsName =
        (activeWs['name'] ?? activeWs['display_name'] ?? p.basename(wsPath))
            .toString();

    // Mode mutation
    if (modeArg != null && modeArg.isNotEmpty) {
      if (modeArg != 'default' && modeArg != 'full_access') {
        stderrSink.writeln(
          'Error: Invalid policy mode "$modeArg". Allowed modes: default, full_access.',
        );
        stderrSink.writeln('Usage: $invocation');
        return 1;
      }

      final targetMode = WorkspacePermissionMode.fromValue(modeArg);
      await service.setWorkspacePermissionMode(
        workspaceId: wsId,
        workspacePath: wsPath,
        mode: targetMode,
      );

      stdoutSink.writeln(
        'Updated security policy for "$wsName" to ${targetMode.value}.',
      );
      return 0;
    }

    // View current policy
    final policy = await service.getWorkspacePolicy(wsPath);
    stdoutSink.writeln('Workspace Security Policy:');
    stdoutSink.writeln('  Workspace:       $wsName ($wsPath)');
    stdoutSink.writeln('  Permission Mode: ${policy.permissionMode.value}');

    final perms = policy.permissions;
    stdoutSink.writeln('  Tool Permissions:');
    stdoutSink.writeln(
      '    Allow: ${perms.allow.isEmpty ? '(none)' : perms.allow.join(', ')}',
    );
    stdoutSink.writeln(
      '    Deny:  ${perms.deny.isEmpty ? '(none)' : perms.deny.join(', ')}',
    );
    stdoutSink.writeln(
      '    Ask:   ${perms.ask.isEmpty ? '(none)' : perms.ask.join(', ')}',
    );

    return 0;
  }
}
