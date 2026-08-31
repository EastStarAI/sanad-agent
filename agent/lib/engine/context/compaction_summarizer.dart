import 'package:sanad_agent/core/secrets_redactor.dart';

/// Provider-neutral summarizer contract (Plan 53c Gate C3).
abstract class CompactionSummarizer {
  Future<String> summarize({required String prompt});
}

/// Deterministic summarizer for tests and offline validation.
///
/// Never invokes tools. Strips secret-shaped spans before returning text.
class StructuredCompactionSummarizer implements CompactionSummarizer {
  static const SecretsRedactor _redactor = SecretsRedactor();

  @override
  Future<String> summarize({required String prompt}) async {
    if (prompt.contains('tool_call_request') ||
        prompt.contains('"name": "tool"')) {
      throw StateError('compaction summarizer must not execute tools');
    }
    final goalMatch = RegExp(
      r'goal:\s*(.+)',
      caseSensitive: false,
    ).firstMatch(prompt);
    final pathMatch = RegExp(
      r'path:\s*(.+)',
      caseSensitive: false,
    ).firstMatch(prompt);
    final blockerMatch = RegExp(
      r'blocker:\s*(.+)',
      caseSensitive: false,
    ).firstMatch(prompt);
    final goal = goalMatch?.group(1)?.trim() ?? 'Continue current task';
    final path = pathMatch?.group(1)?.trim();
    final blocker = blockerMatch?.group(1)?.trim() ?? 'None recorded.';
    final body =
        '''
Current Goal and Success Criteria: $goal
Active Constraints and User Preferences: Preserve existing user preferences.
Completed Work and Verified Results: Prior work captured in checkpoint.
Current State and In-Progress Work: Awaiting next safe action.
Key Decisions and Rationale: Continue with validated plan.
Blockers, Errors, and Unresolved Questions: $blocker
Pending User Asks: None.
Relevant Files, Symbols, IDs, and External State: ${path ?? 'none'}
Remaining Work and Safest Next Action: Execute the next verified step toward the goal.
Critical Context That Must Not Be Lost: $goal
''';
    return _redactor.redact(body);
  }
}
