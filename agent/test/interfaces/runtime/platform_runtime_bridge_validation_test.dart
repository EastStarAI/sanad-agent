import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('PlatformRuntimeBridge Identity and Kind Validation', () {
    late AgentStateDatabase state;
    late PlatformRuntimeBridge bridge;

    setUp(() async {
      await getIt.reset();
      SessionManager.resetForTesting();
      state = AgentStateDatabase.inMemory();
      getIt.registerSingleton<AgentStateDatabase>(state);
      bridge = PlatformRuntimeBridge();
      bridge.attachResponseSink((response) {});
    });

    tearDown(() async {
      SessionManager.resetForTesting();
      await getIt.reset();
      state.dispose();
    });

    test('validates required request_id and session_id', () async {
      final missingReqId = await bridge.handlePermissionResponse(
        CanonicalEvent(
          type: CanonicalEventTypes.toolPermissionResponse,
          sessionId: 'sess-1',
          payload: {'session_id': 'sess-1'},
        ),
      );
      expect(missingReqId.isSuccess, isFalse);
      expect(missingReqId.errorCode, equals('MISSING_REQUEST_ID'));

      final missingSessId = await bridge.handlePermissionResponse(
        CanonicalEvent(
          type: CanonicalEventTypes.toolPermissionResponse,
          payload: {'request_id': 'req-1'},
        ),
      );
      expect(missingSessId.isSuccess, isFalse);
      expect(missingSessId.errorCode, equals('MISSING_SESSION_ID'));
    });

    test(
      'rejects cross-session response without consuming pending request',
      () async {
        final pendingFuture = bridge.requestToolPermission(
          sessionId: 'session-alpha',
          payload: {
            'request_id': 'perm-cross-1',
            'tool_name': 'shell_execute',
            'tool_input': {'command': 'ls'},
          },
        );

        // Attempt response with mismatched session id
        final result = await bridge.handlePermissionResponse(
          CanonicalEvent(
            type: CanonicalEventTypes.toolPermissionResponse,
            sessionId: 'session-beta',
            payload: {
              'request_id': 'perm-cross-1',
              'session_id': 'session-beta',
              'allowed': true,
              'decision': 'allow',
            },
          ),
        );

        expect(result.isSuccess, isFalse);
        expect(result.outcome, equals('cross_session_mismatch'));
        expect(result.errorCode, equals('CROSS_SESSION_MISMATCH'));
        expect(
          result.errorMessage,
          contains(
            'Request perm-cross-1 belongs to session session-alpha, not session-beta',
          ),
        );

        // Verify request was NOT consumed and can still be answered with matching session
        final validResult = await bridge.handlePermissionResponse(
          CanonicalEvent(
            type: CanonicalEventTypes.toolPermissionResponse,
            sessionId: 'session-alpha',
            payload: {
              'request_id': 'perm-cross-1',
              'session_id': 'session-alpha',
              'allowed': true,
              'decision': 'allow',
            },
          ),
        );

        expect(validResult.isSuccess, isTrue);
        final completedDecision = await pendingFuture;
        expect(completedDecision['allowed'], isTrue);
      },
    );

    test(
      'rejects clarification question response when answer is missing without consuming request',
      () async {
        final pendingFuture = bridge.requestToolPermission(
          sessionId: 'session-ask',
          payload: {
            'request_id': 'req-ask-1',
            'tool_name': 'system_ask_user',
            'questions': [
              {'question': 'Proceed?'},
            ],
          },
        );

        // Attempt answering without an 'answer' (e.g. generic tool permission allow)
        final invalidResult = await bridge.handlePermissionResponse(
          CanonicalEvent(
            type: CanonicalEventTypes.toolPermissionResponse,
            sessionId: 'session-ask',
            payload: {
              'request_id': 'req-ask-1',
              'session_id': 'session-ask',
              'allowed': true,
              'decision': 'allow',
            },
          ),
        );

        expect(invalidResult.isSuccess, isFalse);
        expect(invalidResult.outcome, equals('wrong_kind'));
        expect(invalidResult.errorCode, equals('INVALID_ANSWER'));

        // Also attempt with whitespace only answer
        final whitespaceResult = await bridge.handlePermissionResponse(
          CanonicalEvent(
            type: CanonicalEventTypes.toolPermissionResponse,
            sessionId: 'session-ask',
            payload: {
              'request_id': 'req-ask-1',
              'session_id': 'session-ask',
              'answer': '   ',
            },
          ),
        );
        expect(whitespaceResult.isSuccess, isFalse);
        expect(whitespaceResult.errorCode, equals('INVALID_ANSWER'));

        // Correct response with non-empty answer consumes and completes
        final validResult = await bridge.handlePermissionResponse(
          CanonicalEvent(
            type: CanonicalEventTypes.toolPermissionResponse,
            sessionId: 'session-ask',
            payload: {
              'request_id': 'req-ask-1',
              'session_id': 'session-ask',
              'answer': 'Yes, proceed with tests',
            },
          ),
        );

        expect(validResult.isSuccess, isTrue);
        final completedDecision = await pendingFuture;
        expect(completedDecision['answer'], equals('Yes, proceed with tests'));
      },
    );

    test(
      'rejects tool permission response when allow/deny decision is missing without consuming request',
      () async {
        final pendingFuture = bridge.requestToolPermission(
          sessionId: 'session-tool',
          payload: {'request_id': 'req-tool-1', 'tool_name': 'file_write'},
        );

        // Response lacks 'allowed' and 'decision'
        final invalidResult = await bridge.handlePermissionResponse(
          CanonicalEvent(
            type: CanonicalEventTypes.toolPermissionResponse,
            sessionId: 'session-tool',
            payload: {
              'request_id': 'req-tool-1',
              'session_id': 'session-tool',
              'comment': 'just a comment',
            },
          ),
        );

        expect(invalidResult.isSuccess, isFalse);
        expect(invalidResult.outcome, equals('wrong_kind'));
        expect(invalidResult.errorCode, equals('INVALID_DECISION'));

        // Correct response completes the request
        final validResult = await bridge.handlePermissionResponse(
          CanonicalEvent(
            type: CanonicalEventTypes.toolPermissionResponse,
            sessionId: 'session-tool',
            payload: {
              'request_id': 'req-tool-1',
              'session_id': 'session-tool',
              'allowed': false,
              'decision': 'deny',
              'comment': 'Forbidden path',
            },
          ),
        );

        expect(validResult.isSuccess, isTrue);
        final completedDecision = await pendingFuture;
        expect(completedDecision['allowed'], isFalse);
        expect(completedDecision['decision'], equals('deny'));
      },
    );

    test(
      'rejects duplicate or stale responses for already resolved requests',
      () async {
        bridge.requestToolPermission(
          sessionId: 'session-stale',
          payload: {'request_id': 'req-stale-1', 'tool_name': 'web_search'},
        );

        final first = await bridge.handlePermissionResponse(
          CanonicalEvent(
            type: CanonicalEventTypes.toolPermissionResponse,
            sessionId: 'session-stale',
            payload: {
              'request_id': 'req-stale-1',
              'session_id': 'session-stale',
              'allowed': true,
            },
          ),
        );
        expect(first.isSuccess, isTrue);

        final duplicate = await bridge.handlePermissionResponse(
          CanonicalEvent(
            type: CanonicalEventTypes.toolPermissionResponse,
            sessionId: 'session-stale',
            payload: {
              'request_id': 'req-stale-1',
              'session_id': 'session-stale',
              'allowed': true,
            },
          ),
        );

        expect(duplicate.isSuccess, isFalse);
        expect(duplicate.outcome, equals('already_resolved'));
        expect(duplicate.errorCode, equals('ALREADY_RESOLVED'));
      },
    );

    test('returns not_found when request ID is completely unknown', () async {
      final result = await bridge.handlePermissionResponse(
        CanonicalEvent(
          type: CanonicalEventTypes.toolPermissionResponse,
          sessionId: 'session-any',
          payload: {
            'request_id': 'unknown-req-999',
            'session_id': 'session-any',
            'allowed': true,
          },
        ),
      );

      expect(result.isSuccess, isFalse);
      expect(result.outcome, equals('not_found'));
      expect(result.errorCode, equals('REQUEST_NOT_FOUND'));
    });
  });
}
