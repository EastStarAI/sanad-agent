import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/copilot_credential_lifecycle.dart';
import 'package:sanad_agent/engine/adapters/copilot_auth_recovery_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

void main() {
  final ok = AgentResponse(
    message: Message(role: MessageRole.assistant, content: 'ok'),
  );

  LlmHttpException unauthorized() => const LlmHttpException(
    statusCode: 401,
    body: 'expired',
    headers: {},
    operation: 'generateResponse',
  );

  test('retries generateResponse once after a 401 recovery', () async {
    var builds = 0;
    final inner = _ScriptedAdapter(
      responses: [
        () => throw unauthorized(),
        () => ok,
      ],
    );
    final lifecycle = _FakeLifecycle(recover: true, refresh: false);
    final adapter = CopilotAuthRecoveryAdapter(
      inner: inner,
      rebuild: () {
        builds++;
        return inner;
      },
      lifecycle: lifecycle,
      instanceId: 'inst-1',
    );

    final result = await adapter.generateResponse(const []);
    expect(result.message.content, equals('ok'));
    expect(lifecycle.recoveries, equals(1));
    expect(lifecycle.reloginMarks, equals(0));
    expect(builds, equals(1));
  });

  test('marks relogin_required when the retry is still 401', () async {
    final inner = _ScriptedAdapter(
      responses: [
        () => throw unauthorized(),
        () => throw unauthorized(),
      ],
    );
    final lifecycle = _FakeLifecycle(recover: true, refresh: false);
    final adapter = CopilotAuthRecoveryAdapter(
      inner: inner,
      rebuild: () => inner,
      lifecycle: lifecycle,
      instanceId: 'inst-1',
    );

    await expectLater(
      adapter.generateResponse(const []),
      throwsA(
        isA<LlmHttpException>().having((e) => e.statusCode, 'status', 401),
      ),
    );
    expect(lifecycle.recoveries, equals(1));
    expect(lifecycle.reloginMarks, equals(1));
  });

  test('does not retry when recovery fails', () async {
    final inner = _ScriptedAdapter(
      responses: [() => throw unauthorized()],
    );
    final adapter = CopilotAuthRecoveryAdapter(
      inner: inner,
      rebuild: () => inner,
      lifecycle: _FakeLifecycle(recover: false, refresh: false),
      instanceId: 'inst-1',
    );

    await expectLater(
      adapter.generateResponse(const []),
      throwsA(
        isA<LlmHttpException>().having((e) => e.statusCode, 'status', 401),
      ),
    );
  });

  test('retries generateStream once after a 401 before any event', () async {
    final inner = _ScriptedAdapter(
      streams: [
        () => throw unauthorized(),
        () => ok,
      ],
    );
    final lifecycle = _FakeLifecycle(recover: true, refresh: false);
    final adapter = CopilotAuthRecoveryAdapter(
      inner: inner,
      rebuild: () => inner,
      lifecycle: lifecycle,
      instanceId: 'inst-1',
    );

    final events = await adapter.generateStream(const []).toList();
    expect(events.single.message.content, equals('ok'));
    expect(lifecycle.recoveries, equals(1));
    expect(lifecycle.reloginMarks, equals(0));
  });

  test('marks relogin_required when the stream retry is still 401', () async {
    final inner = _ScriptedAdapter(
      streams: [
        () => throw unauthorized(),
        () => throw unauthorized(),
      ],
    );
    final lifecycle = _FakeLifecycle(recover: true, refresh: false);
    final adapter = CopilotAuthRecoveryAdapter(
      inner: inner,
      rebuild: () => inner,
      lifecycle: lifecycle,
      instanceId: 'inst-1',
    );

    await expectLater(
      adapter.generateStream(const []).toList(),
      throwsA(
        isA<LlmHttpException>().having((e) => e.statusCode, 'status', 401),
      ),
    );
    expect(lifecycle.recoveries, equals(1));
    expect(lifecycle.reloginMarks, equals(1));
  });

  test('does not retry a stream 401 after events have already been emitted', () async {
    final inner = _ScriptedAdapter(
      streams: [
        () => ok,
        () => throw unauthorized(),
      ],
      emitThenThrow: true,
    );
    final lifecycle = _FakeLifecycle(recover: true, refresh: false);
    final adapter = CopilotAuthRecoveryAdapter(
      inner: inner,
      rebuild: () => inner,
      lifecycle: lifecycle,
      instanceId: 'inst-1',
    );

    final received = <AgentResponse>[];
    await expectLater(
      () async {
        await for (final event in adapter.generateStream(const [])) {
          received.add(event);
        }
      }(),
      throwsA(
        isA<LlmHttpException>().having((e) => e.statusCode, 'status', 401),
      ),
    );
    expect(received, isNotEmpty);
    expect(lifecycle.recoveries, equals(0));
  });

  test('does not retry a non-401 failure', () async {
    final inner = _ScriptedAdapter(
      responses: [
        () => throw const LlmHttpException(
          statusCode: 500,
          body: 'boom',
          headers: {},
          operation: 'generateResponse',
        ),
      ],
    );
    final lifecycle = _FakeLifecycle(recover: true, refresh: false);
    final adapter = CopilotAuthRecoveryAdapter(
      inner: inner,
      rebuild: () => inner,
      lifecycle: lifecycle,
      instanceId: 'inst-1',
    );

    await expectLater(
      adapter.generateResponse(const []),
      throwsA(
        isA<LlmHttpException>().having((e) => e.statusCode, 'status', 500),
      ),
    );
    expect(lifecycle.recoveries, equals(0));
  });
}

class _FakeLifecycle implements CopilotCredentialLifecycle {
  final bool recover;
  final bool refresh;
  int recoveries = 0;
  int reloginMarks = 0;

  _FakeLifecycle({required this.recover, required this.refresh});

  @override
  Future<bool> ensureFresh(String instanceId, {DateTime? now}) async =>
      refresh;

  @override
  Future<bool> recoverUnauthorized(String instanceId) async {
    recoveries++;
    return recover;
  }

  @override
  Future<void> markReloginRequired(String instanceId, {DateTime? now}) async {
    reloginMarks++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ScriptedAdapter implements LLMAdapter {
  final List<Object Function()> responses;
  final List<Object Function()> streams;
  final bool emitThenThrow;
  int _responseI = 0;
  int _streamI = 0;

  _ScriptedAdapter({
    List<Object Function()>? responses,
    List<Object Function()>? streams,
    this.emitThenThrow = false,
  }) : responses = responses ?? const [],
       streams = streams ?? responses ?? const [];

  T _next<T>(List<Object Function()> source, int Function() read, void Function(int) write) {
    final i = read();
    write(i + 1);
    return source[i]() as T;
  }

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    return _next<AgentResponse>(
      responses,
      () => _responseI,
      (v) => _responseI = v,
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    if (emitThenThrow) {
      yield _next<AgentResponse>(
        streams,
        () => _streamI,
        (v) => _streamI = v,
      );
    }
    yield _next<AgentResponse>(
      streams,
      () => _streamI,
      (v) => _streamI = v,
    );
  }

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 0;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];
}
