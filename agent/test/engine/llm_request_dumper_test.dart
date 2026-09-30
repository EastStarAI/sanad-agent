import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/llm_request_dumper.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sanadagent_dumper_test_');
    setSanadHomeOverride(tempDir.path);
    LLMRequestDumper.environmentOverride = null;
  });

  tearDown(() {
    setSanadHomeOverride(null);
    LLMRequestDumper.environmentOverride = null;
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('LLMRequestDumper Config and Environment Variable checks', () {
    test('isEnabled is false by default', () {
      expect(LLMRequestDumper.isEnabled, isFalse);
    });

    test('isEnabled is true when DUMP_REQUESTS is true or 1', () {
      LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'true'};
      expect(LLMRequestDumper.isEnabled, isTrue);

      LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': '1'};
      expect(LLMRequestDumper.isEnabled, isTrue);

      LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'false'};
      expect(LLMRequestDumper.isEnabled, isFalse);
    });

    test('isStdoutEnabled is true when DUMP_REQUESTS_STDOUT is true or 1', () {
      LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS_STDOUT': 'true'};
      expect(LLMRequestDumper.isStdoutEnabled, isTrue);

      LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS_STDOUT': '1'};
      expect(LLMRequestDumper.isStdoutEnabled, isTrue);

      LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS_STDOUT': 'false'};
      expect(LLMRequestDumper.isStdoutEnabled, isFalse);
    });
  });

  group('LLMRequestDumper File I/O checks', () {
    test(
      'dumpRequest returns null and does not write if isEnabled is false',
      () async {
        final path = await LLMRequestDumper.dumpRequest(
          sessionId: 'test-session',
          history: [Message(role: MessageRole.user, content: 'hi')],
          tools: [],
        );

        expect(path, isNull);
        final dumpDir = Directory(p.join(tempDir.path, 'request_dumps'));
        expect(dumpDir.existsSync(), isFalse);
      },
    );

    test('dumpRequest writes correct details to disk when enabled', () async {
      LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'true'};

      final history = [
        Message(role: MessageRole.user, content: 'Tell me a joke'),
        Message(
          role: MessageRole.assistant,
          content: 'Why did the chicken cross the road?',
        ),
      ];

      final tools = [
        {'name': 'get_weather', 'description': 'gets weather details'},
      ];

      final path = await LLMRequestDumper.dumpRequest(
        sessionId: 'test-session-123',
        history: history,
        tools: tools,
        model: 'gpt-4o',
        provider: 'openai',
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'sk-proj-super-secret-key-123456789',
        customMetadata: {'context_length': 4000},
      );

      expect(path, isNotNull);
      final file = File(path!);
      expect(file.existsSync(), isTrue);

      // Verify file contents
      final fileContent = await file.readAsString();
      final decoded = jsonDecode(fileContent) as Map<String, dynamic>;

      expect(decoded['session_id'], 'test-session-123');
      expect(decoded['model'], 'gpt-4o');
      expect(decoded['provider'], 'openai');
      expect(decoded['base_url'], 'https://api.openai.com/v1');

      // Key must be masked — SecretsRedactor now fully redacts bearer tokens
      // in Authorization headers (Plan 30 P1 §4).
      expect(decoded['api_key'], isNot(contains('super-secret-key')));

      expect(decoded['metadata']['context_length'], 4000);

      // Verify request payload
      final request = decoded['request'] as Map<String, dynamic>;
      expect(request['method'], 'POST');
      expect(request['url'], 'https://api.openai.com/v1/chat/completions');
      expect(request['headers']['Content-Type'], 'application/json');
      // Authorization header is fully redacted: Bearer *** (SecretsRedactor step 0).
      expect(request['headers']['Authorization'], equals('Bearer ***'));

      final body = request['body'] as Map<String, dynamic>;
      expect(body['model'], 'gpt-4o');

      final messagesJson = body['messages'] as List;
      expect(messagesJson.length, 2);
      expect(messagesJson[0]['content'], 'Tell me a joke');
      expect(messagesJson[1]['role'], 'assistant');

      final toolsJson = body['tools'] as List;
      expect(toolsJson.length, 1);
      expect(toolsJson[0]['name'], 'get_weather');
    });

    test(
      'dumpRequest logs error details if an exception is provided',
      () async {
        LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'true'};

        final exception = HttpException('Connection failed');

        final path = await LLMRequestDumper.dumpRequest(
          sessionId: 'test-session-err',
          history: [],
          tools: [],
          error: exception,
        );

        expect(path, isNotNull);
        final file = File(path!);
        final fileContent = await file.readAsString();
        final decoded = jsonDecode(fileContent) as Map<String, dynamic>;

        expect(decoded['error'], isNotNull);
        expect(decoded['error']['type'], 'HttpException');
        expect(decoded['error']['message'], contains('Connection failed'));
      },
    );

    test(
      'dumpRequest truncates base64 data URIs and raw base64 blocks',
      () async {
        LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'true'};

        final longBase64 = 'A' * 1200;
        final dataUri = 'data:image/png;base64,$longBase64';

        final history = [
          Message(role: MessageRole.user, content: dataUri),
          Message(role: MessageRole.assistant, content: longBase64),
        ];

        final path = await LLMRequestDumper.dumpRequest(
          sessionId: 'test-session-b64',
          history: history,
          tools: [],
        );

        expect(path, isNotNull);
        final file = File(path!);
        final fileContent = await file.readAsString();
        final decoded = jsonDecode(fileContent) as Map<String, dynamic>;

        final messagesJson = decoded['request']['body']['messages'] as List;

        // Data URI should be truncated
        final userContent = messagesJson[0]['content'] as String;
        expect(userContent, contains('[Base64 Data Truncated'));
        expect(userContent, startsWith('data:image/png;base64,'));

        // Raw base64 block should be truncated
        final assistantContent = messagesJson[1]['content'] as String;
        expect(assistantContent, contains('[Raw Base64 Data Truncated'));
      },
    );

    test('dumpRequest recursively redacts secrets inside payload', () async {
      LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'true'};

      final history = [
        Message(
          role: MessageRole.user,
          content: 'sk-proj-12345678901234567890',
        ),
        Message(
          role: MessageRole.assistant,
          content: 'Bearer sk-proj-12345678901234567890',
        ),
      ];

      final path = await LLMRequestDumper.dumpRequest(
        sessionId: 'test-session-redact',
        history: history,
        tools: [],
      );

      expect(path, isNotNull);
      final file = File(path!);
      final fileContent = await file.readAsString();
      final decoded = jsonDecode(fileContent) as Map<String, dynamic>;

      final messagesJson = decoded['request']['body']['messages'] as List;

      // SecretsRedactor fully redacts OpenAI-style keys.
      // sk-proj-... becomes sk-*** via the _keyPrefix pattern.
      final userContent = messagesJson[0]['content'] as String;
      expect(userContent, isNot(contains('12345678901234567890')));
      expect(userContent, equals('sk-***'));

      // Bearer sk-proj-... becomes Bearer *** via the _bearer pattern.
      final assistantContent = messagesJson[1]['content'] as String;
      expect(assistantContent, equals('Bearer ***'));
      expect(assistantContent, isNot(contains('12345678901234567890')));
    });

    test('recordError redacts embedded secrets from response bodies', () async {
      LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'true'};

      final path = await LLMRequestDumper.dumpRequest(
        sessionId: 'test-session-error-redact',
        history: const [],
        tools: const [],
      );

      expect(path, isNotNull);
      await LLMRequestDumper.recordError(
        _FakeHttpLikeError(
          statusCode: 401,
          uri: Uri.parse('https://api.example.com/v1?api_key=sk-secret-123'),
          responseBody:
              'Authorization failed for Bearer sk-secret-123 and api_key=sk-secret-123',
        ),
      );

      final decoded =
          jsonDecode(await File(path!).readAsString()) as Map<String, dynamic>;
      final error = decoded['error'] as Map<String, dynamic>;
      expect(error['uri'], isNot(contains('sk-secret-123')));
      expect(error['response_body'], isNot(contains('sk-secret-123')));
      expect(error['response_body'], contains('Bearer ***'));
    });

    test(
      'dumpResponse correctly adds response payload to the last dump file',
      () async {
        LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'true'};

        final path = await LLMRequestDumper.dumpRequest(
          sessionId: 'test-session-resp',
          history: [],
          tools: [],
        );

        expect(path, isNotNull);
        expect(LLMRequestDumper.lastDumpFilePath, equals(path));

        final responsePayload = {
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'Hello!'},
            },
          ],
        };

        await LLMRequestDumper.dumpResponse(responsePayload);

        final file = File(path!);
        expect(file.existsSync(), isTrue);

        final fileContent = await file.readAsString();
        final decoded = jsonDecode(fileContent) as Map<String, dynamic>;

        expect(decoded['response'], isNotNull);
        expect(
          decoded['response']['choices'][0]['message']['content'],
          'Hello!',
        );
      },
    );

    test(
      'dumpResponse correctly records aggregated final response structure',
      () async {
        LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'true'};

        final path = await LLMRequestDumper.dumpRequest(
          sessionId: 'test-session-aggregated',
          history: [],
          tools: [],
        );

        expect(path, isNotNull);

        final aggregatedResponse = {
          'status_code': 200,
          'message': {
            'role': 'assistant',
            'content': 'Here is the summary of the task.',
            'reasoning': 'User asked for a summary, processing now.',
            'tool_calls': [
              {
                'id': 'call_abc123',
                'name': 'search_web',
                'arguments': {'query': 'sanad agent'},
              },
            ],
          },
          'finish_reason': 'toolCalls',
          'usage': {
            'prompt_tokens': 120,
            'completion_tokens': 45,
            'total_tokens': 165,
          },
        };

        await LLMRequestDumper.dumpResponse(aggregatedResponse);

        final file = File(path!);
        expect(file.existsSync(), isTrue);

        final fileContent = await file.readAsString();
        final decoded = jsonDecode(fileContent) as Map<String, dynamic>;

        expect(decoded['response'], isNotNull);
        final resp = decoded['response'] as Map<String, dynamic>;
        expect(resp['status_code'], 200);
        expect(resp['message']['role'], 'assistant');
        expect(resp['message']['content'], 'Here is the summary of the task.');
        expect(resp['message']['reasoning'], 'User asked for a summary, processing now.');
        expect(resp['message']['tool_calls'], isA<List>());
        expect(resp['message']['tool_calls'][0]['name'], 'search_web');
        expect(resp['finish_reason'], 'toolCalls');
        expect(resp['usage']['total_tokens'], 165);
      },
    );
  });
}

class _FakeHttpLikeError {
  final int statusCode;
  final Uri uri;
  final _FakeResponse response;

  _FakeHttpLikeError({
    required this.statusCode,
    required this.uri,
    required String responseBody,
  }) : response = _FakeResponse(statusCode: statusCode, body: responseBody);

  @override
  String toString() => 'HTTP $statusCode for $uri';
}

class _FakeResponse {
  final int statusCode;
  final String body;

  const _FakeResponse({required this.statusCode, required this.body});
}
