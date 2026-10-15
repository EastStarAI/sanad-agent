import 'dart:convert';

import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('PlatformRuntimeBridge Secret Request Handling', () {
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

    test('validates and completes secret request with credentials map', () async {
      final pendingFuture = bridge.requestToolPermission(
        sessionId: 'session-secret-1',
        payload: {
          'request_id': 'req-sec-1',
          'tool_name': 'system_request_secret',
          'fields': [
            {'id': 'api_key', 'label': 'API Key', 'is_secret': true},
          ],
          'reason': 'API Key required',
        },
      );

      final result = await bridge.handlePermissionResponse(
        CanonicalEvent(
          type: CanonicalEventTypes.toolPermissionResponse,
          sessionId: 'session-secret-1',
          payload: {
            'request_id': 'req-sec-1',
            'session_id': 'session-secret-1',
            'allowed': true,
            'values': {'api_key': 'super-secret-value-123'},
          },
        ),
      );

      expect(result.isSuccess, isTrue);
      final decision = await pendingFuture;
      expect(decision['allowed'], isTrue);
      expect((decision['values'] as Map)['api_key'], 'super-secret-value-123');
    });

    test('validates and completes secret request with JSON answer string', () async {
      final pendingFuture = bridge.requestToolPermission(
        sessionId: 'session-secret-2',
        payload: {
          'request_id': 'req-sec-2',
          'tool_name': 'system_request_secret',
          'fields': [
            {'id': 'token', 'label': 'Token', 'is_secret': true},
          ],
          'reason': 'Token required',
        },
      );

      final result = await bridge.handlePermissionResponse(
        CanonicalEvent(
          type: CanonicalEventTypes.toolPermissionResponse,
          sessionId: 'session-secret-2',
          payload: {
            'request_id': 'req-sec-2',
            'session_id': 'session-secret-2',
            'allowed': true,
            'answer': jsonEncode({'token': 'token-secret-xyz'}),
          },
        ),
      );

      expect(result.isSuccess, isTrue);
      final decision = await pendingFuture;
      expect(decision['allowed'], isTrue);
      final answerMap = jsonDecode(decision['answer'] as String) as Map<String, dynamic>;
      expect(answerMap['token'], 'token-secret-xyz');
    });

    test('validates and completes secret request with skip / denied decision', () async {
      final pendingFuture = bridge.requestToolPermission(
        sessionId: 'session-secret-3',
        payload: {
          'request_id': 'req-sec-3',
          'tool_name': 'system_request_secret',
          'fields': [
            {'id': 'api_key', 'label': 'API Key', 'is_secret': true},
          ],
          'reason': 'API Key required',
        },
      );

      final result = await bridge.handlePermissionResponse(
        CanonicalEvent(
          type: CanonicalEventTypes.toolPermissionResponse,
          sessionId: 'session-secret-3',
          payload: {
            'request_id': 'req-sec-3',
            'session_id': 'session-secret-3',
            'allowed': false,
            'comment': 'User skipped entering API key',
          },
        ),
      );

      expect(result.isSuccess, isTrue);
      final decision = await pendingFuture;
      expect(decision['allowed'], isFalse);
    });

    test('rejects secret request allowed without any secret payload', () async {
      final pendingFuture = bridge.requestToolPermission(
        sessionId: 'session-secret-4',
        payload: {
          'request_id': 'req-sec-4',
          'tool_name': 'system_request_secret',
          'fields': [
            {'id': 'api_key', 'label': 'API Key', 'is_secret': true},
          ],
          'reason': 'API Key required',
        },
      );

      final result = await bridge.handlePermissionResponse(
        CanonicalEvent(
          type: CanonicalEventTypes.toolPermissionResponse,
          sessionId: 'session-secret-4',
          payload: {
            'request_id': 'req-sec-4',
            'session_id': 'session-secret-4',
            'allowed': true,
          },
        ),
      );

      expect(result.isSuccess, isFalse);
      expect(result.errorCode, equals('MISSING_SECRET_PAYLOAD'));

      // Complete legitimately so pendingFuture resolves
      await bridge.handlePermissionResponse(
        CanonicalEvent(
          type: CanonicalEventTypes.toolPermissionResponse,
          sessionId: 'session-secret-4',
          payload: {
            'request_id': 'req-sec-4',
            'session_id': 'session-secret-4',
            'allowed': false,
          },
        ),
      );
      await pendingFuture;
    });

    test('redacts secret values in resolved permission retention record', () async {
      final pendingFuture = bridge.requestToolPermission(
        sessionId: 'session-secret-5',
        payload: {
          'request_id': 'req-sec-5',
          'tool_name': 'system_request_secret',
          'fields': [
            {'id': 'pass', 'label': 'Password', 'is_secret': true},
          ],
          'reason': 'Password needed',
        },
      );

      await bridge.handlePermissionResponse(
        CanonicalEvent(
          type: CanonicalEventTypes.toolPermissionResponse,
          sessionId: 'session-secret-5',
          payload: {
            'request_id': 'req-sec-5',
            'session_id': 'session-secret-5',
            'allowed': true,
            'values': {'pass': 'ultra-secret-password'},
            'answer': jsonEncode({'pass': 'ultra-secret-password'}),
          },
        ),
      );
      await pendingFuture;

      // Duplicate submission checks resolved record
      final dupResult = await bridge.handlePermissionResponse(
        CanonicalEvent(
          type: CanonicalEventTypes.toolPermissionResponse,
          sessionId: 'session-secret-5',
          payload: {
            'request_id': 'req-sec-5',
            'session_id': 'session-secret-5',
            'allowed': true,
            'values': {'pass': 'attempt-again'},
          },
        ),
      );
      expect(dupResult.errorCode, equals('ALREADY_RESOLVED'));
    });
  });
}
