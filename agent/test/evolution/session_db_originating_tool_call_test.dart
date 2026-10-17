import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late AgentStateDatabase state;
  late SessionDB db;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'sanad-originating-tool-call-test',
    );
    setSanadHomeOverride(tempDir.path);
    state = AgentStateDatabase();
    db = SessionDB.fromState(state);
    db.saveSession(
      SessionState(
        sessionId: 'session-1',
        model: 'model-1',
        title: 'Session 1',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    );
    db.saveSession(
      SessionState(
        sessionId: 'session-2',
        model: 'model-1',
        title: 'Session 2',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    );
  });

  tearDown(() async {
    db.dispose();
    setSanadHomeOverride(null);
    await tempDir.delete(recursive: true);
  });

  test('resolves tool call with exact JSON matching and bounded fields', () {
    final assistantMsg = Message(
      role: MessageRole.assistant,
      content: 'I will view the image',
      toolCalls: [
        ToolCall(
          id: 'call_exact_123',
          name: 'view_image',
          arguments: {'path': 'test.png'},
        ),
      ],
      metadata: {'run_id': 'run-1', 'model_step_id': 'step-1'},
    );

    db.replaceMessages('session-1', [assistantMsg]);

    final match = db.findOriginatingToolCall(
      'session-1',
      toolCallId: 'call_exact_123',
    );
    expect(match, isNotNull);
    expect(match!.toolCall.id, 'call_exact_123');
    expect(match.toolCall.name, 'view_image');
    expect(match.toolCall.arguments, {'path': 'test.png'});
    expect(match.runId, 'run-1');
    expect(match.modelStepId, 'step-1');
  });

  test(
    'exact matching handles SQL wildcard characters and quotes without regex/like errors',
    () {
      final assistantMsg = Message(
        role: MessageRole.assistant,
        content: 'Tool call with wildcards and quotes',
        toolCalls: [
          ToolCall(
            id: 'call_%_percent_1',
            name: 'view_image',
            arguments: {'path': 'percent.png'},
          ),
          ToolCall(
            id: 'call_foo_percent_1',
            name: 'other_tool',
            arguments: {'path': 'other.png'},
          ),
          ToolCall(
            id: 'call___underscore',
            name: 'view_image',
            arguments: {'path': 'underscore.png'},
          ),
          ToolCall(
            id: 'call_\'quote"test',
            name: 'view_image',
            arguments: {'path': 'quote.png'},
          ),
        ],
        metadata: {'run_id': 'run-wildcard'},
      );

      db.replaceMessages('session-1', [assistantMsg]);

      // Percent wildcard should NOT match call_foo_percent_1
      final percentMatch = db.findOriginatingToolCall(
        'session-1',
        toolCallId: 'call_%_percent_1',
      );
      expect(percentMatch, isNotNull);
      expect(percentMatch!.toolCall.id, 'call_%_percent_1');
      expect(percentMatch.toolCall.name, 'view_image');

      // Underscore should NOT match arbitrary 3-character middle strings
      final underscoreMatch = db.findOriginatingToolCall(
        'session-1',
        toolCallId: 'call___underscore',
      );
      expect(underscoreMatch, isNotNull);
      expect(underscoreMatch!.toolCall.id, 'call___underscore');

      // Single and double quotes should match safely
      final quoteMatch = db.findOriginatingToolCall(
        'session-1',
        toolCallId: 'call_\'quote"test',
      );
      expect(quoteMatch, isNotNull);
      expect(quoteMatch!.toolCall.id, 'call_\'quote"test');
    },
  );

  test(
    'enforces turn boundary strictly and does not fall back to different turn',
    () {
      final msgTurn1 = Message(
        role: MessageRole.assistant,
        content: 'Turn 1',
        toolCalls: [
          ToolCall(
            id: 'call_scoped_1',
            name: 'tool_turn_1',
            arguments: {'turn': 1},
          ),
        ],
        metadata: {'turn_id': 'turn-1', 'run_id': 'run-1'},
      );

      final msgTurn2 = Message(
        role: MessageRole.assistant,
        content: 'Turn 2',
        toolCalls: [
          ToolCall(
            id: 'call_scoped_2',
            name: 'tool_turn_2',
            arguments: {'turn': 2},
          ),
        ],
        metadata: {'turn_id': 'turn-2', 'run_id': 'run-2'},
      );

      db.replaceMessages('session-1', [msgTurn1, msgTurn2]);

      // Matching within correct turn succeeds
      final matchTurn1 = db.findOriginatingToolCall(
        'session-1',
        toolCallId: 'call_scoped_1',
        turnId: 'turn-1',
      );
      expect(matchTurn1, isNotNull);
      expect(matchTurn1!.toolCall.name, 'tool_turn_1');

      // Searching for Turn 2 tool call inside Turn 1 boundary MUST NOT find it and MUST NOT fall back
      final mismatch = db.findOriginatingToolCall(
        'session-1',
        toolCallId: 'call_scoped_2',
        turnId: 'turn-1',
      );
      expect(mismatch, isNull);

      // Searching in non-existent turn MUST NOT fall back to other turns
      final nonExistentTurn = db.findOriginatingToolCall(
        'session-1',
        toolCallId: 'call_scoped_1',
        turnId: 'turn-999',
      );
      expect(nonExistentTurn, isNull);
    },
  );

  test('enforces strict session isolation with no cross-session matches', () {
    final msgSession1 = Message(
      role: MessageRole.assistant,
      content: 'Session 1',
      toolCalls: [
        ToolCall(
          id: 'call_private_session_1',
          name: 'view_image',
          arguments: {'path': 'session1.png'},
        ),
      ],
      metadata: {'run_id': 'run-s1'},
    );

    db.replaceMessages('session-1', [msgSession1]);

    // Querying from session-2 MUST return null
    final crossSessionMatch = db.findOriginatingToolCall(
      'session-2',
      toolCallId: 'call_private_session_1',
    );
    expect(crossSessionMatch, isNull);

    // Querying from session-1 succeeds
    final ownSessionMatch = db.findOriginatingToolCall(
      'session-1',
      toolCallId: 'call_private_session_1',
    );
    expect(ownSessionMatch, isNotNull);
    expect(ownSessionMatch!.toolCall.id, 'call_private_session_1');
  });

  test(
    'parses multi-call batch correctly returning targeted tool call context',
    () {
      final multiCallAssistant = Message(
        role: MessageRole.assistant,
        content: 'Running bash and viewing image',
        toolCalls: [
          ToolCall(
            id: 'call_batch_1',
            name: 'run_command',
            arguments: {'command': 'ls -la'},
          ),
          ToolCall(
            id: 'call_batch_2',
            name: 'view_image',
            arguments: {'path': 'output.png'},
          ),
        ],
        metadata: {'run_id': 'run-batch-1', 'model_step_id': 'step-batch-1'},
      );

      db.replaceMessages('session-1', [multiCallAssistant]);

      final match1 = db.findOriginatingToolCall(
        'session-1',
        toolCallId: 'call_batch_1',
      );
      expect(match1, isNotNull);
      expect(match1!.toolCall.name, 'run_command');
      expect(match1.toolCall.arguments, {'command': 'ls -la'});

      final match2 = db.findOriginatingToolCall(
        'session-1',
        toolCallId: 'call_batch_2',
      );
      expect(match2, isNotNull);
      expect(match2!.toolCall.name, 'view_image');
      expect(match2.toolCall.arguments, {'path': 'output.png'});
    },
  );

  test(
    'resolves tool call even with JSON pretty formatting and extra whitespace',
    () {
      // Manually insert an assistant row with pretty-formatted JSON into SQLite
      final prettyJson = '''
{
  "role" : "assistant",
  "content" : "Pretty formatted JSON",
  "toolCalls" : [
    {
      "id" : "call_pretty_99",
      "name" : "view_image",
      "arguments" : {
        "path" : "pretty.png"
      }
    }
  ],
  "metadata" : {
    "run_id" : "run-pretty",
    "model_step_id" : "step-pretty"
  }
}
''';

      final session = db.getSession('session-1')!;
      db.saveSession(session);

      // Insert directly into messages table
      final stmt = state.db.prepare('''
      INSERT INTO messages (session_id, data, message_id, turn_id, history_status)
      VALUES (?, ?, ?, ?, 'active')
    ''');
      stmt.execute(['session-1', prettyJson, 'msg-pretty-1', 'turn-pretty-1']);

      final match = db.findOriginatingToolCall(
        'session-1',
        toolCallId: 'call_pretty_99',
      );
      expect(match, isNotNull);
      expect(match!.toolCall.id, 'call_pretty_99');
      expect(match.toolCall.name, 'view_image');
      expect(match.toolCall.arguments, {'path': 'pretty.png'});
      expect(match.runId, 'run-pretty');
      expect(match.modelStepId, 'step-pretty');
    },
  );

  test('handles ambiguous duplicate active origins honestly by returning null', () {
    // Two distinct active assistant messages claiming the exact same toolCallId
    final msg1 = Message(
      role: MessageRole.assistant,
      content: 'Assistant 1',
      toolCalls: [
        ToolCall(
          id: 'call_duplicate_active',
          name: 'tool_one',
          arguments: {'v': 1},
        ),
      ],
      metadata: {'turn_id': 'turn-dup-1', 'run_id': 'run-1'},
    );

    final msg2 = Message(
      role: MessageRole.assistant,
      content: 'Assistant 2',
      toolCalls: [
        ToolCall(
          id: 'call_duplicate_active',
          name: 'tool_two',
          arguments: {'v': 2},
        ),
      ],
      metadata: {'turn_id': 'turn-dup-2', 'run_id': 'run-2'},
    );

    db.replaceMessages('session-1', [msg1, msg2]);

    // When querying without turn boundary, ambiguous duplicate active origins return null
    final ambiguousMatch = db.findOriginatingToolCall(
      'session-1',
      toolCallId: 'call_duplicate_active',
    );
    expect(ambiguousMatch, isNull);

    // When querying with explicit turn boundary, each turn resolves its own call unambiguously
    final matchTurn1 = db.findOriginatingToolCall(
      'session-1',
      toolCallId: 'call_duplicate_active',
      turnId: 'turn-dup-1',
    );
    expect(matchTurn1, isNotNull);
    expect(matchTurn1!.toolCall.name, 'tool_one');

    final matchTurn2 = db.findOriginatingToolCall(
      'session-1',
      toolCallId: 'call_duplicate_active',
      turnId: 'turn-dup-2',
    );
    expect(matchTurn2, isNotNull);
    expect(matchTurn2!.toolCall.name, 'tool_two');
  });

  test('ignores superseded messages and respects active history status', () {
    final stmt = state.db.prepare('''
      INSERT INTO messages (session_id, data, message_id, turn_id, history_status)
      VALUES (?, ?, ?, ?, ?)
    ''');

    final toolJson = jsonEncode({
      'role': 'assistant',
      'toolCalls': [
        {'id': 'call_superseded_1', 'name': 'old_tool', 'arguments': {}},
      ],
      'metadata': {'run_id': 'run-old'},
    });

    stmt.execute(['session-1', toolJson, 'msg-old', 'turn-old', 'superseded']);

    final match = db.findOriginatingToolCall(
      'session-1',
      toolCallId: 'call_superseded_1',
    );
    expect(match, isNull);
  });
}
