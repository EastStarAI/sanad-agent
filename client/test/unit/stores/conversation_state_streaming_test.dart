import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_state.dart';

void main() {
  group('ConversationState streaming text merging', () {
    test('does not drop delta chunks whose text is a prefix of accumulated text in auto mode', () {
      final state = ConversationState(thinkingStreamMode: ThinkingStreamMode.auto);

      // Start with text that begins with '**'
      state.apply(
        CanonicalEvent(
          id: 'thinking_1',
          kind: EventKind.thinking,
          status: EventStatus.running,
          text: '**23 سبتمبر، 01:43:50 UTC:** انتهى المنفذ السابق بمهلة تشغيل `timeout` ورمز ',
          timestamp: DateTime.now(),
        ),
      );

      // Next chunk is '**' (to start bolding 124)
      state.apply(
        CanonicalEvent(
          id: 'thinking_1',
          kind: EventKind.thinking,
          status: EventStatus.running,
          text: '**',
          timestamp: DateTime.now(),
        ),
      );

      expect(
        state.events.single.text,
        '**23 سبتمبر، 01:43:50 UTC:** انتهى المنفذ السابق بمهلة تشغيل `timeout` ورمز **',
      );

      // Next chunk is '124'
      state.apply(
        CanonicalEvent(
          id: 'thinking_1',
          kind: EventKind.thinking,
          status: EventStatus.running,
          text: '124',
          timestamp: DateTime.now(),
        ),
      );

      // Next chunk is '**' (to close bolding 124)
      state.apply(
        CanonicalEvent(
          id: 'thinking_1',
          kind: EventKind.thinking,
          status: EventStatus.running,
          text: '**',
          timestamp: DateTime.now(),
        ),
      );

      expect(
        state.events.single.text,
        '**23 سبتمبر، 01:43:50 UTC:** انتهى المنفذ السابق بمهلة تشغيل `timeout` ورمز **124**',
      );
    });

    test('supports cumulative snapshot stream where incoming starts with existing', () {
      final state = ConversationState(thinkingStreamMode: ThinkingStreamMode.auto);

      state.apply(
        CanonicalEvent(
          id: 'thinking_1',
          kind: EventKind.thinking,
          status: EventStatus.running,
          text: 'Hello',
          timestamp: DateTime.now(),
        ),
      );

      state.apply(
        CanonicalEvent(
          id: 'thinking_1',
          kind: EventKind.thinking,
          status: EventStatus.running,
          text: 'Hello World',
          timestamp: DateTime.now(),
        ),
      );

      expect(state.events.single.text, 'Hello World');
    });

    test('delta mode strictly appends incoming text', () {
      final state = ConversationState(thinkingStreamMode: ThinkingStreamMode.delta);

      state.apply(
        CanonicalEvent(
          id: 'thinking_1',
          kind: EventKind.thinking,
          status: EventStatus.running,
          text: 'Part 1: ',
          timestamp: DateTime.now(),
        ),
      );

      state.apply(
        CanonicalEvent(
          id: 'thinking_1',
          kind: EventKind.thinking,
          status: EventStatus.running,
          text: 'Part ',
          timestamp: DateTime.now(),
        ),
      );

      expect(state.events.single.text, 'Part 1: Part ');
    });
  });

  group('ConversationState tool execution merging', () {
    test('preserves start timestamp and computes runtimeMs when tool_result merges into running tool_use', () {
      final state = ConversationState();
      final startTime = DateTime(2026, 1, 1, 10, 0, 0);
      final finishTime = DateTime(2026, 1, 1, 10, 0, 3); // 3 seconds later

      // tool_use arrives (running)
      state.apply(
        CanonicalEvent(
          id: 'call_1',
          toolCallId: 'call_1',
          kind: EventKind.toolCall,
          status: EventStatus.running,
          tool: {'name': 'shell_execute', 'input': {'command': 'ls'}},
          timestamp: startTime,
        ),
      );

      expect(state.events.single.status, EventStatus.running);
      expect(state.events.single.runtimeMs, isNull);
      expect(state.events.single.timestamp, startTime);

      // tool_result arrives (done)
      state.apply(
        CanonicalEvent(
          id: 'call_1',
          toolCallId: 'call_1',
          kind: EventKind.toolCall,
          status: EventStatus.done,
          tool: {'output': 'files.txt'},
          timestamp: finishTime,
        ),
      );

      final merged = state.events.single;
      expect(merged.status, EventStatus.done);
      expect(merged.timestamp, startTime); // start timestamp preserved!
      expect(merged.runtimeMs, 3000); // 3000ms computed!
      expect(merged.tool?['name'], 'shell_execute');
      expect(merged.tool?['output'], 'files.txt');
    });
  });
}
