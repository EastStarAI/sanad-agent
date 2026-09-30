import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/adapters/base_anthropic_adapter.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/codex_responses_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/opencode_session_affinity.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:test/test.dart';

class _Config extends Config {
  @override
  String get llmApiKey => 'test-key';

  @override
  String get llmBaseUrl => 'https://opencode.ai/zen/go/v1';

  @override
  String get llmModel => 'test-model';

  @override
  String apiKeyFor(ProviderProfile profile) => 'test-key';

  @override
  String baseUrlFor(ProviderProfile profile) => llmBaseUrl;
}

void main() {
  const baseHeaders = <String, String>{'Content-Type': 'application/json'};

  group('OpenCode session affinity policy', () {
    test('uses the durable session id and preserves explicit headers', () {
      final headers = withOpenCodeSessionAffinity(
        headers: const {...baseHeaders, openCodeSessionHeader: 'caller-pinned'},
        providerName: 'opencode-go',
        baseUrl: 'https://opencode.ai/zen/go/v1',
        sessionId: 'session-1',
      );

      expect(headers[openCodeSessionHeader], 'caller-pinned');
    });

    test('keeps distinct conversation identities distinct', () {
      Map<String, String> headersFor(String sessionId) =>
          withOpenCodeSessionAffinity(
            headers: baseHeaders,
            providerName: 'opencode-go',
            baseUrl: 'https://opencode.ai/zen/go/v1',
            sessionId: sessionId,
          );

      expect(headersFor('session-1')[openCodeSessionHeader], 'session-1');
      expect(headersFor('session-2')[openCodeSessionHeader], 'session-2');
    });

    test('detects exact OpenCode hosts without suffix spoofing', () {
      final exactHost = withOpenCodeSessionAffinity(
        headers: baseHeaders,
        providerName: 'custom',
        baseUrl: 'https://opencode.ai/zen/go/v1',
        sessionId: 'session-1',
      );
      final deceptiveHost = withOpenCodeSessionAffinity(
        headers: baseHeaders,
        providerName: 'custom',
        baseUrl: 'https://opencode.ai.attacker.test/v1',
        sessionId: 'session-1',
      );
      final unrelated = withOpenCodeSessionAffinity(
        headers: baseHeaders,
        providerName: 'openrouter',
        baseUrl: 'https://openrouter.ai/api/v1',
        sessionId: 'session-1',
      );

      expect(exactHost[openCodeSessionHeader], 'session-1');
      expect(deceptiveHost, isNot(contains(openCodeSessionHeader)));
      expect(unrelated, isNot(contains(openCodeSessionHeader)));
    });
  });

  group('OpenCode adapter request parity', () {
    final config = _Config();
    final history = [Message(role: MessageRole.user, content: 'hello')];
    const options = LLMRequestOptions(sessionId: 'conversation-42');

    test('OpenAI sync and stream send the same affinity header', () async {
      final captured = <http.BaseRequest>[];
      final adapter = BaseOpenAIAdapter(
        config,
        const ProviderProfile(name: 'opencode-go'),
        baseUrlOverride: config.llmBaseUrl,
        apiKeyOverride: config.llmApiKey,
        defaultModelOverride: 'glm-5',
        client: _failingClient(captured),
      );

      await _expectHttpFailure(
        adapter.generateResponse(history, options: options),
      );
      await _expectHttpFailure(
        adapter.generateStream(history, options: options).drain(),
      );

      _expectAffinity(captured);
    });

    test('Anthropic sync and stream send the same affinity header', () async {
      final captured = <http.BaseRequest>[];
      final adapter = BaseAnthropicAdapter(
        config,
        const ProviderProfile(
          name: 'opencode-go',
          apiMode: 'anthropic_messages',
        ),
        baseUrlOverride: config.llmBaseUrl,
        apiKeyOverride: config.llmApiKey,
        defaultModelOverride: 'minimax-m2.7',
        client: _failingClient(captured),
      );

      await _expectHttpFailure(
        adapter.generateResponse(history, options: options),
      );
      await _expectHttpFailure(
        adapter.generateStream(history, options: options).drain(),
      );

      _expectAffinity(captured);
    });

    test('Responses sync and stream send the same affinity header', () async {
      final captured = <http.BaseRequest>[];
      final adapter = CodexResponsesAdapter(
        config,
        const ProviderProfile(name: 'opencode-go', apiMode: 'codex_responses'),
        baseUrlOverride: config.llmBaseUrl,
        apiKeyOverride: config.llmApiKey,
        defaultModelOverride: 'gpt-5.6-luna',
        client: _failingClient(captured),
      );

      await _expectHttpFailure(
        adapter.generateResponse(history, options: options),
      );
      await _expectHttpFailure(
        adapter.generateStream(history, options: options).drain(),
      );

      _expectAffinity(captured);
    });
  });
}

MockClient _failingClient(List<http.BaseRequest> captured) {
  return MockClient((request) async {
    captured.add(request);
    return http.Response('{"error":"expected test failure"}', 500);
  });
}

Future<void> _expectHttpFailure(Future<Object?> request) async {
  await expectLater(request, throwsA(isA<LlmHttpException>()));
}

void _expectAffinity(List<http.BaseRequest> requests) {
  expect(requests, hasLength(2));
  for (final request in requests) {
    expect(request.headers[openCodeSessionHeader], 'conversation-42');
  }
}
