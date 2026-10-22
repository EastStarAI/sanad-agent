import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/translators/agent_to_canonical.dart';
import 'package:test/test.dart';

import '../support/memory_agent_secret_store.dart';

/// A terminal refusal must keep the identity of the request that produced it.
///
/// Without `request_id` a client that is waiting for its own send cannot tell
/// a refusal of that send from any other terminal answer on the session, so it
/// waits forever (Task 125 G2 round 3).
void main() {
  late SanadProtocolBridge bridge;

  setUp(() async {
    await getIt.reset();
    final authManager = _TestAuthManager();
    getIt.registerSingleton<AuthManager>(authManager);
    bridge = SanadProtocolBridge();
  });

  tearDown(() async {
    await getIt.reset();
  });

  test('a pre-start refusal final answer carries its request id on the wire', () {
    final response = GatewayResponse(
      sessionId: 'session-1',
      message: Message(
        role: MessageRole.assistant,
        content: 'Error: turn_failed: Bad state: Workspace folder is unavailable.',
        metadata: const {'error_code': 'turn_failed'},
      ),
      isComplete: true,
      runId: 'run-1',
      turnId: 'turn-1',
      requestId: 'req-refused',
    );

    final canonical = bridge.translateResponse(response);
    expect(canonical.type, 'final_answer');
    expect(canonical.payload['error_code'], 'turn_failed');
    expect(canonical.payload['request_id'], 'req-refused');

    final envelope = bridge.buildAgentEventEnvelope(canonical);
    expect(envelope['request_id'], 'req-refused');
    expect(
      (envelope['payload'] as Map<String, dynamic>)['request_id'],
      'req-refused',
    );
  });

  test('a blocked runtime notice keeps its originating request id on the wire', () {
    final now = DateTime.now().toUtc();
    final notice = RuntimeNotice(
      sessionId: 'session-1',
      requestId: 'req-blocked',
      runId: 'run-1',
      status: RuntimeNoticeStatus.blocked,
      reason: RuntimeFailureReason.auth,
      severity: RuntimeNoticeSeverity.error,
      title: 'Provider authentication failed',
      message: 'Update the provider credentials to continue.',
      actions: const [RuntimeNoticeAction.retry],
      createdAt: now,
      updatedAt: now,
    );

    final canonical = bridge.translateResponse(
      GatewayResponse(
        sessionId: 'session-1',
        message: Message(
          role: MessageRole.assistant,
          metadata: {
            'canonical_event_type': 'session.runtime_notice',
            'canonical_payload': notice.toPayload(),
          },
        ),
      ),
    );
    expect(canonical.payload['status'], 'blocked');
    expect(canonical.payload['request_id'], 'req-blocked');

    final envelope = bridge.buildAgentEventEnvelope(canonical);
    expect(envelope['request_id'], 'req-blocked');
  });

  test('an answer with no request identity advertises none', () {
    final canonical = AgentToCanonical.translate(
      GatewayResponse(
        sessionId: 'session-1',
        message: Message(
          role: MessageRole.assistant,
          content: 'Hello.',
          metadata: const {'error_code': 'turn_failed'},
        ),
        isComplete: true,
      ),
    );

    expect(canonical.payload.containsKey('request_id'), isFalse);
  });
}

class _TestAuthManager extends AuthManager {
  _TestAuthManager() : super(secretStore: MemoryAgentSecretStore());

  @override
  String? get hardwareId => 'hardware-wire-test';

  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Future<bool> reload({bool notifyIfChanged = false}) async => true;
}
