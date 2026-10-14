import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:test/test.dart';

class _OpenRouterConfig extends Config {
  @override
  String get llmApiKey => 'test-key';

  @override
  String get llmBaseUrl => 'https://openrouter.ai/api/v1';

  @override
  String get llmModel => 'openai/gpt-5.5';

  @override
  String apiKeyFor(ProviderProfile profile) => llmApiKey;

  @override
  String baseUrlFor(ProviderProfile profile) => llmBaseUrl;
}

void main() {
  test('OpenRouter profile alone owns the documented app attribution', () {
    final openRouter = ProviderRegistry.findByNameOrAlias('openrouter')!;
    final openAi = ProviderRegistry.findByNameOrAlias('openai')!;

    expect(
      openRouter.defaultHeaders,
      containsPair('HTTP-Referer', 'https://sanad.eaststarai.com'),
    );
    expect(
      openRouter.defaultHeaders,
      containsPair('X-OpenRouter-Title', 'Sanad Agent'),
    );
    expect(openRouter.defaultHeaders, isNot(contains('X-Title')));
    expect(openAi.defaultHeaders, isNot(contains('HTTP-Referer')));
    expect(openAi.defaultHeaders, isNot(contains('X-OpenRouter-Title')));
  });

  test('OpenRouter sync and stream requests forward app attribution', () async {
    final capturedHeaders = <Map<String, String>>[];
    final client = MockClient((request) async {
      capturedHeaders.add(Map.of(request.headers));
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (body['stream'] == true) {
        return http.Response(
          [
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': 'Hello'},
                  'finish_reason': 'stop',
                },
              ],
            })}',
            'data: [DONE]',
          ].join('\n'),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'Hello'},
              'finish_reason': 'stop',
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final config = _OpenRouterConfig();
    final adapter = BaseOpenAIAdapter(
      config,
      ProviderRegistry.findByNameOrAlias('openrouter')!,
      client: client,
    );
    final history = [Message(role: MessageRole.user, content: 'Hi')];

    await adapter.generateResponse(history);
    await adapter.generateStream(history).toList();
    final openAiAdapter = BaseOpenAIAdapter(
      config,
      ProviderRegistry.findByNameOrAlias('openai')!,
      client: client,
    );
    await openAiAdapter.generateResponse(history);

    expect(capturedHeaders, hasLength(3));
    for (final headers in capturedHeaders.take(2)) {
      expect(
        _headerValue(headers, 'HTTP-Referer'),
        'https://sanad.eaststarai.com',
      );
      expect(_headerValue(headers, 'X-OpenRouter-Title'), 'Sanad Agent');
      expect(_headerValue(headers, 'Authorization'), 'Bearer test-key');
    }
    final openAiHeaders = capturedHeaders.last;
    expect(_headerValue(openAiHeaders, 'HTTP-Referer'), isNull);
    expect(_headerValue(openAiHeaders, 'X-OpenRouter-Title'), isNull);
    expect(_headerValue(openAiHeaders, 'Authorization'), 'Bearer test-key');
  });
}

String? _headerValue(Map<String, String> headers, String name) {
  final normalizedName = name.toLowerCase();
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == normalizedName) return entry.value;
  }
  return null;
}
