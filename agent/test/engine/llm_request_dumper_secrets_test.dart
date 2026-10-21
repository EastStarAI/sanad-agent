import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/llm_request_dumper.dart';

/// Task 116 security boundary: request dumps must never contain any part of a
/// credential, including keys that carry no recognizable vendor prefix and
/// credentials sent in non-`Authorization` headers.
void main() {
  late Directory tempDir;

  // Synthetic credential without a recognized `sk-`/`nvapi-` prefix.
  const credential = 'ocgoKEYabcdefghijklmnopqrstuvwxyz0123456789TAIL';
  const head = 'ocgoKEYa';
  const tail = 'TAIL';

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sanad_dumper_secret_');
    setSanadHomeOverride(tempDir.path);
    LLMRequestDumper.resetForTesting();
    LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'true'};
  });

  tearDown(() {
    setSanadHomeOverride(null);
    LLMRequestDumper.resetForTesting();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  void expectNoCredential(String text) {
    expect(text, isNot(contains(credential)));
    expect(text, isNot(contains(head)), reason: 'key prefix leaked');
    expect(text, isNot(contains('...$tail')), reason: 'key suffix leaked');
  }

  test('dumpRequest never writes a partial api key', () async {
    final path = await LLMRequestDumper.dumpRequest(
      sessionId: 's1',
      history: [Message(role: MessageRole.user, content: 'hi')],
      tools: const [],
      model: 'm',
      provider: 'opencode-go',
      baseUrl: 'https://example.invalid/v1',
      apiKey: credential,
      requestId: 'r1',
    );
    final text = await File(path!).readAsString();
    expectNoCredential(text);
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    expect(decoded['api_key'], '***');
    expect(decoded['request']['headers']['Authorization'], 'Bearer ***');
  });

  test('recordActualRequest masks every credential-bearing header', () async {
    final path = await LLMRequestDumper.recordActualRequest(
      url: Uri.parse('https://example.invalid/v1/messages'),
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': credential,
        'api-key': credential,
        'Authorization': 'Token $credential',
        'anthropic-version': '2023-06-01',
      },
      body: {'model': 'm', 'messages': const []},
      sessionId: 's2',
    );
    final text = await File(path!).readAsString();
    expectNoCredential(text);
    final headers =
        (jsonDecode(text) as Map<String, dynamic>)['request']['headers']
            as Map<String, dynamic>;
    expect(headers['x-api-key'], '***');
    expect(headers['api-key'], '***');
    expect(headers['Authorization'], '***');
    expect(headers['anthropic-version'], '2023-06-01');
    expect(headers['Content-Type'], 'application/json');
  });

  test('transport update on an existing dump masks headers too', () async {
    await LLMRequestDumper.dumpRequest(
      sessionId: 's3',
      history: const [],
      tools: const [],
      apiKey: credential,
      requestId: 'r3',
    );
    final path = await LLMRequestDumper.recordActualRequest(
      url: Uri.parse('https://example.invalid/v1/messages'),
      headers: {'x-api-key': credential, 'Authorization': 'Bearer $credential'},
      body: const {'messages': []},
      requestId: 'r3',
    );
    final text = await File(path!).readAsString();
    expectNoCredential(text);
  });
}
