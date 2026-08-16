import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/utils/conversation_timeline_projection.dart';

void main() {
  group('projectConversationTimeline', () {
    test('keeps one completed tool standalone and groups from the second', () {
      final first = _tool('first', 'file_read');
      final second = _tool('second', 'shell_execute');

      final one = projectConversationTimeline([first]);
      expect(one, hasLength(1));
      expect(one.single.isToolGroup, isFalse);

      final two = projectConversationTimeline([first, second]);
      expect(two, hasLength(1));
      expect(two.single.isToolGroup, isTrue);
      expect(two.single.id, first.id);
      expect(two.single.events, [first, second]);
    });

    test('ask-user and running tools split completed groups', () {
      final items = projectConversationTimeline([
        _tool('done-1', 'file_read'),
        _tool('done-2', 'file_edit'),
        _tool('ask', 'system_ask_user'),
        _tool('done-3', 'web_search'),
        _tool('running', 'shell_execute', status: EventStatus.running),
        _tool('done-4', 'web_fetch'),
        _tool('done-5', 'skill_load'),
      ]);

      expect(items, hasLength(3));
      expect(items[0].events.map((event) => event.id), ['done-1', 'done-2']);
      expect(items[1].event.id, 'ask');
      expect(items[2].events.map((event) => event.id), [
        'done-3',
        'running',
        'done-4',
        'done-5',
      ]);
    });

    test('groups every running batch item from the second tool onward', () {
      final items = projectConversationTimeline([
        _tool('running-1', 'file_read', status: EventStatus.running),
        _tool('running-2', 'file_edit', status: EventStatus.running),
        _tool('running-3', 'shell_execute', status: EventStatus.running),
      ]);

      expect(items, hasLength(1));
      expect(items.single.isToolGroup, isTrue);
      expect(items.single.events.map((event) => event.id), [
        'running-1',
        'running-2',
        'running-3',
      ]);
    });

    test('moves the latest batch tool into the group when it completes', () {
      final items = projectConversationTimeline([
        _tool('done-1', 'file_read'),
        _tool('done-2', 'file_edit'),
      ]);

      expect(items, hasLength(1));
      expect(items.single.isToolGroup, isTrue);
      expect(items.single.events.map((event) => event.id), [
        'done-1',
        'done-2',
      ]);
    });

    test('reuses unchanged projected items and summaries by identity', () {
      final events = [
        _tool('first', 'file_read'),
        _tool('second', 'web_search'),
        CanonicalEvent(
          id: 'answer',
          kind: EventKind.finalAnswer,
          text: 'done',
          timestamp: DateTime.utc(2026, 8, 14),
        ),
      ];
      final firstProjection = projectConversationTimeline(events);
      final secondProjection = projectConversationTimeline(
        List<CanonicalEvent>.from(events),
        previousItems: firstProjection,
      );

      expect(identical(secondProjection[0], firstProjection[0]), isTrue);
      expect(identical(secondProjection[1], firstProjection[1]), isTrue);
    });

    test('hides a running ask-user event completely', () {
      final items = projectConversationTimeline([
        _tool(
          'ask-running',
          'system_ask_user',
          status: EventStatus.running,
        ),
      ]);

      expect(items, isEmpty);
    });

    test('activity is gated and always projects at the current tail', () {
      final events = [
        CanonicalEvent(
          id: 'user',
          kind: EventKind.userMessage,
          text: 'start',
          timestamp: DateTime.utc(2026, 8, 16),
        ),
        _tool('old-1', 'file_read'),
        _tool('old-2', 'file_edit'),
        _tool('ask', 'system_ask_user'),
        CanonicalEvent(
          id: 'reasoning',
          kind: EventKind.reasoning,
          status: EventStatus.running,
          text: 'checking the next action carefully',
          runId: 'run-1',
          timestamp: DateTime.utc(2026, 8, 16),
        ),
      ];

      final inactive = projectConversationTimeline(events);
      expect(inactive.any((item) => item.isActivity), isFalse);

      final active = projectConversationTimeline(
        events,
        activityEligible: true,
      );
      expect(active.last.isActivity, isTrue);
      expect(active.last.activity!.kind, ConversationActivityKind.reasoning);
      expect(active[active.length - 2].event.id, 'ask');
    });

    test('retains confirmed activity through a temporary standalone tool', () {
      final user = CanonicalEvent(
        id: 'user',
        kind: EventKind.userMessage,
        text: 'start',
        timestamp: DateTime.utc(2026, 8, 16),
      );
      final reasoning = CanonicalEvent(
        id: 'reasoning',
        kind: EventKind.reasoning,
        status: EventStatus.running,
        text: 'checking the next action carefully',
        runId: 'run-1',
        timestamp: DateTime.utc(2026, 8, 16),
      );
      final previous = projectConversationTimeline(
        [user, reasoning],
        activityEligible: true,
      );

      final next = projectConversationTimeline(
        [
          user,
          _tool(
            'tool-1',
            'file_read',
            status: EventStatus.running,
            runId: 'run-1',
          ),
        ],
        previousItems: previous,
        activityEligible: true,
      );

      expect(next[next.length - 2].event.id, 'tool-1');
      expect(identical(next.last, previous.last), isTrue);
    });

    test('puts skill loads first while retaining terminal run wording', () {
      final summary = projectConversationTimeline([
        _tool('terminal', 'shell_execute'),
        _tool('skill-1', 'skill_load'),
        _tool('skill-2', 'skill_load'),
        _tool('web', 'web_search'),
      ]).single.toolSummary!;

      expect(
        summary.headerMetrics.map((metric) => '${metric.value}${metric.suffix}'),
        ['2 skill loads', '1 terminal run', '1 web search'],
      );
    });

    test('aggregates MCP tools by server instead of individual operation', () {
      final summary = projectConversationTimeline([
        _tool('github-search', 'mcp__github__search_repositories'),
        _tool('github-issue', 'mcp__github__get_issue'),
        _tool('clickup-task', 'mcp__clickup__get_task'),
      ]).single.toolSummary!;

      expect(summary.toolCounts, {
        'github tool': 2,
        'clickup tool': 1,
      });
      expect(
        summary.headerMetrics.map((metric) => '${metric.value}${metric.suffix}'),
        ['2 github tools', '1 clickup tool'],
      );
    });

    test('aggregates kinds unique files and line changes', () {
      final items = projectConversationTimeline([
        _tool(
          'read-1',
          'file_read',
          input: const {'path': r'lib\same.dart'},
        ),
        _tool(
          'read-2',
          'file_read',
          input: const {'path': 'lib/same.dart'},
        ),
        _tool(
          'edit-1',
          'file_edit',
          input: const {
            'path': 'lib/changed.dart',
            'old_string': 'old\nline',
            'new_string': 'new\nline\nadded',
          },
        ),
        _tool(
          'edit-2',
          'file_edit',
          status: EventStatus.error,
          input: const {'path': 'lib/changed.dart'},
          output: const {'patch': '-removed\n+added'},
        ),
        _tool('terminal', 'shell_execute'),
        _tool('web', 'web_search'),
      ]);

      final summary = items.single.toolSummary!;
      expect(summary.toolCounts, {
        'file read': 2,
        'file edit': 2,
        'terminal run': 1,
        'web search': 1,
      });
      expect(summary.readFiles, {'lib/same.dart'});
      expect(summary.modifiedFiles, {'lib/changed.dart'});
      expect(summary.addedLines, 4);
      expect(summary.removedLines, 3);
      expect(summary.activitySegments, [
        '2 file reads',
        '2 file edits',
        '1 terminal run',
        '1 web search',
      ]);
    });
  });
}

CanonicalEvent _tool(
  String id,
  String name, {
  EventStatus status = EventStatus.done,
  Map<String, dynamic>? input,
  Object? output,
  String? runId,
}) {
  return CanonicalEvent(
    id: id,
    runId: runId,
    kind: EventKind.toolCall,
    status: status,
    tool: {
      'name': name,
      if (input != null) 'input': input,
      if (output != null) 'output': output,
    },
    timestamp: DateTime.utc(2026, 8, 14),
  );
}
