import 'dart:io';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/engine/history_healer.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late SessionManager sessionManager;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('history_healer_test_');
    setSanadHomeOverride(tempDir.path);
    sessionManager = SessionManager();
  });

  tearDown(() {
    SessionManager.resetForTesting();
    setSanadHomeOverride(null);
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('deferred launcher result protects unanswered tool call', () {
    final history = [
      Message(
        role: MessageRole.assistant,
        toolCalls: [
          ToolCall(
            id: 'switch-tool',
            name: 'shell_execute',
            arguments: const {},
          ),
        ],
      ),
    ];

    HistoryHealer.healHistory(
      history: history,
      sessionManager: sessionManager,
      sessionId: 'session-1',
      deferredToolCallIds: const {'switch-tool'},
    );

    expect(history, hasLength(1));
    expect(history.single.role, MessageRole.assistant);
  });

  test('genuinely abandoned unanswered tool call is marked interrupted', () {
    final session = sessionManager.createSession('test-model');
    final history = [
      Message(
        role: MessageRole.assistant,
        toolCalls: [
          ToolCall(
            id: 'abandoned-tool',
            name: 'shell_execute',
            arguments: const {},
          ),
        ],
      ),
    ];

    HistoryHealer.healHistory(
      history: history,
      sessionManager: sessionManager,
      sessionId: session.sessionId,
    );

    expect(history, hasLength(2));
    expect(history.last.role, MessageRole.tool);
    expect(history.last.toolCallId, 'abandoned-tool');
    expect(history.last.content, contains('agent stopped unexpectedly'));
    expect(history.last.content, isNot(contains('cancelled by user')));
    expect(history.last.metadata?['reason'], 'daemon_interrupted');
  });

  test('active executing tool is preserved for restart reconciliation', () {
    final session = sessionManager.createSession('test-model');
    final history = [
      Message(
        role: MessageRole.assistant,
        toolCalls: [
          ToolCall(
            id: 'active-shell',
            name: 'shell_execute',
            arguments: const {},
          ),
        ],
      ),
    ];

    HistoryHealer.healHistory(
      history: history,
      sessionManager: sessionManager,
      sessionId: session.sessionId,
      activeToolCallIds: const {'active-shell'},
    );

    expect(history, hasLength(1));
  });

  test('extracts only requester-bound non-terminal deferred results', () {
    final now = DateTime.utc(2026, 7, 30);
    SessionWorkItem item({
      required String id,
      required SessionWorkState state,
      required String toolCallId,
      required String requesterSessionId,
      required String requesterToolCallId,
    }) {
      return SessionWorkItem(
        workItemId: id,
        sessionId: 'session-1',
        sequence: 1,
        attempt: 0,
        state: state,
        continuationMetadata: {
          'deferred_tool_results': {
            toolCallId: {
              'kind': 'sanad_dev_switch',
              'transaction_id': 'switch-1',
              'manifest_path': '/tmp/runtime-switch.json',
              'requester_session_id': requesterSessionId,
              'requester_tool_call_id': requesterToolCallId,
            },
          },
        },
        createdAt: now,
        updatedAt: now,
      );
    }

    final protected = HistoryHealer.deferredToolCallIds(
      sessionId: 'session-1',
      workItems: [
        item(
          id: 'active',
          state: SessionWorkState.running,
          toolCallId: 'switch-tool',
          requesterSessionId: 'session-1',
          requesterToolCallId: 'switch-tool',
        ),
        item(
          id: 'wrong-requester',
          state: SessionWorkState.running,
          toolCallId: 'wrong-requester-tool',
          requesterSessionId: 'session-2',
          requesterToolCallId: 'wrong-requester-tool',
        ),
        item(
          id: 'terminal',
          state: SessionWorkState.completed,
          toolCallId: 'terminal-tool',
          requesterSessionId: 'session-1',
          requesterToolCallId: 'terminal-tool',
        ),
        item(
          id: 'mismatched-tool',
          state: SessionWorkState.running,
          toolCallId: 'metadata-key',
          requesterSessionId: 'session-1',
          requesterToolCallId: 'different-tool',
        ),
      ],
    );

    expect(protected, {'switch-tool'});
  });
}
