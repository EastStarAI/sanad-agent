import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';
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
    LLMRequestDumper.resetForTesting();
  });

  tearDown(() {
    setSanadHomeOverride(null);
    LLMRequestDumper.resetForTesting();
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

        // Data URI and raw base64 are fully redacted without samples.
        final userContent = messagesJson[0]['content'] as String;
        expect(
          userContent,
          '[image payload redacted: mime=image/png, bytes=900]',
        );

        final assistantContent = messagesJson[1]['content'] as String;
        expect(
          assistantContent,
          '[binary payload redacted: mime=unknown, bytes=900]',
        );
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
        expect(
          resp['message']['reasoning'],
          'User asked for a summary, processing now.',
        );
        expect(resp['message']['tool_calls'], isA<List>());
        expect(resp['message']['tool_calls'][0]['name'], 'search_web');
        expect(resp['finish_reason'], 'toolCalls');
        expect(resp['usage']['total_tokens'], 165);
      },
    );

    test(
      'dumpResponse for unpaired response with null lastDumpFilePath logs at fine level without warning',
      () async {
        LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'true'};
        LLMRequestDumper.lastDumpFilePath = null;

        final prevLevel = Logger.root.level;
        Logger.root.level = Level.ALL;
        addTearDown(() => Logger.root.level = prevLevel);

        final records = <LogRecord>[];
        final subscription = Logger('LLMRequestDumper').onRecord.listen(records.add);
        addTearDown(subscription.cancel);

        await LLMRequestDumper.dumpResponse({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'unpaired'},
            },
          ],
        });

        // No operational warnings emitted for expected unpaired responses.
        expect(
          records.where((r) => r.level >= Level.WARNING),
          isEmpty,
          reason: 'Expected no warning or severe logs for unpaired response',
        );

        // Diagnostic fine log is recorded.
        expect(
          records.where(
            (r) =>
                r.level == Level.FINE &&
                r.message.contains('lastDumpFilePath is null'),
          ),
          isNotEmpty,
        );
      },
    );

    test(
      'dumpResponse for auxiliary compaction request skips dumping and preserves previous turn dump file',
      () async {
        LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'true'};

        // Simulate an earlier turn that dumped its request.
        final turn1Path = await LLMRequestDumper.dumpRequest(
          sessionId: 'test-session-earlier-turn',
          history: [Message(role: MessageRole.user, content: 'turn 1 question')],
          tools: [],
        );
        expect(turn1Path, isNotNull);
        final fileBefore = await File(turn1Path!).readAsString();

        final prevLevel = Logger.root.level;
        Logger.root.level = Level.ALL;
        addTearDown(() => Logger.root.level = prevLevel);

        final records = <LogRecord>[];
        final subscription = Logger('LLMRequestDumper').onRecord.listen(records.add);
        addTearDown(subscription.cancel);

        // Auxiliary compaction completion response arrives with compaction request ID.
        await LLMRequestDumper.dumpResponse(
          {
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': 'compaction summary text should never dump into turn 1 file',
                },
              },
            ],
          },
          requestId: 'compaction:uuid-12345',
        );

        // The earlier turn dump file was NOT modified by the auxiliary compaction.
        final fileAfter = await File(turn1Path).readAsString();
        expect(fileAfter, equals(fileBefore));
        expect(fileAfter, isNot(contains('compaction summary text')));

        // No operational warnings emitted.
        expect(records.where((r) => r.level >= Level.WARNING), isEmpty);
        expect(
          records.where(
            (r) =>
                r.level == Level.FINE &&
                r.message.contains('Skipping LLM response dump for auxiliary compaction request'),
          ),
          isNotEmpty,
        );
      },
    );
  });

  group('binary redaction', () {
    test(
      'replaces recursive typed image payloads with MIME and byte count',
      () {
        final png = base64.encode(const [1, 2, 3, 4]);
        final payload = {
          'canonical': {
            'type': 'image',
            'dataBase64': png,
            'mimeType': 'image/png',
          },
          'anthropic': {
            'type': 'image',
            'source': {
              'type': 'base64',
              'media_type': 'image/webp',
              'data': png,
            },
          },
          'responses': [
            {'type': 'input_image', 'image_url': 'data:image/jpeg;base64,$png'},
          ],
        };

        final sanitized = LLMRequestDumper.sanitizePayloadForTesting(payload);
        expect(sanitized['canonical'], {
          'type': 'image_redacted',
          'mime_type': 'image/png',
          'decoded_bytes': 4,
        });
        expect(sanitized['anthropic'], {
          'type': 'image_redacted',
          'mime_type': 'image/webp',
          'decoded_bytes': 4,
        });
        expect(sanitized['responses'].single, {
          'type': 'image_redacted',
          'mime_type': 'image/jpeg',
          'decoded_bytes': 4,
        });
        expect(jsonEncode(sanitized), isNot(contains(png)));
      },
    );

    test('redacts data URIs and malformed typed blocks without samples', () {
      final png = base64.encode(List<int>.filled(1200, 7));
      final sanitized = LLMRequestDumper.sanitizePayloadForTesting({
        'uri': 'data:image/png;base64,$png',
        'malformed_uri': 'data:image/png;base64,not base64!',
        'malformed': {
          'type': 'image',
          'dataBase64': 'not base64!',
          'mimeType': 'image/png',
        },
        'raw': png,
      });

      expect(
        sanitized['uri'],
        '[image payload redacted: mime=image/png, bytes=1200]',
      );
      expect(
        sanitized['malformed_uri'],
        '[image payload redacted: mime=image/png, bytes=unknown]',
      );
      expect(sanitized['malformed'], {
        'type': 'image_redacted',
        'mime_type': 'image/png',
        'decoded_bytes': null,
      });
      expect(
        sanitized['raw'],
        '[binary payload redacted: mime=unknown, bytes=1200]',
      );
      expect(jsonEncode(sanitized), isNot(contains(png.substring(0, 30))));
    });

    test('sanitization deep-copies and does not mutate the live request', () {
      final png = base64.encode(const [9, 8, 7]);
      final live = {
        'messages': [
          {
            'content': [
              {'type': 'image', 'dataBase64': png, 'mimeType': 'image/png'},
            ],
          },
        ],
      };
      final before = jsonEncode(live);

      final sanitized = LLMRequestDumper.sanitizePayloadForTesting(live);

      expect(jsonEncode(live), before);
      expect(jsonEncode(sanitized), isNot(contains(png)));
      expect(identical(sanitized, live), isFalse);
    });
  });

  group('native Ollama images array sanitization', () {
    final shortPngBytes = const [
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0x00,
      0x00,
      0x00,
      0x0D,
      0x49,
      0x48,
      0x44,
      0x52,
      0x00,
      0x00,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x01,
      0x08,
      0x06,
      0x00,
      0x00,
      0x00,
      0x1F,
      0x15,
      0xC4,
      0x89,
    ];
    final shortPngBase64 = base64.encode(shortPngBytes);

    final shortJpegBytes = const [
      0xFF,
      0xD8,
      0xFF,
      0xE0,
      0x00,
      0x10,
      0x4A,
      0x46,
      0x49,
      0x46,
      0x00,
      0x01,
      0x01,
      0x00,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x00,
      0xFF,
      0xDB,
      0x00,
      0x43,
      0x00,
      0xFF,
      0xD9,
    ];
    final shortJpegBase64 = base64.encode(shortJpegBytes);

    final shortGifBytes = const [
      0x47,
      0x49,
      0x46,
      0x38,
      0x39,
      0x61,
      0x01,
      0x00,
      0x01,
      0x00,
      0x80,
      0x00,
      0x00,
    ];
    final shortGifBase64 = base64.encode(shortGifBytes);

    final shortWebpBytes = const [
      0x52,
      0x49,
      0x46,
      0x46,
      0x0C,
      0x00,
      0x00,
      0x00,
      0x57,
      0x45,
      0x42,
      0x50,
      0x56,
      0x50,
      0x38,
      0x20,
    ];
    final shortWebpBase64 = base64.encode(shortWebpBytes);

    final largeJpegBytes = [0xFF, 0xD8, 0xFF, ...List<int>.filled(1197, 0x55)];
    final largeJpegBase64 = base64.encode(largeJpegBytes);

    test(
      'sanitizes direct user message with short native base64 images without size limit',
      () {
        expect(shortPngBase64.length, lessThan(1000));
        expect(shortJpegBase64.length, lessThan(1000));
        expect(shortGifBase64.length, lessThan(1000));
        expect(shortWebpBase64.length, lessThan(1000));

        final directPayload = {
          'request': {
            'body': {
              'model': 'llama3.2-vision',
              'messages': [
                {
                  'role': 'user',
                  'content': 'Here are several small images',
                  'images': [
                    shortPngBase64,
                    shortJpegBase64,
                    shortGifBase64,
                    shortWebpBase64,
                  ],
                },
              ],
            },
          },
        };

        final sanitized = LLMRequestDumper.sanitizePayloadForTesting(
          directPayload,
        );
        final messages = sanitized['request']['body']['messages'] as List;
        final images = (messages.first as Map)['images'] as List;

        expect(images, hasLength(4));
        expect(images[0], {
          'type': 'image_redacted',
          'mime_type': 'image/png',
          'decoded_bytes': shortPngBytes.length,
        });
        expect(images[1], {
          'type': 'image_redacted',
          'mime_type': 'image/jpeg',
          'decoded_bytes': shortJpegBytes.length,
        });
        expect(images[2], {
          'type': 'image_redacted',
          'mime_type': 'image/gif',
          'decoded_bytes': shortGifBytes.length,
        });
        expect(images[3], {
          'type': 'image_redacted',
          'mime_type': 'image/webp',
          'decoded_bytes': shortWebpBytes.length,
        });

        final serialized = jsonEncode(sanitized);
        expect(serialized, isNot(contains(shortPngBase64)));
        expect(serialized, isNot(contains(shortJpegBase64)));
        expect(serialized, isNot(contains(shortGifBase64)));
        expect(serialized, isNot(contains(shortWebpBase64)));
      },
    );

    test(
      'sanitizes detached tool result image request shape with mixed short and large base64',
      () {
        expect(largeJpegBase64.length, greaterThan(1000));

        final detachedPayload = {
          'request': {
            'body': {
              'model': 'llama3.2-vision',
              'messages': [
                {'role': 'user', 'content': 'Please view the image'},
                {
                  'role': 'assistant',
                  'tool_calls': [
                    {
                      'id': 'call-img-1',
                      'type': 'function',
                      'function': {'name': 'view_image', 'arguments': '{}'},
                    },
                  ],
                },
                {
                  'role': 'tool',
                  'tool_call_id': 'call-img-1',
                  'content': 'Image loaded from workspace',
                },
                {
                  'role': 'user',
                  'content':
                      'Image context from preceding tool result 1: tool call call-img-1 (view_image)',
                  'images': [shortPngBase64, largeJpegBase64],
                },
              ],
            },
          },
        };

        final sanitized = LLMRequestDumper.sanitizePayloadForTesting(
          detachedPayload,
        );
        final messages = sanitized['request']['body']['messages'] as List;
        final detachedMsg = messages[3] as Map;
        final images = detachedMsg['images'] as List;

        expect(images, hasLength(2));
        expect(images[0], {
          'type': 'image_redacted',
          'mime_type': 'image/png',
          'decoded_bytes': shortPngBytes.length,
        });
        expect(images[1], {
          'type': 'image_redacted',
          'mime_type': 'image/jpeg',
          'decoded_bytes': 1200,
        });

        final serialized = jsonEncode(sanitized);
        expect(serialized, isNot(contains(shortPngBase64)));
        expect(serialized, isNot(contains(largeJpegBase64.substring(0, 30))));
      },
    );

    test(
      'handles data URIs, malformed strings, non-images, and non-strings safely in images array',
      () {
        final validDataUri = 'data:image/png;base64,$shortPngBase64';
        final malformedDataUri = 'data:image/png;base64,not-base64!';
        final malformedRaw = 'not-valid-base64-content!';
        final textBase64 = base64.encode(utf8.encode('plain text content'));

        final payload = {
          'images': [
            validDataUri,
            malformedDataUri,
            malformedRaw,
            textBase64,
            12345,
            null,
          ],
        };

        final sanitized = LLMRequestDumper.sanitizePayloadForTesting(payload);
        final images = (sanitized['images'] as List)
            .cast<Map<String, dynamic>>();

        expect(images, hasLength(6));
        expect(images[0], {
          'type': 'image_redacted',
          'mime_type': 'image/png',
          'decoded_bytes': shortPngBytes.length,
        });
        expect(images[1], {
          'type': 'image_redacted',
          'mime_type': 'image/png',
          'decoded_bytes': null,
        });
        expect(images[2], {
          'type': 'image_redacted',
          'mime_type': 'unknown',
          'decoded_bytes': null,
        });
        expect(images[3], {
          'type': 'image_redacted',
          'mime_type': 'unknown',
          'decoded_bytes': 18,
        });
        expect(images[4], {
          'type': 'image_redacted',
          'mime_type': 'unknown',
          'decoded_bytes': null,
        });
        expect(images[5], {
          'type': 'image_redacted',
          'mime_type': 'unknown',
          'decoded_bytes': null,
        });

        final serialized = jsonEncode(sanitized);
        expect(serialized, isNot(contains('not-base64')));
        expect(serialized, isNot(contains('not-valid')));
        expect(serialized, isNot(contains('plain text content')));
      },
    );

    test(
      'deep copies and guarantees source immutability for native Ollama image payloads',
      () {
        final payload = {
          'request': {
            'body': {
              'model': 'llama3.2-vision',
              'messages': [
                {
                  'role': 'user',
                  'content': 'Test immutability',
                  'images': [shortPngBase64],
                },
              ],
            },
          },
        };

        final beforeJson = jsonEncode(payload);
        final sanitized = LLMRequestDumper.sanitizePayloadForTesting(payload);

        expect(identical(sanitized, payload), isFalse);
        expect(jsonEncode(payload), equals(beforeJson));
        expect(
          ((payload['request'] as Map)['body']
              as Map)['messages'][0]['images'][0],
          equals(shortPngBase64),
        );
      },
    );

    test(
      'recordActualRequest writes sanitized native image metadata to dump file on disk',
      () async {
        LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'true'};

        final path = await LLMRequestDumper.dumpRequest(
          sessionId: 'test-native-ollama-dump',
          history: const [],
          tools: const [],
          model: 'llama3.2-vision',
          provider: 'ollama',
        );

        expect(path, isNotNull);

        final body = {
          'model': 'llama3.2-vision',
          'messages': [
            {
              'role': 'user',
              'content': 'Detached tool result context',
              'images': [shortPngBase64, largeJpegBase64],
            },
          ],
        };

        await LLMRequestDumper.recordActualRequest(
          url: Uri.parse('http://127.0.0.1:11434/api/chat'),
          headers: {'Content-Type': 'application/json'},
          body: body,
        );

        final dumpFile = File(path!);
        expect(dumpFile.existsSync(), isTrue);

        final content = await dumpFile.readAsString();
        final decoded = jsonDecode(content) as Map<String, dynamic>;
        final reqBody = decoded['request']['body'] as Map<String, dynamic>;
        final messages = (reqBody['messages'] as List)
            .cast<Map<String, dynamic>>();
        final images = (messages.first['images'] as List)
            .cast<Map<String, dynamic>>();

        expect(images, hasLength(2));
        expect(images[0], {
          'type': 'image_redacted',
          'mime_type': 'image/png',
          'decoded_bytes': shortPngBytes.length,
        });
        expect(images[1], {
          'type': 'image_redacted',
          'mime_type': 'image/jpeg',
          'decoded_bytes': 1200,
        });

        expect(content, isNot(contains(shortPngBase64)));
        expect(content, isNot(contains(largeJpegBase64.substring(0, 30))));
      },
    );
  });

  group('Compaction Request Dumper Pairing and Isolation', () {
    test('hasActiveDump tracks in-flight mappings and cleanupActiveDump clears them', () async {
      LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'true'};

      const compactionId = 'active-test-c1';
      const requestId = 'compaction:active-test-c1:req-1';

      expect(LLMRequestDumper.hasActiveDump(compactionId: compactionId, requestId: requestId), isFalse);

      final path = await LLMRequestDumper.dumpRequest(
        compactionId: compactionId,
        requestId: requestId,
        sessionId: 'test-session',
        history: [],
        tools: const [],
      );
      expect(path, isNotNull);
      expect(LLMRequestDumper.hasActiveDump(compactionId: compactionId, requestId: requestId), isTrue);

      LLMRequestDumper.cleanupActiveDump(compactionId: compactionId, requestId: requestId);
      expect(LLMRequestDumper.hasActiveDump(compactionId: compactionId, requestId: requestId), isFalse);
    });

    test(
      'compactionKey normalizes and canonicalizes compaction and request identifiers',
      () {
        expect(
          LLMRequestDumper.compactionKey(
            compactionId: 'op-1',
            requestId: 'req-1',
          ),
          equals('compaction:op-1:req-1'),
        );
        expect(
          LLMRequestDumper.compactionKey(
            compactionId: 'op-1',
            requestId: 'compaction:op-1:req-1',
          ),
          equals('compaction:op-1:req-1'),
        );
        expect(
          LLMRequestDumper.compactionKey(
            requestId: 'compaction:auto-1:attempt-1',
          ),
          equals('compaction:auto-1:attempt-1'),
        );
        expect(
          LLMRequestDumper.compactionKey(compactionId: 'op-1'),
          equals('compaction:op-1'),
        );
        expect(
          LLMRequestDumper.extractCompactionId('compaction:op-1:attempt-1'),
          equals('op-1'),
        );
      },
    );

    test(
      'pairs compaction request, actual request, and response under compactionId:requestId without touching lastDumpFilePath',
      () async {
        LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'true'};

        const compactionId = 'test-compaction-uuid-1';
        const requestId = 'compaction:test-compaction-uuid-1:attempt-1';

        final dumpPath = await LLMRequestDumper.dumpRequest(
          compactionId: compactionId,
          requestId: requestId,
          sessionId: 'session-compaction-test',
          history: [
            Message(role: MessageRole.user, content: 'Summarize previous turns'),
          ],
          tools: const [],
          model: 'summary-model',
          provider: 'openai',
        );

        expect(dumpPath, isNotNull);
        expect(dumpPath, contains('compaction_dump_'));
        // Invariant: Compaction requests NEVER set or overwrite lastDumpFilePath
        expect(LLMRequestDumper.lastDumpFilePath, isNull);

        final initialFile = File(dumpPath!);
        expect(initialFile.existsSync(), isTrue);
        var content =
            jsonDecode(await initialFile.readAsString()) as Map<String, dynamic>;
        expect(content['capture_state'], equals('initialized'));
        expect(content['compaction_id'], equals(compactionId));
        expect(content['request_id'], equals(requestId));

        // Record wire request via adapter hook
        final actualRecorded = await LLMRequestDumper.recordActualRequest(
          url: Uri.parse('https://api.openai.com/v1/chat/completions'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer test-secret-token',
          },
          body: {
            'model': 'summary-model',
            'messages': [
              {'role': 'user', 'content': 'Summarize'},
            ],
          },
          compactionId: compactionId,
          requestId: requestId,
        );
        expect(actualRecorded, equals(dumpPath));
        expect(LLMRequestDumper.lastDumpFilePath, isNull);

        content =
            jsonDecode(await initialFile.readAsString()) as Map<String, dynamic>;
        expect(content['capture_state'], equals('request_sent'));
        expect(
          content['request']['url'],
          equals('https://api.openai.com/v1/chat/completions'),
        );

        // Complete response via adapter hook
        final responseRecorded = await LLMRequestDumper.dumpResponse(
          {
            'status_code': 200,
            'summary': 'This is the compressed summary.',
          },
          requestId: requestId,
        );
        expect(responseRecorded, equals(dumpPath));
        expect(LLMRequestDumper.lastDumpFilePath, isNull);

        content =
            jsonDecode(await initialFile.readAsString()) as Map<String, dynamic>;
        expect(content['capture_state'], equals('completed'));
        expect(
          content['response']['summary'],
          equals('This is the compressed summary.'),
        );

        // Proves in-flight map is cleanly removed on completion
        expect(
          LLMRequestDumper.hasActiveDump(
            compactionId: compactionId,
            requestId: requestId,
          ),
          isFalse,
        );
      },
    );

    test(
      'pairs compaction error and marks capture_state as error without touching lastDumpFilePath',
      () async {
        LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'true'};

        const compactionId = 'test-compaction-uuid-err';
        const requestId = 'compaction:test-compaction-uuid-err:attempt-1';

        final dumpPath = await LLMRequestDumper.dumpRequest(
          compactionId: compactionId,
          requestId: requestId,
          sessionId: 'session-err',
          history: [],
          tools: const [],
        );
        expect(dumpPath, isNotNull);
        expect(LLMRequestDumper.lastDumpFilePath, isNull);
        expect(LLMRequestDumper.hasActiveDump(compactionId: compactionId, requestId: requestId), isTrue);

        final recordedError = await LLMRequestDumper.recordError(
          HttpException(
            'Compaction endpoint unreachable with secret sk-proj-12345678901234567890',
          ),
          requestId: requestId,
          compactionId: compactionId,
        );
        expect(recordedError, equals(dumpPath));
        expect(LLMRequestDumper.lastDumpFilePath, isNull);
        expect(LLMRequestDumper.hasActiveDump(compactionId: compactionId, requestId: requestId), isFalse);

        final content =
            jsonDecode(await File(dumpPath!).readAsString()) as Map<String, dynamic>;
        expect(content['capture_state'], equals('error'));
        expect(content['error']['type'], equals('HttpException'));
        expect(content['error']['message'], contains('unreachable'));
        expect(
          content['error']['message'],
          isNot(contains('12345678901234567890')),
        );
      },
    );

    test(
      'normal-turn and compaction requests concurrently execute with strict lastDumpFilePath isolation',
      () async {
        LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'true'};

        // 1. Normal turn begins
        final normalPath = await LLMRequestDumper.dumpRequest(
          sessionId: 'normal-session-1',
          history: [
            Message(role: MessageRole.user, content: 'Normal user turn message'),
          ],
          tools: const [],
          requestId: 'normal-req-1',
        );
        expect(normalPath, isNotNull);
        expect(LLMRequestDumper.lastDumpFilePath, equals(normalPath));

        // 2. Compaction request begins in background / preflight
        const compactionId = 'compaction-op-concurrent';
        const compactionRequestId =
            'compaction:compaction-op-concurrent:attempt-1';
        final compactionPath = await LLMRequestDumper.dumpRequest(
          compactionId: compactionId,
          requestId: compactionRequestId,
          sessionId: 'normal-session-1',
          history: [
            Message(role: MessageRole.system, content: 'Summarize context'),
          ],
          tools: const [],
        );
        expect(compactionPath, isNotNull);
        expect(compactionPath, isNot(equals(normalPath)));
        // Invariant: lastDumpFilePath MUST NOT be overwritten by compaction
        expect(LLMRequestDumper.lastDumpFilePath, equals(normalPath));

        // 3. Compaction records actual request
        await LLMRequestDumper.recordActualRequest(
          url: Uri.parse('https://api.openai.com/v1/chat/completions'),
          headers: {'Content-Type': 'application/json'},
          body: {'summary_prompt': 'compress context payload'},
          requestId: compactionRequestId,
        );
        expect(LLMRequestDumper.lastDumpFilePath, equals(normalPath));

        // 4. Normal turn records actual request
        await LLMRequestDumper.recordActualRequest(
          url: Uri.parse('https://api.openai.com/v1/chat/completions'),
          headers: {'Content-Type': 'application/json'},
          body: {'user_prompt': 'Normal user turn message'},
          requestId: 'normal-req-1',
        );
        expect(LLMRequestDumper.lastDumpFilePath, equals(normalPath));

        // 5. Compaction finishes first and dumps response
        await LLMRequestDumper.dumpResponse(
          {'summary_output': 'Compact state achieved'},
          requestId: compactionRequestId,
        );
        expect(LLMRequestDumper.lastDumpFilePath, equals(normalPath));

        // 6. Normal turn dumps response
        await LLMRequestDumper.dumpResponse(
          {'reply': 'Normal assistant answer'},
          requestId: 'normal-req-1',
        );
        expect(LLMRequestDumper.lastDumpFilePath, equals(normalPath));

        // Verify normal file content: contains normal turn, NEVER contains compaction data
        final normalContent = await File(normalPath!).readAsString();
        expect(normalContent, contains('Normal user turn message'));
        expect(normalContent, contains('Normal assistant answer'));
        expect(normalContent, isNot(contains('compress context payload')));
        expect(normalContent, isNot(contains('Compact state achieved')));

        // Verify compaction file content: contains compaction turn, NEVER contains normal data
        final compactionContent = await File(compactionPath!).readAsString();
        expect(compactionContent, contains('compress context payload'));
        expect(compactionContent, contains('Compact state achieved'));
        expect(compactionContent, isNot(contains('Normal assistant answer')));
        expect(compactionContent, isNot(contains('Normal user turn message')));
      },
    );

    test(
      'auto-creates compaction dump file on wire recordActualRequest without preceding dumpRequest',
      () async {
        LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'true'};

        const requestId = 'compaction:raw-adapter-uuid:attempt-1';
        final actualDump = await LLMRequestDumper.recordActualRequest(
          url: Uri.parse('https://api.openai.com/v1/chat/completions'),
          headers: {'Content-Type': 'application/json'},
          body: {
            'messages': [
              {'role': 'user', 'content': 'Wire compaction test'},
            ],
          },
          requestId: requestId,
        );

        expect(actualDump, isNotNull);
        expect(actualDump, contains('compaction_dump_'));
        expect(LLMRequestDumper.lastDumpFilePath, isNull);

        final initial =
            jsonDecode(await File(actualDump!).readAsString())
                as Map<String, dynamic>;
        expect(initial['capture_state'], equals('request_sent'));
        expect(initial['compaction_id'], equals('raw-adapter-uuid'));
        expect(initial['request_id'], equals(requestId));

        // Completing response attaches to the auto-created dump
        final responseRecorded = await LLMRequestDumper.dumpResponse(
          {'output': 'wire completion ok'},
          requestId: requestId,
        );
        expect(responseRecorded, equals(actualDump));
        expect(LLMRequestDumper.lastDumpFilePath, isNull);

        final completed =
            jsonDecode(await File(actualDump).readAsString())
                as Map<String, dynamic>;
        expect(completed['capture_state'], equals('completed'));
        expect(completed['response']['output'], equals('wire completion ok'));
      },
    );

    test(
      'isolates distinct compaction attempts under the same compactionId',
      () async {
        LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'true'};

        const compactionId = 'multi-attempt-op';
        const req1 = 'compaction:multi-attempt-op:attempt-1';
        const req2 = 'compaction:multi-attempt-op:attempt-2';

        // Attempt 1 fails
        final dump1 = await LLMRequestDumper.dumpRequest(
          compactionId: compactionId,
          requestId: req1,
          sessionId: 'session-multi',
          history: [],
          tools: const [],
        );
        expect(LLMRequestDumper.hasActiveDump(compactionId: compactionId, requestId: req1), isTrue);

        await LLMRequestDumper.recordError(
          HttpException('Attempt 1 timeout'),
          requestId: req1,
          compactionId: compactionId,
        );
        expect(LLMRequestDumper.hasActiveDump(compactionId: compactionId, requestId: req1), isFalse);

        // Attempt 2 succeeds
        final dump2 = await LLMRequestDumper.dumpRequest(
          compactionId: compactionId,
          requestId: req2,
          sessionId: 'session-multi',
          history: [],
          tools: const [],
        );
        expect(LLMRequestDumper.hasActiveDump(compactionId: compactionId, requestId: req2), isTrue);

        await LLMRequestDumper.dumpResponse(
          {'success': true},
          requestId: req2,
          compactionId: compactionId,
        );
        expect(LLMRequestDumper.hasActiveDump(compactionId: compactionId, requestId: req2), isFalse);

        expect(dump1, isNot(equals(dump2)));
        final content1 =
            jsonDecode(await File(dump1!).readAsString())
                as Map<String, dynamic>;
        final content2 =
            jsonDecode(await File(dump2!).readAsString())
                as Map<String, dynamic>;

        expect(content1['capture_state'], equals('error'));
        expect(content1['request_id'], equals(req1));
        expect(content2['capture_state'], equals('completed'));
        expect(content2['request_id'], equals(req2));
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
