import 'dart:convert';

import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/utils/tool_presentation_helper.dart';

enum ConversationActivityKind { reasoning, runningTool, thinking }

class ConversationActivity {
  const ConversationActivity._({
    required this.kind,
    this.event,
  });

  const ConversationActivity.reasoning(CanonicalEvent event)
    : this._(kind: ConversationActivityKind.reasoning, event: event);

  const ConversationActivity.runningTool(CanonicalEvent event)
    : this._(kind: ConversationActivityKind.runningTool, event: event);

  const ConversationActivity.thinking() : this._(kind: ConversationActivityKind.thinking);

  final ConversationActivityKind kind;
  final CanonicalEvent? event;
}

class ConversationTimelineItem {
  const ConversationTimelineItem._({
    required this.id,
    required this.events,
    this.toolSummary,
    this.activity,
  });

  factory ConversationTimelineItem.event(CanonicalEvent event) =>
      ConversationTimelineItem._(id: event.id, events: [event]);

  factory ConversationTimelineItem.toolGroup(List<CanonicalEvent> events) {
    assert(events.isNotEmpty);
    final stableEvents = List<CanonicalEvent>.unmodifiable(events);
    return ConversationTimelineItem._(
      id: stableEvents.first.id,
      events: stableEvents,
      toolSummary: ToolGroupSummary.fromEvents(stableEvents),
    );
  }

  factory ConversationTimelineItem.activity({
    required String id,
    required ConversationActivity activity,
  }) => ConversationTimelineItem._(
    id: id,
    events: const [],
    activity: activity,
  );

  final String id;
  final List<CanonicalEvent> events;
  final ToolGroupSummary? toolSummary;
  final ConversationActivity? activity;

  bool get isToolGroup => toolSummary != null;
  bool get isActivity => activity != null;
  CanonicalEvent get event => events.single;
  bool containsEventId(String eventId) => events.any((event) => event.id == eventId);
}

List<ConversationTimelineItem> projectConversationTimeline(
  List<CanonicalEvent> events, {
  List<ConversationTimelineItem> previousItems = const [],
  bool activityEligible = false,
  String? activityIdentity,
}) {
  final items = <ConversationTimelineItem>[];
  final toolRun = <CanonicalEvent>[];
  final previousById = {
    for (final item in previousItems) item.id: item,
  };
  final currentTurnStart = events.lastIndexWhere(
    (event) => event.kind == EventKind.userMessage,
  );
  final currentTurnEvents = events.skip(currentTurnStart + 1).toList(growable: false);

  ConversationTimelineItem reuseOrCreate(
    List<CanonicalEvent> projectedEvents, {
    required bool asGroup,
  }) {
    final previous = previousById[projectedEvents.first.id];
    if (previous != null &&
        previous.isToolGroup == asGroup &&
        previous.events.length == projectedEvents.length &&
        _sameEventInstances(previous.events, projectedEvents)) {
      return previous;
    }
    return asGroup
        ? ConversationTimelineItem.toolGroup(projectedEvents)
        : ConversationTimelineItem.event(projectedEvents.single);
  }

  void flushTools() {
    if (toolRun.isEmpty) return;
    items.add(
      reuseOrCreate(toolRun, asGroup: toolRun.length > 1),
    );
    toolRun.clear();
  }

  for (final event in events) {
    final isAskUser = event.kind == EventKind.toolCall && event.toolName == 'system_ask_user';
    if (isAskUser) {
      flushTools();
      if (event.status != EventStatus.running) {
        items.add(reuseOrCreate([event], asGroup: false));
      }
      continue;
    }

    if (event.kind == EventKind.toolCall) {
      toolRun.add(event);
      continue;
    }

    flushTools();
    if (event.kind != EventKind.reasoning) {
      items.add(reuseOrCreate([event], asGroup: false));
    }
  }

  flushTools();
  ConversationTimelineItem? previousActivity;
  for (final item in previousItems.reversed) {
    if (item.isActivity) {
      previousActivity = item;
      break;
    }
  }
  _appendCurrentActivity(
    items,
    currentTurnEvents,
    activityEligible: activityEligible,
    previousActivity: previousActivity,
    activityIdentity: activityIdentity,
  );
  return List<ConversationTimelineItem>.unmodifiable(items);
}

void _appendCurrentActivity(
  List<ConversationTimelineItem> items,
  List<CanonicalEvent> currentTurnEvents, {
  required bool activityEligible,
  required ConversationTimelineItem? previousActivity,
  String? activityIdentity,
}) {
  if (!activityEligible) return;

  final latestEvent = currentTurnEvents.isEmpty ? null : currentTurnEvents.last;
  if (latestEvent != null && (latestEvent.status == EventStatus.error || latestEvent.kind == EventKind.error)) {
    return;
  }

  final activeReasoning =
      latestEvent != null && latestEvent.kind == EventKind.reasoning && latestEvent.status == EventStatus.running
      ? latestEvent
      : null;
  ConversationTimelineItem? activeGroup;
  if (latestEvent != null && latestEvent.kind == EventKind.toolCall && latestEvent.toolName != 'system_ask_user') {
    for (final item in items.reversed) {
      if (item.isToolGroup && item.containsEventId(latestEvent.id)) {
        activeGroup = item;
        break;
      }
    }
  }

  ConversationActivity? activity;
  if (activeReasoning != null) {
    activity = ConversationActivity.reasoning(activeReasoning);
  } else if (activeGroup != null) {
    CanonicalEvent? runningTool;
    for (final event in activeGroup.events.reversed) {
      if (event.status == EventStatus.running) {
        runningTool = event;
        break;
      }
    }
    activity = runningTool == null
        ? const ConversationActivity.thinking()
        : ConversationActivity.runningTool(runningTool);
  } else if (previousActivity != null) {
    // Preserve the last confirmed activity through a temporary first standalone
    // tool or while the provider is working before the first reasoning/tool
    // event of the current turn arrives.
    final previousKind = previousActivity.activity!.kind;
    final isPreviousStillValid =
        previousKind == ConversationActivityKind.thinking ||
        previousKind == ConversationActivityKind.reasoning ||
        (previousKind == ConversationActivityKind.runningTool &&
            previousActivity.activity!.event != null &&
            previousActivity.activity!.event!.status == EventStatus.running);
    if (isPreviousStillValid) {
      final isTemporaryStandaloneTool =
          latestEvent != null && latestEvent.kind == EventKind.toolCall && latestEvent.toolName != 'system_ask_user';
      if (isTemporaryStandaloneTool) {
        items.add(previousActivity);
        return;
      }
      activity = previousActivity.activity;
    }
  }

  if (activity == null) {
    // No reasoning/tool available yet, but the turn is still authoritative
    // running/resuming. Show a generic working placeholder so the elapsed
    // timer and activity row remain visible to the user.
    if (activityIdentity != null && activityIdentity.isNotEmpty) {
      items.add(
        ConversationTimelineItem.activity(
          id: 'conversation-activity:$activityIdentity',
          activity: const ConversationActivity.thinking(),
        ),
      );
    } else if (previousActivity != null) {
      items.add(previousActivity);
    }
    return;
  }
  final identityEvent = activeGroup?.events.first ?? activeReasoning;
  final turnIdentity = identityEvent != null
      ? (identityEvent.runId ?? identityEvent.sessionId ?? identityEvent.modelStepId ?? identityEvent.id)
      : (activityIdentity ?? '');
  if (turnIdentity.isEmpty) return;
  items.add(
    ConversationTimelineItem.activity(
      id: 'conversation-activity:$turnIdentity',
      activity: activity,
    ),
  );
}

bool _sameEventInstances(
  List<CanonicalEvent> previous,
  List<CanonicalEvent> current,
) {
  for (var index = 0; index < current.length; index++) {
    if (!identical(previous[index], current[index])) return false;
  }
  return true;
}

class ToolGroupCountMetric {
  const ToolGroupCountMetric({
    required this.key,
    required this.value,
    required this.singularLabel,
    required this.pluralLabel,
  });

  final String key;
  final int value;
  final String singularLabel;
  final String pluralLabel;

  String get suffix => ' ${value == 1 ? singularLabel : pluralLabel}';
}

class ToolGroupSummary {
  const ToolGroupSummary({
    required this.toolCounts,
    required this.readFiles,
    required this.modifiedFiles,
    required this.addedLines,
    required this.removedLines,
  });

  factory ToolGroupSummary.fromEvents(List<CanonicalEvent> events) {
    final toolCounts = <String, int>{};
    final readFiles = <String>{};
    final modifiedFiles = <String>{};
    var addedLines = 0;
    var removedLines = 0;

    for (final event in events) {
      final name = event.toolName ?? 'tool';
      final label = _summaryLabel(name);
      toolCounts[label] = (toolCounts[label] ?? 0) + 1;

      final input = _mapValue(event.toolInput);
      final output = _mapValue(event.toolOutput);
      final path = _canonicalPath(
        input['path'] ?? input['file_path'] ?? output['filePath'] ?? output['path'] ?? _nestedFilePath(output['file']),
      );

      if (_isFileRead(name) && path != null) {
        readFiles.add(path);
      }
      if (_isFileMutation(name) && path != null) {
        modifiedFiles.add(path);
      }

      final changes = _lineChanges(name, input, output);
      addedLines += changes.$1;
      removedLines += changes.$2;
    }

    return ToolGroupSummary(
      toolCounts: Map<String, int>.unmodifiable(toolCounts),
      readFiles: Set<String>.unmodifiable(readFiles),
      modifiedFiles: Set<String>.unmodifiable(modifiedFiles),
      addedLines: addedLines,
      removedLines: removedLines,
    );
  }

  final Map<String, int> toolCounts;
  final Set<String> readFiles;
  final Set<String> modifiedFiles;
  final int addedLines;
  final int removedLines;

  List<String> get activitySegments => [
    for (final entry in toolCounts.entries) '${entry.value} ${entry.value == 1 ? entry.key : _pluralLabel(entry.key)}',
  ];

  List<ToolGroupCountMetric> get headerMetrics {
    final metrics = <ToolGroupCountMetric>[];
    const fileLabels = {
      'file read',
      'file write',
      'file edit',
      'file search',
    };
    final skillLoads = toolCounts['skill load'] ?? 0;
    if (skillLoads > 0) {
      metrics.add(
        ToolGroupCountMetric(
          key: 'skill-load',
          value: skillLoads,
          singularLabel: 'skill load',
          pluralLabel: 'skill loads',
        ),
      );
    }
    for (final entry in toolCounts.entries) {
      if (fileLabels.contains(entry.key) || entry.key == 'skill load') {
        continue;
      }
      metrics.add(
        ToolGroupCountMetric(
          key: entry.key,
          value: entry.value,
          singularLabel: entry.key,
          pluralLabel: _pluralLabel(entry.key),
        ),
      );
    }

    final fileSearches = toolCounts['file search'] ?? 0;
    if (fileSearches > 0) {
      metrics.add(
        ToolGroupCountMetric(
          key: 'file-search',
          value: fileSearches,
          singularLabel: 'file search',
          pluralLabel: 'file searches',
        ),
      );
    }
    final fileReads = toolCounts['file read'] ?? 0;
    if (fileReads > 0) {
      metrics.add(
        ToolGroupCountMetric(
          key: 'file-read',
          value: fileReads,
          singularLabel: 'file explore',
          pluralLabel: 'file explores',
        ),
      );
    }
    if (modifiedFiles.isNotEmpty) {
      metrics.add(
        ToolGroupCountMetric(
          key: 'modified-files',
          value: modifiedFiles.length,
          singularLabel: 'file modified',
          pluralLabel: 'files modified',
        ),
      );
    }
    return List<ToolGroupCountMetric>.unmodifiable(metrics);
  }

  static String _pluralLabel(String label) {
    if (label.endsWith('search')) return '${label}es';
    if (label.endsWith('fetch')) return '${label}es';
    return '${label}s';
  }

  static String _summaryLabel(String rawName) {
    final name = rawName.toLowerCase();
    if (name.startsWith('mcp__')) {
      final parts = name.split('__');
      final server = parts.length > 1 && parts[1].isNotEmpty ? parts[1].replaceAll(RegExp(r'[_-]+'), ' ') : 'mcp';
      return '$server tool';
    }
    if (name == 'file_read' || name.endsWith('__file_read')) {
      return 'file read';
    }
    if (name == 'file_write' || name.endsWith('__file_write')) {
      return 'file write';
    }
    if (name == 'file_edit' || name.endsWith('__file_edit')) {
      return 'file edit';
    }
    if (name == 'search_glob' ||
        name == 'search_grep' ||
        name.endsWith('__search_glob') ||
        name.endsWith('__search_grep')) {
      return 'file search';
    }
    if (name == 'shell_execute' || name.contains('terminal')) {
      return 'terminal run';
    }
    if (name == 'web_search') return 'web search';
    if (name == 'web_fetch') return 'web fetch';
    if (name == 'skill_load') return 'skill load';
    return ToolPresentationHelper.cleanToolTitle(rawName).toLowerCase();
  }

  static bool _isFileRead(String name) {
    final normalized = name.toLowerCase();
    return normalized == 'file_read' || normalized.endsWith('__file_read');
  }

  static bool _isFileMutation(String name) {
    final normalized = name.toLowerCase();
    return normalized == 'file_write' ||
        normalized == 'file_edit' ||
        normalized.endsWith('__file_write') ||
        normalized.endsWith('__file_edit');
  }

  static (int, int) _lineChanges(
    String name,
    Map<String, dynamic> input,
    Map<String, dynamic> output,
  ) {
    final normalized = name.toLowerCase();
    if (normalized == 'file_write' || normalized.endsWith('__file_write')) {
      return (_lineCount(input['content']?.toString()), 0);
    }
    if (normalized != 'file_edit' && !normalized.endsWith('__file_edit')) {
      return (0, 0);
    }

    final oldString = input['old_string']?.toString();
    final newString = input['new_string']?.toString();
    if (oldString != null || newString != null) {
      return (_lineCount(newString), _lineCount(oldString));
    }

    final patch = output['patch']?.toString();
    if (patch == null || patch.trim().isEmpty) return (0, 0);
    var added = 0;
    var removed = 0;
    for (final line in const LineSplitter().convert(patch)) {
      if (line.startsWith('+') && !line.startsWith('+++')) {
        added++;
      } else if (line.startsWith('-') && !line.startsWith('---')) {
        removed++;
      }
    }
    return (added, removed);
  }

  static int _lineCount(String? value) {
    if (value == null || value.isEmpty) return 0;
    return '\n'.allMatches(value).length + 1;
  }

  static Map<String, dynamic> _mapValue(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    if (value is String) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    return const {};
  }

  static dynamic _nestedFilePath(dynamic value) {
    if (value is! Map) return null;
    return value['filePath'] ?? value['path'];
  }

  static String? _canonicalPath(dynamic value) {
    final path = value?.toString().trim();
    if (path == null || path.isEmpty) return null;
    return path.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  }
}
