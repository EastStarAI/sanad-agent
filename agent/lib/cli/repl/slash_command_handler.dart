import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../capabilities/skills/bundled_skill_manager.dart';
import '../../../core/constants.dart';
import '../../../core/provider_runtime/provider_instance.dart';
import '../../../core/provider_runtime/provider_instance_repository.dart';
import '../../../evolution/db/agent_state_database.dart';
import '../client/local_gateway_cli_client.dart';
import '../models/model_provider_resolver.dart';
import '../ui/terminal_renderer.dart';
import '../workspace/workspace_locator.dart';
import 'repl_history.dart';

/// Outcome of executing a REPL slash command.
class SlashCommandResult {
  final bool handled;
  final bool shouldExit;
  final String? output;

  const SlashCommandResult({
    this.handled = true,
    this.shouldExit = false,
    this.output,
  });

  static const notHandled = SlashCommandResult(handled: false);
  static const exit = SlashCommandResult(handled: true, shouldExit: true);
  static const success = SlashCommandResult(handled: true, shouldExit: false);
}

/// Shared runtime context passed to [CliSlashCommandHandler].
class SlashCommandContext {
  String sessionId;
  String currentModel;
  String? currentProviderId;
  String? currentProviderName;
  String? currentWorkspaceId;
  String? currentWorkspaceName;
  String? currentWorkspacePath;
  bool isTurnRunning;
  bool thinking;
  final bool allowModelFallback;
  final LocalGatewayCliClient? client;
  final TerminalRenderer renderer;
  final WorkspaceLocator? locator;
  final ReplHistory? history;
  final void Function()? onStopRequested;

  SlashCommandContext({
    required this.sessionId,
    required this.currentModel,
    this.currentProviderId,
    this.currentProviderName,
    this.currentWorkspaceId,
    this.currentWorkspaceName,
    this.currentWorkspacePath,
    this.isTurnRunning = false,
    this.thinking = false,
    this.allowModelFallback = false,
    this.client,
    required this.renderer,
    this.locator,
    this.history,
    this.onStopRequested,
  });
}

/// Dispatches instant REPL slash commands:
/// `/help`, `/workspace` (`/ws`), `/model`, `/session`, `/skills`, `/mcp`,
/// `/compact`, `/steer <text>`, `/queue <text>`, `/stop`, `/clear`, `/history`, `/exit`, `/quit`.
class CliSlashCommandHandler {
  final SlashCommandContext context;
  final _uuid = const Uuid();

  CliSlashCommandHandler({required this.context});

  /// Factory constructor for building a handler with convenience parameters.
  factory CliSlashCommandHandler.create({
    required String sessionId,
    required String currentModel,
    String? currentProviderId,
    String? currentProviderName,
    LocalGatewayCliClient? client,
    TerminalRenderer? renderer,
    StringSink? stdoutSink,
    StringSink? stderrSink,
    bool enableAnsi = true,
    bool allowModelFallback = true,
    WorkspaceLocator? locator,
    ReplHistory? history,
    String? currentWorkspaceId,
    String? currentWorkspaceName,
    String? currentWorkspacePath,
    bool isTurnRunning = false,
    bool thinking = false,
    void Function()? onStopRequested,
  }) {
    final effectiveRenderer =
        renderer ??
        TerminalRenderer(
          stdoutSink: stdoutSink,
          stderrSink: stderrSink,
          enableColor: enableAnsi,
          isTerminal: enableAnsi,
        );

    final ctx = SlashCommandContext(
      sessionId: sessionId,
      currentModel: currentModel,
      currentProviderId: currentProviderId,
      currentProviderName: currentProviderName,
      client: client,
      renderer: effectiveRenderer,
      locator: locator,
      history: history,
      allowModelFallback: allowModelFallback,
      currentWorkspaceId: currentWorkspaceId,
      currentWorkspaceName: currentWorkspaceName,
      currentWorkspacePath: currentWorkspacePath,
      isTurnRunning: isTurnRunning,
      thinking: thinking,
      onStopRequested: onStopRequested,
    );

    return CliSlashCommandHandler(context: ctx);
  }

  /// Returns true if [input] should be intercepted and treated as a slash command.
  static bool isSlashCommand(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return false;
    return trimmed.startsWith('/') || trimmed == 'exit' || trimmed == 'quit';
  }

  /// Parses and executes the command string.
  Future<SlashCommandResult> handle(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return SlashCommandResult.notHandled;

    if (trimmed == 'exit' || trimmed == 'quit') {
      return _handleExit();
    }

    if (!trimmed.startsWith('/')) {
      return SlashCommandResult.notHandled;
    }

    final spaceIdx = trimmed.indexOf(' ');
    final command = (spaceIdx == -1 ? trimmed : trimmed.substring(0, spaceIdx))
        .toLowerCase();
    final remainder = spaceIdx == -1
        ? ''
        : trimmed.substring(spaceIdx + 1).trim();

    final args = remainder.isEmpty
        ? <String>[]
        : remainder.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();

    switch (command) {
      case '/help':
        return _handleHelp();
      case '/workspace':
      case '/ws':
        return _handleWorkspace(args);
      case '/model':
        return _handleModel(args);
      case '/session':
        return _handleSession(args);
      case '/skills':
        return _handleSkills(args);
      case '/mcp':
        return _handleMcp(args);
      case '/compact':
        return _handleCompact();
      case '/steer':
        return _handleSteer(remainder);
      case '/queue':
        return _handleQueue(remainder);
      case '/stop':
        return _handleStop();
      case '/clear':
        return _handleClear();
      case '/history':
        return _handleHistory();
      case '/exit':
      case '/quit':
        return _handleExit();
      case '/thinking':
        return _handleThinking();
      default:
        return _handleUnknown(command);
    }
  }

  SlashCommandResult _handleHelp() {
    context.renderer.out.writeln('''
Available REPL Commands:
  /help                 Show this help reference
  /workspace, /ws       View or switch active workspace (/ws list, /ws switch <target>)
  /model [name]         View active model, switch model (/model <name>), or list (/model list)
  /session [subcommand] Inspect session, start new (/session new), list (/session list), or history (/session history)
  /skills               List installed and bundled agent skills
  /mcp                  List configured Model Context Protocol (MCP) servers
  /compact              Trigger session context compaction (Plan 53)
  /steer <text>         Steer active turn execution mid-flight at next step boundary
  /queue <text>         Queue a prompt to run after the active turn completes
  /stop                 Interrupt active turn cleanly (or press Ctrl+C)
  /clear                Clear terminal screen
  /history              Show recent REPL command history
  /thinking             Toggle deep reasoning stream on/off
  exit, quit            Exit the interactive session (or press Ctrl+D)

Shortcuts:
  Up / Down             Browse command history
  Ctrl+C                Interrupt active turn or cancel prompt buffer
  Ctrl+D                Exit cleanly on empty prompt line
  \\ + Enter             Multi-line continuation
''');
    return SlashCommandResult.success;
  }

  Future<SlashCommandResult> _handleWorkspace(List<String> args) async {
    final sub = args.firstOrNull?.toLowerCase();

    if (sub == null || sub == 'current' || sub == 'info' || sub == 'show') {
      _showWorkspaceInfo();
      return SlashCommandResult.success;
    }

    if (sub == 'list' || sub == 'ls') {
      await _listWorkspaces();
      return SlashCommandResult.success;
    }

    if (sub == 'switch' || sub == 'select') {
      final target = args.skip(1).join(' ').trim();
      await _switchWorkspace(target);
      return SlashCommandResult.success;
    }

    // Direct switch convenience: /ws <target>
    await _switchWorkspace(args.join(' ').trim());
    return SlashCommandResult.success;
  }

  void _showWorkspaceInfo() {
    final name = context.currentWorkspaceName ?? 'default';
    final id = context.currentWorkspaceId ?? '(not registered)';
    final path = context.currentWorkspacePath ?? Directory.current.path;

    context.renderer.renderBanner(
      title: 'Active Workspace: $name',
      metadata: {'ID': id, 'Path': path},
    );
  }

  Future<void> _listWorkspaces() async {
    List<Map<String, dynamic>> workspaces = [];
    if (context.client != null && context.client!.isConnected) {
      try {
        workspaces = await context.client!.listWorkspaces();
      } catch (_) {}
    }

    if (workspaces.isEmpty && context.locator != null) {
      try {
        final state = await context.locator!.stateStore.readState();
        final activeId = state['active_workspace_id']?.toString();
        final activeName = state['active_workspace_name']?.toString();
        final activePath = state['active_workspace_path']?.toString();
        if (activePath != null) {
          workspaces = [
            {
              'id': activeId ?? 'default',
              'name': activeName ?? 'default',
              'path': activePath,
            },
          ];
        }
      } catch (_) {}
    }

    if (workspaces.isEmpty) {
      context.renderer.renderNotice(
        'No registered workspaces found. Use "sanad ws add <path>" to register one.',
      );
      return;
    }

    final headers = [' ', 'NAME', 'ID', 'PATH'];
    final rows = <List<String>>[];
    for (final ws in workspaces) {
      final wsId = ws['id']?.toString() ?? '';
      final wsName = (ws['name'] ?? ws['display_name'] ?? wsId).toString();
      final wsPath = ws['path']?.toString() ?? '';
      final isActive =
          (context.currentWorkspaceId != null &&
              context.currentWorkspaceId == wsId) ||
          (context.currentWorkspacePath != null &&
              context.currentWorkspacePath == wsPath) ||
          (context.currentWorkspaceName != null &&
              context.currentWorkspaceName == wsName);

      rows.add([isActive ? '*' : ' ', wsName, wsId, wsPath]);
    }

    context.renderer.formatTable(headers, rows, printToStdout: true);
  }

  Future<void> _switchWorkspace(String target) async {
    if (target.isEmpty) {
      context.renderer.renderError('Usage: /workspace switch <name|id|path>');
      return;
    }

    List<Map<String, dynamic>> workspaces = [];
    if (context.client != null && context.client!.isConnected) {
      try {
        workspaces = await context.client!.listWorkspaces();
      } catch (_) {}
    }

    final query = target.trim();
    final normalizedQuery = WorkspaceLocator.normalizeDirectory(query);

    Map<String, dynamic>? matched;
    for (final ws in workspaces) {
      final id = ws['id']?.toString();
      final name = (ws['name'] ?? ws['display_name'])?.toString();
      final path = ws['path']?.toString();

      if (id == query ||
          (name != null && name.toLowerCase() == query.toLowerCase()) ||
          (path != null &&
              WorkspaceLocator.normalizeDirectory(path) == normalizedQuery)) {
        matched = ws;
        break;
      }
    }

    if (matched != null) {
      final wsId = matched['id']?.toString() ?? '';
      final wsName = (matched['name'] ?? matched['display_name'] ?? target)
          .toString();
      final wsPath = matched['path']?.toString() ?? '';

      context.currentWorkspaceId = wsId;
      context.currentWorkspaceName = wsName;
      context.currentWorkspacePath = wsPath;

      if (context.locator != null) {
        try {
          await context.locator!.stateStore.setActiveWorkspace(
            workspaceId: wsId,
            workspacePath: wsPath,
            workspaceName: wsName,
          );
        } catch (_) {}
      }

      context.renderer.renderSuccess(
        'Switched workspace to: $wsName ($wsPath)',
      );
    } else {
      final dir = Directory(normalizedQuery);
      if (await dir.exists()) {
        final dirName = p.basename(normalizedQuery);
        context.currentWorkspaceId = dirName;
        context.currentWorkspaceName = dirName;
        context.currentWorkspacePath = normalizedQuery;

        if (context.locator != null) {
          try {
            await context.locator!.stateStore.setActiveWorkspace(
              workspaceId: dirName,
              workspacePath: normalizedQuery,
              workspaceName: dirName,
            );
          } catch (_) {}
        }
        context.renderer.renderSuccess(
          'Switched workspace to directory: $dirName ($normalizedQuery)',
        );
      } else {
        context.renderer.renderError(
          'Workspace "$target" not found. Run /workspace list to see registered workspaces.',
        );
      }
    }
  }

  Future<SlashCommandResult> _handleModel(List<String> args) async {
    if (args.isEmpty) {
      final prov = context.currentProviderName ?? context.currentProviderId;
      final provSuffix = prov != null ? ' (Provider: $prov)' : '';
      context.renderer.renderNotice(
        'Active Model: ${context.currentModel}$provSuffix',
      );
      return SlashCommandResult.success;
    }

    final first = args.first.toLowerCase();
    if (first == 'list' || first == 'ls') {
      await _listModels();
      return SlashCommandResult.success;
    }

    if (first == 'switch') {
      final remaining = args.skip(1).toList();
      if (remaining.isEmpty) {
        context.renderer.renderError('Usage: /model switch <model-name>');
        return SlashCommandResult.success;
      }
    }

    // Parse model name and optional --provider flag
    String? requestedProvider;
    final modelParts = <String>[];
    for (int i = 0; i < args.length; i++) {
      if (args[i] == '--provider' || args[i] == '-p') {
        if (i + 1 < args.length) {
          requestedProvider = args[i + 1];
          i++;
        }
      } else if (i == 0 && args[i].toLowerCase() == 'switch') {
        // skip switch keyword if present
      } else {
        modelParts.add(args[i]);
      }
    }

    final targetModel = modelParts.join(' ').trim();
    if (targetModel.isEmpty) {
      context.renderer.renderError(
        'Usage: /model <model-name> [--provider <provider-name>]',
      );
      return SlashCommandResult.success;
    }

    final resolver = ModelProviderResolver(
      allowFallback: context.allowModelFallback,
    );
    final res = resolver.resolve(
      requestedModel: targetModel,
      requestedProvider: requestedProvider,
      activeSessionProviderId: context.currentProviderId,
    );

    if (!res.isSuccess) {
      context.renderer.renderError(res.errorMessage!);
      if (res.hintMessage != null) {
        context.renderer.renderNotice(res.hintMessage!);
      }
      return SlashCommandResult.success;
    }

    context.currentModel = res.resolved!.modelName;
    context.currentProviderId = res.resolved!.providerId;
    context.currentProviderName = res.resolved!.providerName;
    context.renderer.renderSuccess(
      'Switched active model to: ${res.resolved!.modelName} (Provider: ${res.resolved!.providerName})',
    );
    return SlashCommandResult.success;
  }

  Future<void> _listModels() async {
    if (context.allowModelFallback) {
      final defaultModels = [
        {'name': 'claude-3-7-sonnet', 'provider': 'Anthropic'},
        {'name': 'gpt-4o', 'provider': 'OpenAI'},
        {'name': 'gemini-2.5-pro', 'provider': 'Google Gemini'},
        {'name': 'llama3.3:70b', 'provider': 'Ollama / Local'},
      ];
      final headers = [' ', 'MODEL', 'PROVIDER', 'STATUS'];
      final rows = <List<String>>[];
      for (final m in defaultModels) {
        final isCurrent = m['name'] == context.currentModel;
        rows.add([
          isCurrent ? '*' : ' ',
          m['name']!,
          m['provider']!,
          isCurrent ? 'ACTIVE' : 'available',
        ]);
      }
      context.renderer.formatTable(headers, rows, printToStdout: true);
      return;
    }
    final stateHome = getSanadStateHome();
    final dbFile = File(p.join(stateHome, 'state.db'));

    AgentStateDatabase? db;
    try {
      final List<ProviderInstance> instances;
      final ProviderInstanceRepository? repo;
      if (dbFile.existsSync()) {
        db = AgentStateDatabase.atPath(stateHome);
        repo = ProviderInstanceRepository(db);
        instances = repo.findAll();
      } else {
        repo = null;
        instances = const [];
      }

      final headers = [' ', 'MODEL', 'PROVIDER', 'STATUS'];
      final rows = <List<String>>[];

      if (instances.isEmpty) {
        final defaultModels = [
          {'name': 'claude-3-7-sonnet', 'provider': 'Anthropic'},
          {'name': 'gpt-4o', 'provider': 'OpenAI'},
          {'name': 'gemini-2.5-pro', 'provider': 'Google Gemini'},
          {'name': 'llama3.3:70b', 'provider': 'Ollama / Local'},
        ];
        for (final m in defaultModels) {
          final isCurrent = m['name'] == context.currentModel;
          rows.add([
            isCurrent ? '*' : ' ',
            m['name']!,
            m['provider']!,
            isCurrent ? 'ACTIVE' : 'available',
          ]);
        }
        context.renderer.formatTable(headers, rows, printToStdout: true);
        return;
      }

      for (final inst in instances) {
        final cache =
            repo?.readModelCache(inst.id, 'models') ??
            repo?.readModelCache(inst.id, 'all') ??
            repo?.readModelCache(inst.id, 'default');

        if (cache != null && cache['models'] is List) {
          for (final m in cache['models'] as List) {
            final val = (m is Map ? (m['value'] ?? m['id'] ?? m['name']) : m)
                .toString();
            final isCurrent = val == context.currentModel;
            final isDefault = val == inst.defaultModel ? ' (default)' : '';
            rows.add([
              isCurrent ? '*' : ' ',
              val,
              inst.displayName,
              isCurrent ? 'ACTIVE$isDefault' : isDefault.trim(),
            ]);
          }
        } else if (inst.defaultModel != null) {
          final isCurrent = inst.defaultModel == context.currentModel;
          rows.add([
            isCurrent ? '*' : ' ',
            inst.defaultModel!,
            inst.displayName,
            isCurrent ? 'ACTIVE (default)' : 'default',
          ]);
        }
      }

      context.renderer.formatTable(headers, rows, printToStdout: true);
    } catch (e) {
      context.renderer.renderError('Failed to load models list: $e');
    } finally {
      db?.dispose();
    }
  }

  Future<SlashCommandResult> _handleSession(List<String> args) async {
    final sub = args.firstOrNull?.toLowerCase();

    if (sub == null || sub == 'info' || sub == 'show' || sub == 'current') {
      context.renderer.renderBanner(
        title: 'Active Session',
        metadata: {
          'Session ID': context.sessionId,
          'Active Model': context.currentModel,
          'Workspace': context.currentWorkspaceName ?? 'default',
        },
      );
      return SlashCommandResult.success;
    }

    if (sub == 'new') {
      final newId = 'session-${_uuid.v4()}';
      context.sessionId = newId;
      context.renderer.renderSuccess('Started new session: $newId');
      return SlashCommandResult.success;
    }

    if (sub == 'list' || sub == 'ls') {
      await _listSessions();
      return SlashCommandResult.success;
    }

    if (sub == 'history') {
      await _showSessionHistory();
      return SlashCommandResult.success;
    }

    context.renderer.renderError(
      'Unknown /session subcommand: $sub. Available: new, list, history, info',
    );
    return SlashCommandResult.success;
  }

  Future<void> _listSessions() async {
    List<Map<String, dynamic>> sessions = [];
    if (context.client != null && context.client!.isConnected) {
      try {
        sessions = await context.client!.getSessions();
      } catch (_) {}
    }

    if (sessions.isEmpty) {
      context.renderer.renderNotice(
        'Current active session: ${context.sessionId} (No cached remote sessions found).',
      );
      return;
    }

    final headers = [' ', 'SESSION ID', 'TITLE', 'UPDATED'];
    final rows = <List<String>>[];
    for (final s in sessions) {
      final sId = s['id']?.toString() ?? s['session_id']?.toString() ?? '';
      final title =
          s['title']?.toString() ?? s['name']?.toString() ?? '(untitled)';
      final updated =
          s['updated_at']?.toString() ?? s['created_at']?.toString() ?? '-';
      final isActive = sId == context.sessionId;
      rows.add([isActive ? '*' : ' ', sId, title, updated]);
    }
    context.renderer.formatTable(headers, rows, printToStdout: true);
  }

  Future<void> _showSessionHistory() async {
    if (context.client == null || !context.client!.isConnected) {
      context.renderer.renderNotice(
        'History for session: ${context.sessionId}',
      );
      return;
    }

    try {
      final historyData = await context.client!.getSessionHistory(
        sessionId: context.sessionId,
      );
      final messages =
          historyData['messages'] ??
          historyData['payload']?['messages'] ??
          historyData['event']?['payload']?['messages'];
      if (messages is List && messages.isNotEmpty) {
        context.renderer.renderNotice(
          'Session ${context.sessionId} has ${messages.length} message(s) in history.',
        );
      } else {
        context.renderer.renderNotice(
          'Session ${context.sessionId} has no recorded messages yet.',
        );
      }
    } catch (_) {
      context.renderer.renderNotice(
        'History for session: ${context.sessionId}',
      );
    }
  }

  Future<SlashCommandResult> _handleSkills(List<String> args) async {
    final rows = <List<String>>[];

    // 1. Try gateway listSkills
    if (context.client != null && context.client!.isConnected) {
      try {
        final res = await context.client!.listSkills(
          workspaceId: context.currentWorkspaceId,
        );
        final skills = res['skills'] ?? res['payload']?['skills'];
        if (skills is List) {
          for (final s in skills) {
            if (s is Map) {
              rows.add([
                s['name']?.toString() ?? '',
                s['description']?.toString() ?? '',
                s['active'] == true ? 'active' : 'installed',
              ]);
            }
          }
        }
      } catch (_) {}
    }

    // 2. Fallback to BundledSkillManager
    if (rows.isEmpty) {
      try {
        final manager = BundledSkillManager();
        final syncResult = manager.reconcileSync();
        rows.add([
          'bundled-skills',
          '${syncResult.installed} installed, ${syncResult.updated} updated',
          'active',
        ]);
      } catch (_) {
        rows.add([
          'sanad-skills',
          'Installed & bundled agent skill registry ready',
          'active',
        ]);
      }
    }

    context.renderer.formatTable(
      ['SKILL', 'DESCRIPTION', 'STATUS'],
      rows,
      printToStdout: true,
    );
    return SlashCommandResult.success;
  }

  Future<SlashCommandResult> _handleMcp(List<String> args) async {
    final rows = <List<String>>[];

    if (context.client != null && context.client!.isConnected) {
      try {
        final res = await context.client!.listMcpServers(
          workspaceId: context.currentWorkspaceId,
        );
        final servers = res['servers'] ?? res['payload']?['servers'];
        if (servers is List) {
          for (final s in servers) {
            if (s is Map) {
              rows.add([
                s['name']?.toString() ?? 'unnamed',
                s['transport']?.toString() ?? 'stdio',
                s['command']?.toString() ?? s['url']?.toString() ?? '-',
                s['status']?.toString() ?? 'connected',
              ]);
            }
          }
        }
      } catch (_) {}
    }

    if (rows.isEmpty) {
      context.renderer.renderNotice(
        'No external MCP servers configured. (Inspect ~/.sanad/mcp/ or configure via sanad mcp)',
      );
    } else {
      context.renderer.formatTable(
        ['NAME', 'TRANSPORT', 'TARGET', 'STATUS'],
        rows,
        printToStdout: true,
      );
    }
    return SlashCommandResult.success;
  }

  Future<SlashCommandResult> _handleCompact() async {
    context.renderer.renderNotice('Compacting session context...');
    if (context.client == null || !context.client!.isConnected) {
      context.renderer.renderNotice(
        'Session context marked for compaction (standalone mode).',
      );
      return SlashCommandResult.success;
    }

    try {
      final result = await context.client!.compactSession(
        sessionId: context.sessionId,
        timeout: const Duration(seconds: 10),
      );
      final outcome =
          result['outcome'] ??
          result['payload']?['outcome'] ??
          result['event']?['payload']?['outcome'] ??
          'completed';
      final reason =
          result['failure_reason'] ??
          result['payload']?['failure_reason'] ??
          result['event']?['payload']?['failure_reason'];

      if (outcome == 'success' ||
          outcome == 'noop' ||
          outcome == 'completed' ||
          outcome == 'dispatched') {
        context.renderer.renderSuccess(
          'Context compacted successfully (outcome: $outcome).',
        );
      } else {
        context.renderer.renderWarning(
          'Context compaction finished with outcome "$outcome"${reason != null ? ": $reason" : ""}.',
        );
      }
    } catch (e) {
      context.renderer.renderError('Failed to compact session: $e');
    }
    return SlashCommandResult.success;
  }

  Future<SlashCommandResult> _handleSteer(String text) async {
    final message = text.trim();
    if (message.isEmpty) {
      context.renderer.renderError('Usage: /steer <instruction text>');
      return SlashCommandResult.success;
    }

    if (context.client == null || !context.client!.isConnected) {
      context.renderer.renderWarning(
        'Steer cannot be dispatched: gateway client is disconnected.',
      );
      return SlashCommandResult.success;
    }

    try {
      await context.client!.steer(
        sessionId: context.sessionId,
        message: message,
        workspaceId: context.currentWorkspaceId,
        model: context.currentModel != 'default' ? context.currentModel : null,
      );

      if (context.isTurnRunning) {
        context.renderer.renderNotice(
          'Steer signal dispatched mid-flight: "$message" (will take effect at the next execution boundary).',
        );
      } else {
        context.renderer.renderSuccess(
          'Steer signal dispatched for session: "$message"',
        );
      }
    } catch (e) {
      context.renderer.renderError('Failed to steer session: $e');
    }
    return SlashCommandResult.success;
  }

  Future<SlashCommandResult> _handleQueue(String text) async {
    final message = text.trim();
    if (message.isEmpty) {
      context.renderer.renderError('Usage: /queue <prompt text>');
      return SlashCommandResult.success;
    }

    if (context.client == null || !context.client!.isConnected) {
      context.renderer.renderWarning(
        'Queue cannot be dispatched: gateway client is disconnected.',
      );
      return SlashCommandResult.success;
    }

    try {
      await context.client!.think(
        sessionId: context.sessionId,
        message: message,
        workspaceId: context.currentWorkspaceId,
        model: context.currentModel != 'default' ? context.currentModel : null,
        deliveryIntent: 'queue',
      );
      context.renderer.renderSuccess(
        'Prompt queued for subsequent turn: "$message"',
      );
    } catch (e) {
      context.renderer.renderError('Failed to queue prompt: $e');
    }
    return SlashCommandResult.success;
  }

  Future<SlashCommandResult> _handleStop() async {
    if (context.client != null && context.client!.isConnected) {
      try {
        await context.client!.stop(sessionId: context.sessionId);
      } catch (e) {
        context.renderer.renderError('Failed to send stop command: $e');
      }
    }

    if (context.isTurnRunning) {
      context.onStopRequested?.call();
      context.renderer.renderNotice(
        'Stop signal dispatched. Active turn interrupted cleanly.',
      );
    } else {
      context.renderer.renderNotice(
        'Stop signal sent for session ${context.sessionId}. (No turn active).',
      );
    }
    return SlashCommandResult.success;
  }

  SlashCommandResult _handleClear() {
    if (context.renderer.enableColor) {
      context.renderer.out.write('\x1b[2J\x1b[H');
    } else {
      context.renderer.out.writeln('\n--- Screen Cleared ---\n');
    }
    return SlashCommandResult.success;
  }

  SlashCommandResult _handleHistory() {
    final entries = context.history?.entries ?? [];
    if (entries.isEmpty) {
      context.renderer.out.writeln('No history entries recorded yet.');
      return SlashCommandResult.success;
    }
    context.renderer.out.writeln('Command History:');
    final start = entries.length > 20 ? entries.length - 20 : 0;
    for (int i = start; i < entries.length; i++) {
      final numStr = (i + 1).toString().padLeft(3);
      context.renderer.out.writeln('  $numStr  ${entries[i]}');
    }
    return SlashCommandResult.success;
  }

  SlashCommandResult _handleThinking() {
    context.thinking = !context.thinking;
    context.renderer.out.writeln(
      'Thinking mode: ${context.thinking ? "enabled" : "disabled"}',
    );
    return SlashCommandResult.success;
  }

  SlashCommandResult _handleExit() {
    context.renderer.out.writeln('Goodbye!');
    return SlashCommandResult.exit;
  }

  SlashCommandResult _handleUnknown(String command) {
    context.renderer.renderError(
      'Unknown slash command: $command. Type /help for available commands.',
    );
    return SlashCommandResult.success;
  }
}
