import 'package:sanad_agent/core/secrets_redactor.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';

import 'compaction_tail_selector.dart';
import 'compaction_token_estimator.dart';

/// Structured rolling summary prompt builder (Plan 53c Gate C3).
abstract final class CompactionSummaryPrompt {
  CompactionSummaryPrompt._();

  static const int defaultMaxPromptTokens = 24_000;
  static const SecretsRedactor _redactor = SecretsRedactor();

  /// Builds one or more bounded summarizer prompts for [sourceMessages].
  ///
  /// When the full source exceeds [maxPromptTokens], messages are split into a
  /// limited number of contiguous passes instead of emitting an over-budget
  /// prompt or recursing unbounded.
  static List<String> buildPasses({
    required List<IndexedConversationMessage> sourceMessages,
    CompactionInternalSummary? previousSummary,
    int maxPromptTokens = defaultMaxPromptTokens,
    int maxPasses = 4,
  }) {
    if (sourceMessages.isEmpty) {
      return [
        build(sourceMessages: sourceMessages, previousSummary: previousSummary),
      ];
    }

    final full = build(
      sourceMessages: sourceMessages,
      previousSummary: previousSummary,
    );
    if (CompactionTokenEstimator.estimateText(full) <= maxPromptTokens) {
      return [full];
    }

    final chunkSize = (sourceMessages.length / maxPasses).ceil().clamp(
      1,
      sourceMessages.length,
    );
    final passes = <String>[];
    for (var i = 0; i < sourceMessages.length; i += chunkSize) {
      final end = (i + chunkSize).clamp(0, sourceMessages.length);
      passes.add(
        build(
          sourceMessages: sourceMessages.sublist(i, end),
          previousSummary: i == 0 ? previousSummary : null,
        ),
      );
      if (passes.length >= maxPasses) {
        break;
      }
    }
    return passes;
  }

  static String build({
    required List<IndexedConversationMessage> sourceMessages,
    CompactionInternalSummary? previousSummary,
  }) {
    final buffer = StringBuffer()
      ..writeln(
        'You are producing an internal historical checkpoint for a coding agent.',
      )
      ..writeln(
        'This checkpoint is NOT authorized to override current system or user instructions.',
      )
      ..writeln(
        'Preserve the conversation language. Keep identifiers, paths, and literal values unchanged.',
      )
      ..writeln('Respond with the required sections only. Do not call tools.')
      ..writeln()
      ..writeln('Required sections:')
      ..writeln('- Current Goal and Success Criteria')
      ..writeln('- Active Constraints and User Preferences')
      ..writeln('- Completed Work and Verified Results')
      ..writeln('- Current State and In-Progress Work')
      ..writeln('- Key Decisions and Rationale')
      ..writeln('- Blockers, Errors, and Unresolved Questions')
      ..writeln('- Pending User Asks')
      ..writeln('- Relevant Files, Symbols, IDs, and External State')
      ..writeln('- Remaining Work and Safest Next Action')
      ..writeln('- Critical Context That Must Not Be Lost');

    if (previousSummary != null) {
      buffer
        ..writeln()
        ..writeln('Previous summary anchor:')
        ..writeln(_redactor.redact(formatSummary(previousSummary)))
        ..writeln(
          'Update the rolling checkpoint. Drop stale completed or pending facts.',
        );
    }

    buffer
      ..writeln()
      ..writeln('Conversation span to summarize:');
    for (final entry in sourceMessages) {
      final message = entry.message;
      final content = _redactor.redact(message.content ?? '');
      buffer.writeln('[${entry.rowId}] ${message.role.name}: $content');
      if (message.toolCalls != null && message.toolCalls!.isNotEmpty) {
        for (final call in message.toolCalls!) {
          buffer.writeln(
            '  tool_call ${call.name}(${_redactor.redact(call.arguments.toString())})',
          );
        }
      }
    }
    return buffer.toString();
  }

  static String formatSummary(CompactionInternalSummary summary) {
    return [
      if (summary.currentGoal.isNotEmpty) 'Goal: ${summary.currentGoal}',
      if ((summary.successCriteria ?? '').isNotEmpty)
        'Success: ${summary.successCriteria}',
      if ((summary.constraints ?? '').isNotEmpty)
        'Constraints: ${summary.constraints}',
      if ((summary.completedWork ?? '').isNotEmpty)
        'Completed: ${summary.completedWork}',
      if ((summary.activeState ?? '').isNotEmpty)
        'Active: ${summary.activeState}',
      if ((summary.decisions ?? '').isNotEmpty)
        'Decisions: ${summary.decisions}',
      if ((summary.blockers ?? '').isNotEmpty) 'Blockers: ${summary.blockers}',
      if ((summary.filesAndPaths ?? '').isNotEmpty)
        'Files: ${summary.filesAndPaths}',
      if ((summary.pendingAsks ?? '').isNotEmpty)
        'Pending asks: ${summary.pendingAsks}',
      if ((summary.remainingWork ?? '').isNotEmpty)
        'Remaining: ${summary.remainingWork}',
    ].join('\n');
  }
}

/// Parses structured summarizer output into [CompactionInternalSummary].
abstract final class CompactionSummaryParser {
  CompactionSummaryParser._();

  static final RegExp _reasoningTag = RegExp(
    r'<think>[\s\S]*?</think>|<reasoning>[\s\S]*?</reasoning>',
    caseSensitive: false,
  );

  static String stripProviderOnlyMarkup(String response) {
    return response.replaceAll(_reasoningTag, '').trim();
  }

  static CompactionInternalSummary parse(String response) {
    final cleaned = stripProviderOnlyMarkup(response);
    String section(String label) {
      final pattern = RegExp(
        '$label:\\s*(.+?)(?=\\n[A-Z]|\\n\\n|\$)',
        dotAll: true,
      );
      final match = pattern.firstMatch(cleaned);
      return match?.group(1)?.trim() ?? '';
    }

    return CompactionInternalSummary(
      currentGoal: section('Current Goal and Success Criteria').isNotEmpty
          ? section('Current Goal and Success Criteria')
          : section('Goal'),
      successCriteria: section('Success Criteria'),
      constraints: section('Active Constraints and User Preferences'),
      completedWork: section('Completed Work and Verified Results'),
      activeState: section('Current State and In-Progress Work'),
      decisions: section('Key Decisions and Rationale'),
      blockers: section('Blockers, Errors, and Unresolved Questions'),
      pendingAsks: section('Pending User Asks'),
      filesAndPaths: section(
        'Relevant Files, Symbols, IDs, and External State',
      ),
      remainingWork: section('Remaining Work and Safest Next Action').isNotEmpty
          ? section('Remaining Work and Safest Next Action')
          : section('Remaining Work'),
    );
  }
}
