import '../core/models/tool_call.dart';

class ToolConcurrencyEvaluator {
  /// Evaluates tool call batches to safely execute compatible tools concurrently.
  /// Interactive tools (system_ask_user), terminal execution (shell_execute),
  /// and overlapping file operation paths trigger a sequential execution fallback.
  static bool shouldParallelizeToolBatch(List<ToolCall> toolCalls) {
    if (toolCalls.length <= 1) return false;

    const neverParallelTools = {'system_ask_user', 'system_request_secret'};
    const parallelSafeTools = {
      'tool_search',
      'web_search',
      'web_fetch',
      'search_glob',
      'search_grep',
    };
    const pathScopedTools = {'file_read', 'file_write', 'file_edit'};

    final reservedPaths = <String>{};

    for (final tc in toolCalls) {
      if (neverParallelTools.contains(tc.name)) {
        return false;
      }

      if (pathScopedTools.contains(tc.name)) {
        final path = tc.arguments['path']?.toString();
        if (path == null || path.isEmpty) {
          return false;
        }
        if (reservedPaths.contains(path)) {
          return false;
        }
        reservedPaths.add(path);
        continue;
      }

      if (!parallelSafeTools.contains(tc.name)) {
        return false;
      }
    }

    return true;
  }
}
