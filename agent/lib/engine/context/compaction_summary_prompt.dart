import 'dart:convert';

import 'package:sanad_agent/core/secrets_redactor.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';

import 'compaction_tail_selector.dart';
import 'compaction_token_estimator.dart';

/// Versioned provider-backed summary contract (Task 53i).
abstract final class CompactionSummaryPrompt {
  CompactionSummaryPrompt._();

  static const int defaultMaxPromptTokens = 24_000;
  static const SecretsRedactor _redactor = SecretsRedactor();

  static const allowedKeys = <String>{
    'schemaVersion',
    'currentGoal',
    'latestUserRequest',
    'successCriteria',
    'constraints',
    'completedWork',
    'activeState',
    'criticalContext',
    'decisions',
    'blockers',
    'filesAndPaths',
    'pendingAsks',
    'remainingWork',
  };

  /// The only semantic input appended to the ordinary provider projection.
  static String buildJsonInstruction({
    List<String> missingFields = const [],
    bool partial = false,
  }) {
    final repair = missingFields.isEmpty
        ? ''
        : ' Your previous attempt was invalid. Ensure these fields are present and non-empty: ${missingFields.join(', ')}.';
    final scope = partial
        ? 'Summarize only the supplied contiguous conversation span as a partial checkpoint.'
        : 'Summarize the entire conversation visible before this message as one rolling internal checkpoint.';
    return '''
$scope Preserve the conversation's primary language. Preserve paths, URLs, UUIDs, hashes, ports, numbers, error text, tool outcomes, active constraints, and pending asks literally when needed for continuation. Do not use any tool calls even though the normal tool list remains available. Return only the final JSON object, with no Markdown, reasoning, or surrounding text. Keep it within about two pages of reading.$repair

The JSON schema version is ${CompactionInternalSummary.schemaVersion}. Use exactly these keys; every value except schemaVersion must be a string:
${jsonEncode({'schemaVersion': CompactionInternalSummary.schemaVersion, 'currentGoal': 'goal being pursued now', 'latestUserRequest': 'latest user request that still requires continuation', 'successCriteria': 'observable success criteria, or none', 'constraints': 'active constraints and user preferences, or none', 'completedWork': 'completed work and verified results, or none', 'activeState': 'current state and in-progress work', 'criticalContext': 'facts that must not be lost', 'decisions': 'key decisions and rationale, or none', 'blockers': 'blockers, errors, and unresolved questions, or none', 'filesAndPaths': 'relevant files, symbols, identifiers, and external state, or none', 'pendingAsks': 'pending user asks, or none', 'remainingWork': 'remaining work and safest next action'})}
FINAL REQUIREMENT: Do not use any tool calls; return only the final JSON object.
'''
        .trim();
  }

  /// Test-only bounded fixture prompt. Production never reserializes history.
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
    final result = <String>[];
    for (
      var i = 0;
      i < sourceMessages.length && result.length < maxPasses;
      i += chunkSize
    ) {
      result.add(
        build(
          sourceMessages: sourceMessages.sublist(
            i,
            (i + chunkSize).clamp(0, sourceMessages.length),
          ),
          previousSummary: i == 0 ? previousSummary : null,
        ),
      );
    }
    return result;
  }

  static String build({
    required List<IndexedConversationMessage> sourceMessages,
    CompactionInternalSummary? previousSummary,
  }) {
    final buffer = StringBuffer()
      ..writeln(buildJsonInstruction())
      ..writeln();
    if (previousSummary != null) {
      buffer
        ..writeln('Previous summary anchor:')
        ..writeln(_redactor.redact(formatSummary(previousSummary)))
        ..writeln();
    }
    buffer.writeln('Conversation span to summarize:');
    for (final entry in sourceMessages) {
      final message = entry.message;
      buffer.writeln(
        '[${entry.rowId}] ${message.role.name}: ${_redactor.redact(message.content ?? '')}',
      );
      for (final call in message.toolCalls ?? const []) {
        buffer.writeln(
          '  tool_call ${call.name}(${_redactor.redact(call.arguments.toString())})',
        );
      }
    }
    return buffer.toString();
  }

  static String formatSummary(CompactionInternalSummary summary) => [
    'Goal: ${summary.currentGoal}',
    'Latest user request: ${summary.latestUserRequest}',
    if ((summary.successCriteria ?? '').isNotEmpty)
      'Success: ${summary.successCriteria}',
    if ((summary.constraints ?? '').isNotEmpty)
      'Constraints: ${summary.constraints}',
    if ((summary.completedWork ?? '').isNotEmpty)
      'Completed: ${summary.completedWork}',
    'Active: ${summary.activeState}',
    'Critical context: ${summary.criticalContext}',
    if ((summary.decisions ?? '').isNotEmpty) 'Decisions: ${summary.decisions}',
    if ((summary.blockers ?? '').isNotEmpty) 'Blockers: ${summary.blockers}',
    if ((summary.filesAndPaths ?? '').isNotEmpty)
      'Files: ${summary.filesAndPaths}',
    if ((summary.pendingAsks ?? '').isNotEmpty)
      'Pending asks: ${summary.pendingAsks}',
    'Remaining: ${summary.remainingWork}',
  ].join('\n');

  static Map<String, dynamic> toJsonMap(CompactionInternalSummary summary) => {
    'schemaVersion': CompactionInternalSummary.schemaVersion,
    'currentGoal': summary.currentGoal,
    'latestUserRequest': summary.latestUserRequest,
    'successCriteria': summary.successCriteria ?? '',
    'constraints': summary.constraints ?? '',
    'completedWork': summary.completedWork ?? '',
    'activeState': summary.activeState ?? '',
    'criticalContext': summary.criticalContext,
    'decisions': summary.decisions ?? '',
    'blockers': summary.blockers ?? '',
    'filesAndPaths': summary.filesAndPaths ?? '',
    'pendingAsks': summary.pendingAsks ?? '',
    'remainingWork': summary.remainingWork ?? '',
  };
}

/// Strict JSON parser for provider-backed summary output.
abstract final class CompactionSummaryParser {
  CompactionSummaryParser._();

  static final RegExp _reasoningTag = RegExp(
    r'<think>[\s\S]*?</think>|<reasoning>[\s\S]*?</reasoning>',
    caseSensitive: false,
  );

  static String stripProviderOnlyMarkup(String response) =>
      response.replaceAll(_reasoningTag, '').trim();

  static CompactionInternalSummary parse(String response) {
    final cleaned = stripProviderOnlyMarkup(response);
    _rejectDuplicateKeys(cleaned);
    final decoded = jsonDecode(cleaned);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('compaction summary must be a JSON object');
    }
    final unknown = decoded.keys.toSet().difference(
      CompactionSummaryPrompt.allowedKeys,
    );
    if (unknown.isNotEmpty) {
      throw FormatException(
        'unknown compaction summary keys: ${unknown.join(', ')}',
      );
    }
    if (decoded['schemaVersion'] != CompactionInternalSummary.schemaVersion) {
      throw const FormatException('unsupported compaction summary schema');
    }
    String value(String key) {
      final raw = decoded[key];
      if (raw is! String) throw FormatException('$key must be a string');
      return raw.trim();
    }

    return CompactionInternalSummary(
      currentGoal: value('currentGoal'),
      latestUserRequest: value('latestUserRequest'),
      successCriteria: value('successCriteria'),
      constraints: value('constraints'),
      completedWork: value('completedWork'),
      activeState: value('activeState'),
      criticalContext: value('criticalContext'),
      decisions: value('decisions'),
      blockers: value('blockers'),
      filesAndPaths: value('filesAndPaths'),
      pendingAsks: value('pendingAsks'),
      remainingWork: value('remainingWork'),
    );
  }

  /// Compatibility parser used only by the deterministic test summarizer.
  static CompactionInternalSummary parseLegacy(String response) {
    final cleaned = stripProviderOnlyMarkup(response);
    String section(String label) =>
        RegExp(
          '$label:\\s*(.+?)(?=\\n[A-Z]|\\n\\n|\$)',
          dotAll: true,
        ).firstMatch(cleaned)?.group(1)?.trim() ??
        '';
    final goal = section('Current Goal and Success Criteria').isNotEmpty
        ? section('Current Goal and Success Criteria')
        : section('Goal');
    final active = section('Current State and In-Progress Work');
    final remaining =
        section('Remaining Work and Safest Next Action').isNotEmpty
        ? section('Remaining Work and Safest Next Action')
        : section('Remaining Work');
    return CompactionInternalSummary(
      currentGoal: goal,
      latestUserRequest: goal,
      successCriteria: section('Success Criteria'),
      constraints: section('Active Constraints and User Preferences'),
      completedWork: section('Completed Work and Verified Results'),
      activeState: active.isEmpty ? 'Awaiting next safe action.' : active,
      criticalContext: goal,
      decisions: section('Key Decisions and Rationale'),
      blockers: section('Blockers, Errors, and Unresolved Questions'),
      pendingAsks: section('Pending User Asks'),
      filesAndPaths: section(
        'Relevant Files, Symbols, IDs, and External State',
      ),
      remainingWork: remaining,
    );
  }

  static void _rejectDuplicateKeys(String json) {
    final seen = <String>{};
    var objectDepth = 0;
    var arrayDepth = 0;
    var stringStart = -1;
    var escaped = false;
    var expectTopLevelKey = false;
    for (var index = 0; index < json.length; index++) {
      final char = json[index];
      if (stringStart >= 0) {
        if (escaped) {
          escaped = false;
        } else if (char == r'\') {
          escaped = true;
        } else if (char == '"') {
          if (objectDepth == 1 && arrayDepth == 0 && expectTopLevelKey) {
            var cursor = index + 1;
            while (cursor < json.length && json[cursor].trim().isEmpty) {
              cursor++;
            }
            if (cursor < json.length && json[cursor] == ':') {
              final key = jsonDecode(json.substring(stringStart, index + 1));
              if (key is String && !seen.add(key)) {
                throw FormatException('duplicate compaction summary key: $key');
              }
              expectTopLevelKey = false;
            }
          }
          stringStart = -1;
        }
        continue;
      }
      switch (char) {
        case '"':
          stringStart = index;
        case '{':
          objectDepth++;
          if (objectDepth == 1) expectTopLevelKey = true;
        case '}':
          objectDepth--;
        case '[':
          arrayDepth++;
        case ']':
          arrayDepth--;
        case ',':
          if (objectDepth == 1 && arrayDepth == 0) {
            expectTopLevelKey = true;
          }
      }
    }
  }
}
