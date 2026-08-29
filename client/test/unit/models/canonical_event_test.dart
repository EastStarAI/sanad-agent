/// Tests for [UnifiedDeviceMapper] and [CanonicalEvent] model.
///
/// These tests verify the new event mapping system introduced by the
/// conversation events refactor plan.
library;

import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/data/mappers/unified_device_mapper.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_state.dart';

void main() {
  // ──────────────────────────────────────────────────────────────────────────
  // Helpers
  // ──────────────────────────────────────────────────────────────────────────

  final mapper = UnifiedDeviceMapper();

  Map<String, dynamic> agentEvent(String event, Map<String, dynamic> payload) {
    return {
      'device_id': 'agent-uuid',
      'type': 'event',
      'event': event,
      'payload': payload,
    };
  }

  // ──────────────────────────────────────────────────────────────────────────
  // CanonicalEvent — model behavior
  // ──────────────────────────────────────────────────────────────────────────
  group('CanonicalEvent model', () {
    test('copyWith replaces only specified fields', () {
      final original = CanonicalEvent(
        id: 'msg-1',
        kind: EventKind.toolCall,
        status: EventStatus.running,
        tool: {'name': 'web_search', 'input': {}},
        timestamp: DateTime.now(),
      );

      final updated = original.copyWith(
        status: EventStatus.done,
        tool: {'name': 'web_search', 'input': {}, 'output': 'results'},
      );

      expect(updated.id, original.id);
      expect(updated.kind, original.kind);
      expect(updated.tool?['name'], 'web_search');
      expect(updated.status, EventStatus.done);
      expect(updated.tool?['output'], 'results');
    });

    test('merge combines tool fields', () {
      final toolUse = CanonicalEvent(
        id: 'tool-1',
        kind: EventKind.toolCall,
        status: EventStatus.running,
        tool: {
          'name': 'calculator',
          'input': {'expression': '2+2'},
        },
        timestamp: DateTime.now(),
        runId: 'run-123',
      );

      final toolResult = CanonicalEvent(
        id: 'tool-1',
        kind: EventKind.toolCall,
        status: EventStatus.done,
        tool: {'output': '4'},
        timestamp: DateTime.now(),
        runId: 'run-123',
      );

      final merged = toolUse.merge(toolResult);

      expect(merged.status, EventStatus.done);
      expect(merged.tool?['name'], 'calculator');
      expect(merged.tool?['input'], {'expression': '2+2'});
      expect(merged.tool?['output'], '4');
    });

    test('toolName extracts name from tool map', () {
      final event = CanonicalEvent(
        id: 'tool-1',
        kind: EventKind.toolCall,
        tool: {'name': 'web_search', 'input': {}},
        timestamp: DateTime.now(),
      );

      expect(event.toolName, 'web_search');
    });

    test('toolInput extracts input from tool map', () {
      final event = CanonicalEvent(
        id: 'tool-1',
        kind: EventKind.toolCall,
        tool: {
          'name': 'calculator',
          'input': {'expression': '2+2'},
        },
        timestamp: DateTime.now(),
      );

      expect(event.toolInput, {'expression': '2+2'});
    });

    test('toolOutput extracts output from tool map', () {
      final event = CanonicalEvent(
        id: 'tool-1',
        kind: EventKind.toolCall,
        tool: {'name': 'calculator', 'output': '4'},
        timestamp: DateTime.now(),
      );

      expect(event.toolOutput, '4');
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // UnifiedDeviceMapper.mapLiveEvent
  // ──────────────────────────────────────────────────────────────────────────
  group('UnifiedDeviceMapper.mapLiveEvent', () {
    test('final_answer maps to finalAnswer kind', () {
      final event = agentEvent('final_answer', {
        'content': 'الإجابة النهائية',
        'session_id': 'session-123',
      });

      final canonical = mapper.mapLiveEvent(event);

      expect(canonical, isNotNull);
      expect(canonical!.kind, EventKind.finalAnswer);
      expect(canonical.text, 'الإجابة النهائية');
      expect(canonical.status, EventStatus.done);
    });

    test('thought_stream maps to thinking kind with running status', () {
      final event = agentEvent('thought_stream', {
        'content': 'أنا أفكر...',
        'session_id': 'session-123',
      });

      final canonical = mapper.mapLiveEvent(event);

      expect(canonical, isNotNull);
      expect(canonical!.kind, EventKind.thinking);
      expect(canonical.text, 'أنا أفكر...');
      expect(canonical.status, EventStatus.running);
    });

    test('canonical thinking maps payload text and top-level ids', () {
      final event = {
        'device_id': 'device-uuid',
        'type': 'device_event',
        'event': 'thinking',
        'session_id': 'session-main',
        'run_id': 'run-1',
        'timestamp': '2026-04-19T00:00:11.000Z',
        'payload': {
          'id': 'thinking-1',
          'status': 'running',
          'text': 'يفكر الآن...',
        },
      };

      final canonical = mapper.mapLiveEvent(event);

      expect(canonical, isNotNull);
      expect(canonical!.kind, EventKind.thinking);
      expect(canonical.text, 'يفكر الآن...');
      expect(canonical.status, EventStatus.running);
      expect(canonical.sessionId, 'session-main');
      expect(canonical.runId, 'run-1');
    });

    test('tool_use maps to toolCall kind with running status', () {
      final event = agentEvent('tool_use', {
        'tool': 'web_search',
        'title': 'Searching the web...',
        'input': {'query': 'test'},
        'run_id': 'run-uuid-123',
        'status': 'running',
      });

      final canonical = mapper.mapLiveEvent(event);

      expect(canonical, isNotNull);
      expect(canonical!.kind, EventKind.toolCall);
      expect(canonical.status, EventStatus.running);
      expect(canonical.toolName, 'web_search');
      expect(canonical.toolInput, {'query': 'test'});
      expect(canonical.runId, 'run-uuid-123');
    });

    test('computer canonical tool_call maps nested tool payload', () {
      final event = {
        'device_id': 'computer-agent-uuid',
        'type': 'device_event',
        'event': 'tool_call',
        'session_id': 'agent:main:main',
        'run_id': 'tool-1',
        'payload': {
          'id': 'tool-call-1',
          'status': 'done',
          'tool': {
            'name': 'read',
            'input': {'path': '/tmp/a.txt'},
            'output': 'file text',
          },
        },
      };

      final canonical = mapper.mapLiveEvent(event);

      expect(canonical, isNotNull);
      expect(canonical!.kind, EventKind.toolCall);
      expect(canonical.status, EventStatus.done);
      expect(canonical.toolName, 'read');
      expect(canonical.toolInput, {'path': '/tmp/a.txt'});
      expect(canonical.toolOutput, 'file text');
      expect(canonical.runId, 'tool-1');
    });

    test('tool_result maps to toolCall kind with done status', () {
      final event = agentEvent('tool_result', {
        'tool': 'calculator',
        'output': '4',
        'run_id': 'run-uuid-123',
      });

      final canonical = mapper.mapLiveEvent(event);

      expect(canonical, isNotNull);
      expect(canonical!.kind, EventKind.toolCall);
      expect(canonical.status, EventStatus.done);
      expect(canonical.toolOutput, '4');
      expect(canonical.runId, 'run-uuid-123');
    });

    test('tool_result with isError=true maps to error status', () {
      final event = agentEvent('tool_result', {
        'tool': 'web_search',
        'output': 'Error: network failed',
        'run_id': 'run-1',
        'isError': true,
      });

      final canonical = mapper.mapLiveEvent(event);

      expect(canonical!.status, EventStatus.error);
    });

    test('user_message maps to userMessage kind', () {
      final event = agentEvent('user_message', {
        'content': 'مرحباً',
        'session_id': 'session-123',
      });

      final canonical = mapper.mapLiveEvent(event);

      expect(canonical, isNotNull);
      expect(canonical!.kind, EventKind.userMessage);
      expect(canonical.text, 'مرحباً');
      expect(canonical.status, EventStatus.done);
    });

    test('user_message with request_id maps to the optimistic message id', () {
      final event = agentEvent('user_message', {
        'request_id': 'req-123',
        'content': 'مرحباً',
        'session_id': 'session-123',
      });

      final canonical = mapper.mapLiveEvent(event);

      expect(canonical!.id, 'user_req-123');
    });

    test('error maps to error kind with error status', () {
      final event = agentEvent('error', {
        'content': 'حدث خطأ غير متوقع',
        'session_id': 'session-123',
      });

      final canonical = mapper.mapLiveEvent(event);

      expect(canonical, isNotNull);
      expect(canonical!.kind, EventKind.error);
      expect(canonical.status, EventStatus.error);
      expect(canonical.text, 'حدث خطأ غير متوقع');
    });

    test('stopped is a control event handled outside conversation projection mapping', () {
      final event = agentEvent('stopped', {
        'content': 'partial answer',
        'session_id': 'session-123',
        'run_id': 'run-1',
      });

      final canonical = mapper.mapLiveEvent(event);

      expect(canonical, isNull);
    });

    test('step_start returns null (placeholder event)', () {
      final event = agentEvent('step_start', {
        'session_id': 'session-123',
      });

      final canonical = mapper.mapLiveEvent(event);

      expect(canonical, isNull);
    });

    test('unknown event type returns null', () {
      final event = agentEvent('unknown_event_xyz', {'data': 'test'});

      final canonical = mapper.mapLiveEvent(event);

      expect(canonical, isNull);
    });

    test('tool_use and tool_result produce same id for merging', () {
      final toolUseEvent = agentEvent('tool_use', {
        'tool': 'calculator',
        'run_id': 'run-abc',
        'tool_call_id': 'call-abc',
      });
      final toolResultEvent = agentEvent('tool_result', {
        'tool': 'calculator',
        'output': '4',
        'run_id': 'run-abc',
        'tool_call_id': 'call-abc',
      });

      final toolUse = mapper.mapLiveEvent(toolUseEvent);
      final toolResult = mapper.mapLiveEvent(toolResultEvent);

      expect(toolUse!.id, toolResult!.id);
    });

    test('same named tools do not merge without a shared tool call identity', () {
      final first = mapper.mapLiveEvent(
        agentEvent('tool_use', {
          'tool': 'shell_execute',
          'run_id': 'run-abc',
          'event_id': 'event-1',
        }),
      );
      final second = mapper.mapLiveEvent(
        agentEvent('tool_use', {
          'tool': 'shell_execute',
          'run_id': 'run-abc',
          'event_id': 'event-2',
        }),
      );

      expect(first!.id, isNot(second!.id));
    });

    test('cancelled tool result preserves terminal version metadata', () {
      final canonical = mapper.mapLiveEvent(
        agentEvent('tool_result', {
          'tool': 'shell_execute',
          'output': 'Command cancelled by user.',
          'status': 'cancelled',
          'run_id': 'run-abc',
          'tool_call_id': 'call-abc',
          'generation': 7,
          'revision': 42,
          'reason': 'user_stop',
          'started_at': '2026-08-29T00:00:00Z',
          'terminal_at': '2026-08-29T00:00:01Z',
          'cleanup_outcome': 'completed',
        }),
      );

      expect(canonical!.status, EventStatus.cancelled);
      expect(canonical.generation, 7);
      expect(canonical.revision, 42);
      expect(canonical.metadata, containsPair('reason', 'user_stop'));
      expect(canonical.metadata, containsPair('started_at', '2026-08-29T00:00:00Z'));
      expect(canonical.metadata, containsPair('terminal_at', '2026-08-29T00:00:01Z'));
      expect(canonical.metadata, containsPair('cleanup_outcome', 'completed'));
    });

    test('model steps remain distinct inside one authoritative run', () {
      final first = mapper.mapLiveEvent(
        agentEvent('thought_stream', {
          'content': 'step one',
          'run_id': 'run-1',
          'model_step_id': 'step-1',
        }),
      );
      final second = mapper.mapLiveEvent(
        agentEvent('thought_stream', {
          'content': 'step two',
          'run_id': 'run-1',
          'model_step_id': 'step-2',
        }),
      );

      expect(first!.id, 'thinking_step-1');
      expect(second!.id, 'thinking_step-2');
      expect(first.id, isNot(second.id));
      expect(first.runId, second.runId);
    });

    test('tool identity is independent from authoritative run identity', () {
      final first = mapper.mapLiveEvent(
        agentEvent('tool_use', {
          'tool': 'first',
          'run_id': 'run-1',
          'tool_call_id': 'call-1',
        }),
      );
      final second = mapper.mapLiveEvent(
        agentEvent('tool_use', {
          'tool': 'second',
          'run_id': 'run-1',
          'tool_call_id': 'call-2',
        }),
      );

      expect(first!.id, 'tool_call-1');
      expect(second!.id, 'tool_call-2');
      expect(first.id, isNot(second.id));
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // UnifiedDeviceMapper.mapHistory
  // ──────────────────────────────────────────────────────────────────────────
  group('UnifiedDeviceMapper.mapHistory', () {
    test('maps final_answer from history', () {
      final history = [
        {
          'type': 'final_answer',
          'content': 'تاريخي',
        },
      ];

      final events = mapper.mapHistory(history);

      expect(events.any((e) => e.kind == EventKind.finalAnswer), isTrue);
    });

    test('maps user_message from history', () {
      final history = [
        {
          'type': 'user_message',
          'sender': 'user',
          'content': 'مرحباً',
          'metadata': {
            'model': 'openai/gpt-5',
            'model_display': 'OpenAI: GPT-5',
            'provider': 'openrouter',
            'thinking_mode': 'precise',
            'reasoning_level': 'high',
          },
        },
      ];

      final events = mapper.mapHistory(history);

      expect(events.any((e) => e.kind == EventKind.userMessage), isTrue);
      expect(events.first.text, 'مرحباً');
      expect(events.first.model, 'openai/gpt-5');
      expect(events.first.modelDisplay, 'OpenAI: GPT-5');
      expect(events.first.provider, 'openrouter');
      expect(events.first.thinkingMode, 'precise');
      expect(events.first.reasoningLevel, 'high');
    });

    test('skips non-map entries in history', () {
      final history = ['bad entry', null, 42];

      final events = mapper.mapHistory(history);

      expect(events, isEmpty);
    });

    test('maps tool_use from history', () {
      final history = [
        {
          'type': 'tool_use',
          'tool': 'web_search',
          'run_id': 'run-1',
          'input': {'query': 'test'},
        },
      ];

      final events = mapper.mapHistory(history);

      expect(events.any((e) => e.kind == EventKind.toolCall), isTrue);
    });

    test('maps tool_use from history metadata fallback', () {
      final history = [
        {
          'type': 'tool_use',
          'metadata': {
            'tool': 'execute_terminal_command',
            'input': {'command': 'pwd'},
            'run_id': 'run-meta-use',
          },
        },
      ];

      final events = mapper.mapHistory(history);

      expect(events.single.kind, EventKind.toolCall);
      expect(events.single.toolName, 'execute_terminal_command');
      expect(events.single.toolInput, {'command': 'pwd'});
    });

    test('maps tool_result from history', () {
      final history = [
        {
          'type': 'tool_result',
          'tool': 'web_search',
          'run_id': 'run-1',
          'output': 'results',
        },
      ];

      final events = mapper.mapHistory(history);

      expect(events.any((e) => e.kind == EventKind.toolCall), isTrue);
      // Note: toolOutput may be null for history items as output is stored in tool map
    });

    test('maps tool_result from history metadata fallback', () {
      final history = [
        {
          'type': 'tool_result',
          'metadata': {
            'tool': 'execute_terminal_command',
            'output': '/tmp/project',
            'run_id': 'run-meta-result',
          },
        },
      ];

      final events = mapper.mapHistory(history);

      expect(events.single.kind, EventKind.toolCall);
      expect(events.single.toolName, 'execute_terminal_command');
      expect(events.single.toolOutput, '/tmp/project');
    });

    test('history cancellation matches live terminal metadata', () {
      final events = mapper.mapHistory([
        {
          'type': 'tool_result',
          'tool': 'shell_execute',
          'output': 'Command cancelled by user.',
          'status': 'cancelled',
          'run_id': 'run-history',
          'tool_call_id': 'call-history',
          'generation': 3,
          'revision': 91,
          'reason': 'user_stop',
          'started_at': '2026-08-29T00:00:00Z',
          'terminal_at': '2026-08-29T00:00:01Z',
          'cleanup_outcome': 'completed',
        },
      ]);

      final terminal = events.single;
      expect(terminal.status, EventStatus.cancelled);
      expect(terminal.generation, 3);
      expect(terminal.revision, 91);
      expect(terminal.metadata, containsPair('reason', 'user_stop'));
      expect(terminal.metadata, containsPair('cleanup_outcome', 'completed'));
    });

    test('maps canonical tool_call from history metadata fallback', () {
      final history = [
        {
          'type': 'tool_call',
          'metadata': {
            'run_id': 'run-tool-call',
            'status': 'done',
            'tool': {
              'name': 'execute_terminal_command',
              'input': {'command': 'uname -a'},
              'output': 'Darwin ...',
            },
          },
        },
      ];

      final events = mapper.mapHistory(history);

      expect(events.single.kind, EventKind.toolCall);
      expect(events.single.status, EventStatus.done);
      expect(events.single.toolName, 'execute_terminal_command');
      expect(events.single.toolInput, {'command': 'uname -a'});
      expect(events.single.toolOutput, 'Darwin ...');
    });
  });

  // ──────────────────────────────────────────────────────────────────────────
  // ConversationState — state management
  // ──────────────────────────────────────────────────────────────────────────
  group('ConversationState', () {
    late ConversationState state;

    setUp(() {
      state = ConversationState();
    });

    tearDown(() {
      state.dispose();
    });

    test('apply adds new event to events list', () {
      final event = CanonicalEvent(
        id: 'user-1',
        kind: EventKind.userMessage,
        text: 'Hello',
        status: EventStatus.done,
        timestamp: DateTime.now(),
      );

      state.apply(event);

      expect(state.events.length, 1);
      expect(state.events.first.text, 'Hello');
    });

    test('apply with same id updates existing event (upsert)', () {
      final event1 = CanonicalEvent(
        id: 'thinking-1',
        kind: EventKind.thinking,
        text: 'A',
        status: EventStatus.running,
        timestamp: DateTime.now(),
      );
      final event2 = CanonicalEvent(
        id: 'thinking-1',
        kind: EventKind.thinking,
        text: 'B',
        status: EventStatus.running,
        timestamp: DateTime.now(),
      );

      state.apply(event1);
      state.apply(event2);

      expect(state.events.length, 1);
      expect(state.events.first.text, contains('A'));
      expect(state.events.first.text, contains('B'));
    });

    test('new running reasoning replaces a stale concurrent reasoning stream', () {
      final now = DateTime.now();
      state.apply(
        CanonicalEvent(
          id: 'reasoning-step-1',
          kind: EventKind.reasoning,
          text: 'stale reasoning',
          status: EventStatus.running,
          timestamp: now,
          sessionId: 'session-1',
          runId: 'run-1',
          modelStepId: 'step-1',
        ),
      );
      state.apply(
        CanonicalEvent(
          id: 'reasoning-step-2',
          kind: EventKind.reasoning,
          text: 'current reasoning',
          status: EventStatus.running,
          timestamp: now.add(const Duration(milliseconds: 1)),
          sessionId: 'session-1',
          runId: 'run-1',
          modelStepId: 'step-2',
        ),
      );

      expect(
        state.events.where(
          (event) => event.kind == EventKind.reasoning && event.status == EventStatus.running,
        ),
        hasLength(1),
      );
      expect(state.events.single.id, 'reasoning-step-2');
    });

    test('running reasoning does not replace the concurrent thought surface', () {
      final now = DateTime.now();
      state.apply(
        CanonicalEvent(
          id: 'thinking-step-1',
          kind: EventKind.thinking,
          text: 'visible thought',
          status: EventStatus.running,
          timestamp: now,
          sessionId: 'session-1',
          runId: 'run-1',
        ),
      );
      state.apply(
        CanonicalEvent(
          id: 'reasoning-step-1',
          kind: EventKind.reasoning,
          text: 'provider reasoning',
          status: EventStatus.running,
          timestamp: now,
          sessionId: 'session-1',
          runId: 'run-1',
        ),
      );

      expect(state.events.map((event) => event.kind), [
        EventKind.thinking,
        EventKind.reasoning,
      ]);
    });

    test('backend user echo replaces optimistic user message with same request id', () {
      final now = DateTime.now();
      state.apply(
        CanonicalEvent(
          id: 'user_req-123',
          kind: EventKind.userMessage,
          text: 'Hello',
          status: EventStatus.done,
          timestamp: now,
          sessionId: 'session-1',
          metadata: {
            'optimistic': true,
            'request_id': 'req-123',
          },
        ),
      );

      state.apply(
        CanonicalEvent(
          id: 'user_req-123',
          kind: EventKind.userMessage,
          text: 'Hello',
          status: EventStatus.done,
          timestamp: now.add(const Duration(seconds: 12)),
          sessionId: 'session-1',
        ),
      );

      expect(state.events.length, 1);
      expect(state.events.single.metadata?['optimistic'], isNull);
    });

    test('delayed backend user echo replaces nearest optimistic fallback', () {
      final now = DateTime.now();
      state.apply(
        CanonicalEvent(
          id: 'user_req-1',
          kind: EventKind.userMessage,
          text: 'Hello',
          status: EventStatus.done,
          timestamp: now,
          sessionId: 'session-1',
          metadata: {
            'optimistic': true,
            'request_id': 'req-1',
          },
        ),
      );

      state.apply(
        CanonicalEvent(
          id: 'user_server_echo',
          kind: EventKind.userMessage,
          text: 'Hello',
          status: EventStatus.done,
          timestamp: now.add(const Duration(seconds: 12)),
          sessionId: 'session-1',
        ),
      );

      expect(state.events.length, 1);
      expect(state.events.single.id, 'user_server_echo');
    });

    test('thinking streaming appends text', () {
      final event1 = CanonicalEvent(
        id: 'thinking-1',
        kind: EventKind.thinking,
        text: 'First ',
        status: EventStatus.running,
        timestamp: DateTime.now(),
      );
      final event2 = CanonicalEvent(
        id: 'thinking-1',
        kind: EventKind.thinking,
        text: 'Second',
        status: EventStatus.running,
        timestamp: DateTime.now(),
      );

      state.apply(event1);
      state.apply(event2);

      expect(state.events.first.text, 'First Second');
    });

    test('thinking streaming replaces cumulative snapshots without duplication', () {
      state = ConversationState(thinkingStreamMode: ThinkingStreamMode.snapshot);

      final event1 = CanonicalEvent(
        id: 'thinking-1',
        kind: EventKind.thinking,
        text: 'مرحبا',
        status: EventStatus.running,
        timestamp: DateTime.now(),
      );
      final event2 = CanonicalEvent(
        id: 'thinking-1',
        kind: EventKind.thinking,
        text: 'مرحبا من',
        status: EventStatus.running,
        timestamp: DateTime.now(),
      );
      final event3 = CanonicalEvent(
        id: 'thinking-1',
        kind: EventKind.thinking,
        text: 'مرحبا من جديد',
        status: EventStatus.running,
        timestamp: DateTime.now(),
      );

      state.apply(event1);
      state.apply(event2);
      state.apply(event3);

      expect(state.events.first.text, 'مرحبا من جديد');
    });

    test('thinking streaming auto mode still handles cumulative snapshots', () {
      final event1 = CanonicalEvent(
        id: 'thinking-1',
        kind: EventKind.thinking,
        text: 'على',
        status: EventStatus.running,
        timestamp: DateTime.now(),
      );
      final event2 = CanonicalEvent(
        id: 'thinking-1',
        kind: EventKind.thinking,
        text: 'على الرحب',
        status: EventStatus.running,
        timestamp: DateTime.now(),
      );

      state.apply(event1);
      state.apply(event2);

      expect(state.events.first.text, 'على الرحب');
    });

    test('final_answer removes corresponding thinking bubble', () {
      final thinkingEvent = CanonicalEvent(
        id: 'thinking_123',
        kind: EventKind.thinking,
        text: 'Thinking...',
        status: EventStatus.running,
        timestamp: DateTime.now(),
        runId: 'run-123',
      );
      final answerEvent = CanonicalEvent(
        id: 'answer_123',
        kind: EventKind.finalAnswer,
        text: 'Final answer',
        status: EventStatus.done,
        timestamp: DateTime.now(),
        runId: 'run-123',
      );

      state.apply(thinkingEvent);
      state.apply(answerEvent);

      expect(state.events.any((e) => e.kind == EventKind.thinking), isFalse);
      expect(state.events.any((e) => e.kind == EventKind.finalAnswer), isTrue);
    });

    test('final answer removes only its running model-step projection', () {
      final now = DateTime.now();
      state.apply(
        CanonicalEvent(
          id: 'thinking_step-1',
          kind: EventKind.thinking,
          text: 'completed earlier thought',
          status: EventStatus.done,
          timestamp: now,
          runId: 'run-1',
          modelStepId: 'step-1',
        ),
      );
      state.apply(
        CanonicalEvent(
          id: 'thinking_step-2',
          kind: EventKind.thinking,
          text: 'streamed final projection',
          status: EventStatus.running,
          timestamp: now,
          runId: 'run-1',
          modelStepId: 'step-2',
        ),
      );
      state.apply(
        CanonicalEvent(
          id: 'answer_step-2',
          kind: EventKind.finalAnswer,
          text: 'final',
          status: EventStatus.done,
          timestamp: now,
          runId: 'run-1',
          modelStepId: 'step-2',
        ),
      );

      expect(state.events.map((event) => event.id), [
        'thinking_step-1',
        'answer_step-2',
      ]);
    });

    test('late steer completion preserves the prior stream before the next step', () {
      final now = DateTime.now();
      state.apply(
        CanonicalEvent(
          id: 'thinking_step-1',
          kind: EventKind.thinking,
          text: 'Answer before steer',
          status: EventStatus.running,
          timestamp: now,
          sessionId: 'session-1',
          runId: 'run-1',
          modelStepId: 'step-1',
        ),
      );
      state.apply(
        CanonicalEvent(
          id: 'thinking_step-1',
          kind: EventKind.thinking,
          text: 'Answer before steer',
          status: EventStatus.done,
          timestamp: now.add(const Duration(milliseconds: 1)),
          sessionId: 'session-1',
          runId: 'run-1',
          modelStepId: 'step-1',
        ),
      );
      state.apply(
        CanonicalEvent(
          id: 'user_steer-1',
          kind: EventKind.userMessage,
          text: 'Revise it',
          status: EventStatus.done,
          timestamp: now.add(const Duration(milliseconds: 2)),
          sessionId: 'session-1',
          runId: 'run-1',
        ),
      );
      state.apply(
        CanonicalEvent(
          id: 'thinking_step-2',
          kind: EventKind.thinking,
          text: 'Adjusted response',
          status: EventStatus.running,
          timestamp: now.add(const Duration(milliseconds: 3)),
          sessionId: 'session-1',
          runId: 'run-1',
          modelStepId: 'step-2',
        ),
      );

      expect(state.events.map((event) => event.id), [
        'thinking_step-1',
        'user_steer-1',
        'thinking_step-2',
      ]);
      expect(state.events.first.status, EventStatus.done);
      expect(state.events.first.text, 'Answer before steer');
    });

    test('tool_use and tool_result merge via same id', () {
      final toolUseEvent = CanonicalEvent(
        id: 'tool_run-abc',
        kind: EventKind.toolCall,
        status: EventStatus.running,
        tool: {
          'name': 'calculator',
          'input': {'expression': '2+2'},
        },
        timestamp: DateTime.now(),
        runId: 'run-abc',
      );
      final toolResultEvent = CanonicalEvent(
        id: 'tool_run-abc',
        kind: EventKind.toolCall,
        status: EventStatus.done,
        tool: {'output': '4'},
        timestamp: DateTime.now(),
        runId: 'run-abc',
      );

      state.apply(toolUseEvent);
      state.apply(toolResultEvent);

      expect(state.events.length, 1);
      expect(state.events.first.status, EventStatus.done);
      expect(state.events.first.toolName, 'calculator');
      expect(state.events.first.toolInput, {'expression': '2+2'});
      expect(state.events.first.toolOutput, '4');
    });

    test('cancelled terminal rejects older and unversioned late results', () {
      final now = DateTime.now();
      state.apply(
        CanonicalEvent(
          id: 'tool_call-1',
          kind: EventKind.toolCall,
          status: EventStatus.cancelled,
          tool: const {'name': 'shell_execute', 'output': 'cancelled'},
          timestamp: now,
          runId: 'run-1',
          toolCallId: 'call-1',
          metadata: const {'generation': 4, 'revision': 20},
        ),
      );
      state.apply(
        CanonicalEvent(
          id: 'tool_call-1',
          kind: EventKind.toolCall,
          status: EventStatus.error,
          tool: const {'output': 'late timeout'},
          timestamp: now.add(const Duration(seconds: 1)),
          runId: 'run-1',
          toolCallId: 'call-1',
          metadata: const {'generation': 4, 'revision': 19},
        ),
      );
      state.apply(
        CanonicalEvent(
          id: 'tool_call-1',
          kind: EventKind.toolCall,
          status: EventStatus.error,
          tool: const {'output': 'newer late timeout'},
          timestamp: now.add(const Duration(milliseconds: 1500)),
          runId: 'run-1',
          toolCallId: 'call-1',
          metadata: const {'generation': 4, 'revision': 21},
        ),
      );
      state.apply(
        CanonicalEvent(
          id: 'tool_call-1',
          kind: EventKind.toolCall,
          status: EventStatus.done,
          tool: const {'output': 'late completion'},
          timestamp: now.add(const Duration(seconds: 2)),
          runId: 'run-1',
          toolCallId: 'call-1',
        ),
      );

      expect(state.events.single.status, EventStatus.cancelled);
      expect(state.events.single.toolOutput, 'cancelled');
      expect(state.events.single.revision, 20);
    });

    test('newer terminal revision replaces an older terminal observation', () {
      final now = DateTime.now();
      state.apply(
        CanonicalEvent(
          id: 'tool_call-1',
          kind: EventKind.toolCall,
          status: EventStatus.error,
          tool: const {'name': 'shell_execute', 'output': 'old timeout'},
          timestamp: now,
          metadata: const {'generation': 2, 'revision': 10},
        ),
      );
      state.apply(
        CanonicalEvent(
          id: 'tool_call-1',
          kind: EventKind.toolCall,
          status: EventStatus.done,
          tool: const {'output': 'authoritative completion'},
          timestamp: now.add(const Duration(seconds: 1)),
          metadata: const {'generation': 2, 'revision': 11},
        ),
      );

      expect(state.events.single.status, EventStatus.done);
      expect(state.events.single.toolOutput, 'authoritative completion');
      expect(state.events.single.revision, 11);
    });

    test('tool use closes the persisted model-step thought', () {
      final now = DateTime.now();
      state.apply(
        CanonicalEvent(
          id: 'thinking_step-1',
          kind: EventKind.thinking,
          status: EventStatus.running,
          text: 'completed reasoning',
          timestamp: now,
          sessionId: 'session-1',
          runId: 'run-1',
          modelStepId: 'step-1',
        ),
      );
      state.apply(
        CanonicalEvent(
          id: 'tool_call-1',
          kind: EventKind.toolCall,
          status: EventStatus.running,
          timestamp: now,
          sessionId: 'session-1',
          runId: 'run-1',
          modelStepId: 'step-1',
          toolCallId: 'call-1',
        ),
      );

      final thought = state.events.firstWhere(
        (event) => event.kind == EventKind.thinking,
      );
      expect(thought.status, EventStatus.done);
    });

    test('steer remains after its tool and before the final answer', () {
      final now = DateTime.now();
      state.apply(
        CanonicalEvent(
          id: 'tool_run-steer',
          kind: EventKind.toolCall,
          status: EventStatus.running,
          tool: {'name': 'shell_execute', 'input': 'pwd'},
          timestamp: now,
          runId: 'run-steer',
        ),
      );
      state.apply(
        CanonicalEvent(
          id: 'user_steer-1',
          kind: EventKind.userMessage,
          text: 'Change direction',
          status: EventStatus.done,
          timestamp: now.add(const Duration(seconds: 1)),
          metadata: {'steer': true, 'request_id': 'steer-1'},
        ),
      );
      state.apply(
        CanonicalEvent(
          id: 'tool_run-steer',
          kind: EventKind.toolCall,
          status: EventStatus.done,
          tool: {'output': '/workspace'},
          timestamp: now.add(const Duration(seconds: 2)),
          runId: 'run-steer',
        ),
      );
      state.apply(
        CanonicalEvent(
          id: 'answer_run-steer',
          kind: EventKind.finalAnswer,
          text: 'Adjusted answer',
          status: EventStatus.done,
          timestamp: now.add(const Duration(seconds: 3)),
          runId: 'run-steer',
        ),
      );

      expect(state.events.map((event) => event.kind), [
        EventKind.toolCall,
        EventKind.userMessage,
        EventKind.finalAnswer,
      ]);
      expect(state.events.first.status, EventStatus.done);
      expect(state.events[1].text, 'Change direction');
    });

    test('final_answer merge keeps enriched live metadata on same id', () {
      final initialAnswer = CanonicalEvent(
        id: 'answer_run-xyz',
        kind: EventKind.finalAnswer,
        text: 'Final answer',
        status: EventStatus.done,
        timestamp: DateTime.now(),
        runId: 'run-xyz',
      );
      final enrichedAnswer = CanonicalEvent(
        id: 'answer_run-xyz',
        kind: EventKind.finalAnswer,
        text: 'Final answer',
        status: EventStatus.done,
        timestamp: DateTime.now(),
        runId: 'run-xyz',
        model: 'moonshotai/kimi-k2.5',
        modelDisplay: 'kimi-k2.5',
        provider: 'openrouter',
        usage: {
          'input': 25300,
          'output': 168,
          'cacheRead': 64,
        },
        runtimeMs: 3612,
        contextTokens: 200000,
      );

      state.apply(initialAnswer);
      state.apply(enrichedAnswer);

      expect(state.events.length, 1);
      expect(state.events.first.kind, EventKind.finalAnswer);
      expect(state.events.first.model, 'moonshotai/kimi-k2.5');
      expect(state.events.first.modelDisplay, 'kimi-k2.5');
      expect(state.events.first.provider, 'openrouter');
      expect(state.events.first.usage, {
        'input': 25300,
        'output': 168,
        'cacheRead': 64,
      });
      expect(state.events.first.runtimeMs, 3612);
      expect(state.events.first.contextTokens, 200000);
    });

    test('setHistory replaces all events', () {
      state.apply(
        CanonicalEvent(
          id: 'user-1',
          kind: EventKind.userMessage,
          text: 'Old message',
          status: EventStatus.done,
          timestamp: DateTime.now(),
        ),
      );

      final history = [
        CanonicalEvent(
          id: 'user-2',
          kind: EventKind.userMessage,
          text: 'New message',
          status: EventStatus.done,
          timestamp: DateTime.now(),
        ),
        CanonicalEvent(
          id: 'answer-1',
          kind: EventKind.finalAnswer,
          text: 'Response',
          status: EventStatus.done,
          timestamp: DateTime.now(),
        ),
      ];

      state.setHistory(history);

      expect(state.events.length, 2);
      expect(state.events.any((e) => e.text == 'New message'), isTrue);
      expect(state.events.any((e) => e.text == 'Response'), isTrue);
    });

    test('clear removes all events', () {
      state.apply(
        CanonicalEvent(
          id: 'user-1',
          kind: EventKind.userMessage,
          text: 'Message',
          status: EventStatus.done,
          timestamp: DateTime.now(),
        ),
      );

      state.clear();

      expect(state.events, isEmpty);
    });

    test('isEmpty returns true when no events', () {
      expect(state.isEmpty, isTrue);
    });

    test('isEmpty returns false when events exist', () {
      state.apply(
        CanonicalEvent(
          id: 'user-1',
          kind: EventKind.userMessage,
          text: 'Message',
          status: EventStatus.done,
          timestamp: DateTime.now(),
        ),
      );

      expect(state.isEmpty, isFalse);
    });
  });
}
