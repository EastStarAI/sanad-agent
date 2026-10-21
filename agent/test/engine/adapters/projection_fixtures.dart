/// Shared synthetic fixtures for Task 116 provider-compatible projection wire
/// tests. Every payload is synthetic; no live provider, credential or user
/// Home is involved.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/llm_provider_state.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/models_dev_service.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';

const goInstance = 'go-1';
const goBaseUrl = 'https://opencode.ai/zen/go/v1';
const goIssuer = '$goInstance|openai_compatible|$goBaseUrl';
const deepseek = 'deepseek-v4.1-flash';
const kimi = 'kimi-k2.6';
const codexIssuer =
    'codex-1|codex_responses|https://chatgpt.com/backend-api/codex';
const codexModel = 'gpt-6.1-sol';

class FixedRouteConfig extends Config {
  final String baseUrl;
  FixedRouteConfig(this.baseUrl) : super(environment: const {});

  @override
  String get llmApiKey => 'fixture-key';
  @override
  String get llmBaseUrl => baseUrl;
  @override
  String get llmModel => deepseek;
  @override
  String apiKeyFor(ProviderProfile profile) => 'fixture-key';
  @override
  String baseUrlFor(ProviderProfile profile) => baseUrl;
}

/// models.dev cache with exact-route `interleaved` declarations.
ModelsDevService fixtureModelsDev() {
  final dir = Directory.systemTemp.createTempSync('sanad_116_models_dev_');
  final path = p.join(dir.path, 'models_dev_cache.json');
  File(path).writeAsStringSync(
    jsonEncode({
      'opencode-go': {
        'models': {
          deepseek: {
            'id': deepseek,
            'interleaved': {'field': 'reasoning_content'},
          },
          kimi: {
            'id': kimi,
            'interleaved': {'field': 'reasoning_content'},
          },
        },
      },
      'openrouter': {
        'models': {
          'vendor/model-a': {
            'id': 'vendor/model-a',
            'interleaved': {'field': 'reasoning_details'},
          },
          'vendor/model-b': {
            'id': 'vendor/model-b',
            'interleaved': {'field': 'reasoning_details'},
          },
        },
      },
    }),
  );
  return ModelsDevService(cacheFilePathOverride: path);
}

/// Records each HTTP body and answers with [respond] (default: a final
/// Chat completion).
class WireRecorder {
  final bodies = <Map<String, dynamic>>[];
  final String Function(Map<String, dynamic> body)? respond;

  WireRecorder({this.respond});

  http.Client get client => MockClient((request) async {
    final body = (jsonDecode(request.body) as Map).cast<String, dynamic>();
    bodies.add(body);
    return http.Response(
      respond?.call(body) ?? chatFinal('done'),
      200,
      headers: {'content-type': 'application/json'},
    );
  });

  List<Map<String, dynamic>> get lastMessages =>
      (bodies.last['messages'] as List).cast<Map<String, dynamic>>();
}

String chatFinal(String text) => jsonEncode({
  'choices': [
    {
      'message': {'role': 'assistant', 'content': text},
      'finish_reason': 'stop',
    },
  ],
});

/// One SSE stream body for Chat completions.
String sse(List<Map<String, dynamic>> events) =>
    '${events.map((event) => 'data: ${jsonEncode(event)}').join('\n\n')}'
    '\n\ndata: [DONE]\n\n';

BaseOpenAIAdapter goAdapter(
  http.Client client, {
  ModelsDevService? modelsDev,
  String instance = goInstance,
  String profileName = 'opencode-go',
  String baseUrl = goBaseUrl,
}) {
  return BaseOpenAIAdapter(
    FixedRouteConfig(baseUrl),
    ProviderRegistry.findByNameOrAlias(profileName)!,
    client: client,
    modelsDevService: modelsDev,
    providerInstanceId: instance,
  );
}

ToolCall call(String id) => ToolCall(id: id, name: 'read_file', arguments: {
  'path': '$id.txt',
});

Message toolResult(String id) =>
    Message(role: MessageRole.tool, toolCallId: id, content: 'ok $id');

/// Assistant tool-call turn carrying [state] and optional legacy metadata.
Message toolTurn(
  String id, {
  LLMProviderState? state,
  Map<String, dynamic>? metadata,
}) => Message(
  role: MessageRole.assistant,
  content: '',
  toolCalls: [call(id)],
  providerState: state,
  metadata: metadata,
);

LLMProviderState chatState({
  String issuer = goIssuer,
  String? model = deepseek,
  Object? reasoning = _unset,
  String? field,
  List<dynamic>? details,
}) => LLMProviderState(
  namespace: 'openai_chat_completions',
  issuer: issuer,
  data: {
    if (!identical(reasoning, _unset)) 'reasoning_content': reasoning,
    'reasoning_details': ?details,
    'issuer_model': ?model,
    'reasoning_field': ?field,
  },
);

const Object _unset = Object();

LLMProviderState codexState() => const LLMProviderState(
  namespace: 'codex_responses',
  issuer: codexIssuer,
  data: {
    'reasoning_items': [
      {'type': 'reasoning', 'encrypted_content': 'sealed-codex'},
    ],
  },
);

/// Assistant wire messages that carry tool calls.
List<Map<String, dynamic>> assistantToolWire(List<Map<String, dynamic>> wire) =>
    wire
        .where((m) => m['role'] == 'assistant' && m['tool_calls'] != null)
        .toList();
