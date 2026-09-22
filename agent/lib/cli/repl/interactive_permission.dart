import '../models/cli_events.dart';
import '../ui/cli_tool_formatter.dart';
import 'repl_line_reader.dart';

/// The result of an interactive tool permission prompt.
class PermissionResult {
  final bool allowed;
  final String scope;
  final String decision;
  final String? comment;

  const PermissionResult({
    required this.allowed,
    required this.scope,
    required this.decision,
    this.comment,
  });

  @override
  String toString() =>
      'PermissionResult(allowed: $allowed, scope: $scope, decision: $decision, comment: $comment)';
}

/// Handles interactive permission prompts for gated tool execution.
class InteractivePermissionHandler {
  /// Prompts the user interactively to allow or deny tool execution with scope selection.
  static Future<PermissionResult> prompt({
    required CliPermissionRequestEvent event,
    required ReplLineReader lineReader,
    required StringSink output,
    bool ansi = false,
  }) async {
    final tool = event.toolName;
    final permClass = event.permissionClass;
    final wsName = event.workspaceName ?? 'Active Workspace';

    // Extract tool input map with full fallback coverage
    final rawPayload = event.raw['payload'] is Map
        ? event.raw['payload'] as Map
        : {};
    final Map<String, dynamic> toolInput = event.toolInput.isNotEmpty
        ? event.toolInput
        : (rawPayload['tool_input'] is Map
              ? Map<String, dynamic>.from(rawPayload['tool_input'] as Map)
              : (rawPayload['arguments'] is Map
                    ? Map<String, dynamic>.from(rawPayload['arguments'] as Map)
                    : (rawPayload['input'] is Map
                          ? Map<String, dynamic>.from(
                              rawPayload['input'] as Map,
                            )
                          : <String, dynamic>{})));

    final title = CliToolFormatter.formatPermissionTitle(
      tool,
      toolInput: toolInput,
    );
    final details = CliToolFormatter.formatPermissionDetails(
      toolName: tool,
      toolInput: toolInput,
      workspaceName: wsName,
      workspacePath: event.workspacePath,
    );

    output.writeln();
    output.writeln(ansi ? '\x1b[1;33m⚠️  [$title]\x1b[0m' : '⚠️  [$title]');
    output.writeln('   Tool:        $tool');
    output.writeln('   Permission:  $permClass');

    for (final d in details) {
      if (d.key != null && d.key != 'Tool' && d.key != 'Workspace') {
        final label = '${d.key}:'.padRight(12);
        output.writeln('   $label ${d.value}');
      }
    }
    if (wsName.isNotEmpty) {
      output.writeln('   Workspace:   $wsName');
    }

    final options = [
      'Yes, allow this time',
      'Yes, allow for this session',
      'Yes, always allow in this workspace',
      'No (deny)',
    ];

    final shortcutMap = {
      'y': 0,
      'yes': 0,
      '1': 0,
      's': 1,
      'session': 1,
      '2': 1,
      'w': 2,
      'workspace': 2,
      '3': 2,
      'n': 3,
      'no': 3,
      'deny': 3,
      '4': 3,
    };

    final choiceIndex = await lineReader.selectOption(
      title: ansi ? '\x1b[1;36mAllow execution?\x1b[0m' : 'Allow execution?',
      options: options,
      defaultIndex: 0,
      shortcutMap: shortcutMap,
    );

    switch (choiceIndex) {
      case 0:
        return const PermissionResult(
          allowed: true,
          scope: 'once',
          decision: 'allow',
        );
      case 1:
        return const PermissionResult(
          allowed: true,
          scope: 'session',
          decision: 'allow',
        );
      case 2:
        return const PermissionResult(
          allowed: true,
          scope: 'workspace',
          decision: 'allow',
        );
      default:
        String? comment;
        if (ansi) {
          final feedback = await lineReader.readLine(
            prompt:
                '\x1b[90mTell the agent what to do instead (optional) > \x1b[0m',
          );
          if (feedback != null && feedback.trim().isNotEmpty) {
            comment = feedback.trim();
          }
        }
        return PermissionResult(
          allowed: false,
          scope: 'once',
          decision: 'deny',
          comment: comment,
        );
    }
  }
}
