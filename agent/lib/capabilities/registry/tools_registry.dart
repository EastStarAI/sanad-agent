import '../models/local_tool_spec.dart';
import '../tools/base_tool.dart';
import '../tools/runtime/spec_backed_tool.dart';

class ToolsRegistry {
  static const int _maxSearchResults = 20;
  static const Set<String> _nonSearchableTools = {
    'tool_search',
    'shell_execute',
    'file_read',
    'file_write',
    'file_edit',
    'search_glob',
    'search_grep',
  };

  final Map<String, BaseTool> _tools = {};
  final Map<String, LocalToolSpec> _specs = {};

  /// Lookup-only aliases mapping legacy or alternative tool names to their canonical registered names.
  ///
  /// Aliases are lookup-only: they are honored by [getTool], [isRestartReplaySafe], and [getSpec],
  /// but they never add a second entry to [allTools] or [allSpecs], and never appear in the model-facing catalog.
  /// This is required because [ToolExecutionCoordinator] resolves tools by `registry.getTool(toolCall.name)`
  /// and persisted/replayed tool-call identity (e.g. legacy `list_scheduled_tasks`) must keep working.
  final Map<String, String> _aliases = {
    'list_scheduled_tasks': 'schedule_task',
  };

  void registerAlias(String aliasName, String targetToolName) {
    _aliases[aliasName] = targetToolName;
  }

  void registerTool(BaseTool tool) {
    _tools[tool.schema.name] = tool;
    _specs[tool.schema.name] = _resolveSpec(tool);
  }

  void registerTools(List<BaseTool> tools) {
    for (var tool in tools) {
      registerTool(tool);
    }
  }

  BaseTool? getTool(String name) {
    final canonicalName = _aliases[name] ?? name;
    return _tools[canonicalName];
  }

  bool isRestartReplaySafe(String name) {
    final canonicalName = _aliases[name] ?? name;
    return _tools[canonicalName]?.restartReplaySafe == true;
  }

  List<BaseTool> get allTools => _tools.values.toList();

  List<LocalToolSpec> get allSpecs => _specs.values.toList(growable: false);

  LocalToolSpec? getSpec(String name) {
    final canonicalName = _aliases[name] ?? name;
    return _specs[canonicalName];
  }

  List<Map<String, dynamic>> toRegisterAllToolsPayload() {
    return allSpecs
        .map((tool) => tool.toRegisterPayload())
        .toList(growable: false);
  }

  List<LocalToolSpec> searchableTools() {
    return allSpecs
        .where((tool) => !_nonSearchableTools.contains(tool.name))
        .toList(growable: false);
  }

  Map<String, dynamic> search(String query, {int maxResults = 5}) {
    final normalized = query.trim().toLowerCase();
    final matches =
        searchableTools()
            .map((tool) => (spec: tool, score: _score(tool, normalized)))
            .where((entry) => entry.score > 0)
            .toList(growable: false)
          ..sort((left, right) => right.score.compareTo(left.score));

    final effectiveMaxResults = maxResults.clamp(1, _maxSearchResults);
    final limited = matches
        .take(effectiveMaxResults)
        .map((entry) {
          final tool = entry.spec;
          return {
            'name': tool.name,
            'display_name': tool.displayName,
            'description': tool.description,
            'category': tool.category,
            'server_name': tool.serverName,
            'workspace_required': tool.workspaceRequired,
            'source': tool.source,
          };
        })
        .toList(growable: false);

    return {
      'query': query.trim(),
      'normalized_query': normalized,
      'total_searchable_tools': searchableTools().length,
      'matches': limited,
    };
  }

  ToolsRegistry copy() {
    final clone = ToolsRegistry();
    clone.registerTools(allTools);
    for (final entry in _aliases.entries) {
      clone.registerAlias(entry.key, entry.value);
    }
    return clone;
  }

  LocalToolSpec _resolveSpec(BaseTool tool) {
    if (tool is ToolSpecProvider) {
      return (tool as ToolSpecProvider).toolSpec;
    }

    return LocalToolSpec(
      name: tool.schema.name,
      displayName: tool.schema.name,
      description: tool.schema.description,
      inputSchema: tool.schema.parameters,
      source: const {'type': 'builtin_local', 'id': 'sanad-agent'},
      category: 'core',
      workspaceRequired: false,
      approval: const {'mode': 'default', 'sensitive': false},
      execution: const {'target': 'local_runtime'},
    );
  }

  int _score(LocalToolSpec spec, String query) {
    if (query.isEmpty) {
      return 1;
    }

    final exactFields = [
      spec.name.toLowerCase(),
      spec.displayName.toLowerCase(),
      spec.category.toLowerCase(),
    ];
    if (exactFields.contains(query)) {
      return 100;
    }

    var score = 0;
    if (spec.name.toLowerCase().contains(query)) {
      score += 50;
    }
    if (spec.displayName.toLowerCase().contains(query)) {
      score += 30;
    }
    if (spec.description.toLowerCase().contains(query)) {
      score += 20;
    }
    if (spec.category.toLowerCase().contains(query)) {
      score += 10;
    }
    if ((spec.serverName ?? '').toLowerCase().contains(query)) {
      score += 10;
    }
    return score;
  }
}
