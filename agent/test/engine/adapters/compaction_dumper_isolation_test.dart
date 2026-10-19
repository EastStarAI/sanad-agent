/// Task 106 G10 (Wave D) — auxiliary compaction requests must never write into
/// an unrelated LLM request dump, proven through the real production adapters.
///
/// `LLMRequestDumper` unit coverage lives in `test/engine/llm_request_dumper_test.dart`.
/// This suite locks the adapter call sites that forward
/// `LLMRequestOptions.requestId` into `recordActualRequest`/`dumpResponse`: if an
/// adapter stops forwarding the request id, an auxiliary compaction exchange can
/// append its request body/response payload into the previous turn's dump file
/// (or re-introduce the unpaired-response warning) without any test noticing.
///
/// The compaction options are derived through the real
/// `CompactionRequestFactory`, so the `compaction:` request-id shape under test is
/// the production one. Fixture HTTP carriers only — no network egress, no vendor
/// acceptance claim, and a temporary Sanad Home.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/engine/adapters/base_anthropic_adapter.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/codex_responses_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:sanad_agent/engine/llm_request_dumper.dart';
import 'package:sanad_agent/engine/runtime/compaction_request_factory.dart';
import 'package:test/test.dart';

const _previousTurnMarker = 'previous turn request body';
const _compactionInstruction = 'compact now';
const _completionMarker = 'adapter-dump-summary-marker';

const _anthropicProfile = ProviderProfile(
  name: 'custom',
  displayName: 'Custom Anthropic',
  description: 'Custom Anthropic provider',
  defaultBaseUrl: 'https://dump.invalid/v1',
  authType: 'api_key',
  apiMode: 'anthropic_messages',
  protocol: ProviderProtocol.anthropicCompatible,
  apiKeyRequirement: ApiKeyRequirement.optional,
  authMethods: [ProviderAuthMethod.apiKey],
);

const _codexProfile = ProviderProfile(
  name: 'openai-codex',
  defaultBaseUrl: 'https://dump.invalid/v1',
  fallbackModels: ['gpt-5.4'],
  apiMode: 'codex_responses',
);

/// One terminal `response.completed` SSE event for the mocked codex wire.
String _codexCompletedSse() => 'data: ${jsonEncode({
  'type': 'response.completed',
  'response': {
    'id': 'resp_dump_1',
    'status': 'completed',
    'model': 'gpt-5.4',
    'output': [
      {
        'type': 'message',
        'role': 'assistant',
        'status': 'completed',
        'content': [
          {'type': 'output_text', 'text': _completionMarker},
        ],
      },
    ],
    'usage': {'input_tokens': 10, 'output_tokens': 7, 'total_tokens': 17},
  },
})}\n\n';

void main() {
  late Directory scratch;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('sanad-106-adapter-dump-');
    setSanadHomeOverride(scratch.path);
    LLMRequestDumper.environmentOverride = {'DUMP_REQUESTS': 'true'};
    LLMRequestDumper.lastDumpFilePath = null;
  });

  tearDown(() {
    setSanadHomeOverride(null);
    LLMRequestDumper.environmentOverride = null;
    LLMRequestDumper.lastDumpFilePath = null;
    if (scratch.existsSync()) {
      scratch.deleteSync(recursive: true);
    }
  });

  Config config() => Config(environment: {'SANAD_HOME': scratch.path});

  Config codexConfig() => Config(
    environment: {
      'SANAD_HOME': scratch.path,
      'ACTIVE_PROVIDER': 'openai-codex',
      'CHATGPT_SESSION_TOKEN': 'fixture-key',
      'LLM_API_KEY': 'fixture-key',
      'LLM_MODEL': 'gpt-5.4',
      'CHATGPT_MODEL': 'gpt-5.4',
      'LLM_BASE_URL': 'https://dump.invalid/v1',
    },
  );

  LLMRequestOptions compactionOptions({
    required String providerInstanceId,
    required String modelId,
  }) {
    final options = CompactionRequestFactory.buildCompactionRequestOptions(
      sessionId: 'dump-guard-session',
      compactionId: 'adapter-dump-uuid',
      routeSignature: RouteSignature(
        providerInstanceId: providerInstanceId,
        templateId: 'custom',
        protocol: 'openai_compatible',
        normalizedBaseUrl: 'https://dump.invalid/v1',
        modelId: modelId,
        configRevision: 1,
        credentialRevision: 1,
      ),
      baseOptions: LLMRequestOptions(
        sessionId: 'dump-guard-session',
        providerInstanceId: providerInstanceId,
      ),
      fallbackThinkingMode: 'high',
    );
    expect(
      options.requestId,
      startsWith('compaction:'),
      reason: 'the suite must dispatch the real auxiliary compaction shape',
    );
    return options;
  }

  /// Seeds one previous-turn dump file, records its exact bytes, runs
  /// [dispatch] with compaction-derived options, and proves the auxiliary
  /// exchange left both the file bytes and the operational log level untouched.
  Future<void> expectCompactionDispatchIsolated({
    required Future<void> Function(LLMRequestOptions options) dispatch,
    required String providerInstanceId,
    required String modelId,
  }) async {
    final turnPath = await LLMRequestDumper.dumpRequest(
      sessionId: 'dump-guard-session',
      history: [
        Message(role: MessageRole.user, content: _previousTurnMarker),
      ],
      tools: const [],
    );
    expect(
      turnPath,
      isNotNull,
      reason: 'a previous turn dump is required to detect corruption',
    );
    final before = await File(turnPath!).readAsString();

    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    addTearDown(() => Logger.root.level = previousLevel);
    final records = <LogRecord>[];
    final subscription = Logger('LLMRequestDumper').onRecord.listen(
      records.add,
    );
    addTearDown(subscription.cancel);

    await dispatch(
      compactionOptions(
        providerInstanceId: providerInstanceId,
        modelId: modelId,
      ),
    );

    final after = await File(turnPath).readAsString();
    expect(
      after,
      equals(before),
      reason:
          'an auxiliary compaction exchange must not modify the previous '
          'turn dump file',
    );
    expect(
      after,
      isNot(contains(_compactionInstruction)),
      reason: 'the compaction request body was written into the turn dump',
    );
    expect(
      after,
      isNot(contains(_completionMarker)),
      reason: 'the compaction response payload was written into the turn dump',
    );
    expect(
      records.where((record) => record.level >= Level.WARNING),
      isEmpty,
      reason: 'auxiliary compaction must not emit operational warnings',
    );
  }

  group('Auxiliary compaction requests stay out of request dumps', () {
    test(
      'openai-compatible adapter isolates the compaction exchange from the previous turn dump',
      () async {
        final adapter = BaseOpenAIAdapter(
          config(),
          const ProviderProfile(name: 'openai', apiMode: 'chat'),
          baseUrlOverride: 'https://dump.invalid/v1',
          apiKeyOverride: 'fixture-key',
          defaultModelOverride: 'dump-model',
          client: MockClient(
            (request) async => http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'role': 'assistant',
                      'content': _completionMarker,
                    },
                    'finish_reason': 'stop',
                  },
                ],
              }),
              200,
            ),
          ),
        );

        await expectCompactionDispatchIsolated(
          providerInstanceId: 'dump-openai-provider',
          modelId: 'dump-model',
          dispatch: (options) => adapter.generateResponse(
            [Message(role: MessageRole.user, content: _compactionInstruction)],
            options: options,
          ),
        );
      },
    );

    test(
      'anthropic-compatible adapter isolates the compaction exchange from the previous turn dump',
      () async {
        final adapter = BaseAnthropicAdapter(
          config(),
          _anthropicProfile,
          providerInstanceId: 'dump-anthropic-provider',
          baseUrlOverride: 'https://dump.invalid/v1',
          apiKeyOverride: 'fixture-key',
          client: MockClient(
            (request) async => http.Response(
              jsonEncode({
                'id': 'msg_dump_1',
                'type': 'message',
                'role': 'assistant',
                'content': [
                  {'type': 'text', 'text': _completionMarker},
                ],
                'model': 'dump-model',
                'stop_reason': 'end_turn',
                'usage': {'input_tokens': 5, 'output_tokens': 5},
              }),
              200,
            ),
          ),
        );

        await expectCompactionDispatchIsolated(
          providerInstanceId: 'dump-anthropic-provider',
          modelId: 'dump-model',
          dispatch: (options) => adapter.generateResponse(
            [Message(role: MessageRole.user, content: _compactionInstruction)],
            options: options,
          ),
        );
      },
    );

    test(
      'codex responses adapter isolates a successful compaction exchange from the previous turn dump',
      () async {
        final adapter = CodexResponsesAdapter(
          codexConfig(),
          _codexProfile,
          providerInstanceId: 'dump-codex-provider',
          baseUrlOverride: 'https://dump.invalid/v1',
          apiKeyOverride: 'fixture-key',
          client: MockClient.streaming(
            (request, _) async => http.StreamedResponse(
              Stream.value(utf8.encode(_codexCompletedSse())),
              200,
            ),
          ),
        );

        await expectCompactionDispatchIsolated(
          providerInstanceId: 'dump-codex-provider',
          modelId: 'gpt-5.4',
          dispatch: (options) => adapter.generateResponse(
            [Message(role: MessageRole.user, content: _compactionInstruction)],
            options: options,
          ),
        );
      },
    );

    test(
      'codex responses adapter isolates the failed compaction exchange from the previous turn dump',
      () async {
        final adapter = CodexResponsesAdapter(
          codexConfig(),
          _codexProfile,
          providerInstanceId: 'dump-codex-provider',
          baseUrlOverride: 'https://dump.invalid/v1',
          apiKeyOverride: 'fixture-key',
          client: MockClient.streaming(
            (request, _) async => http.StreamedResponse(
              Stream.value(utf8.encode('{"error":"denied"}')),
              400,
            ),
          ),
        );

        // Both codex `generateResponse` dumper call sites (request and failed
        // response) must be exercised; the request is rejected before download.
        Object? thrown;
        await expectCompactionDispatchIsolated(
          providerInstanceId: 'dump-codex-provider',
          modelId: 'gpt-5.4',
          dispatch: (options) async {
            try {
              await adapter.generateResponse(
                [
                  Message(
                    role: MessageRole.user,
                    content: _compactionInstruction,
                  ),
                ],
                options: options,
              );
            } catch (error) {
              thrown = error;
            }
          },
        );
        expect(thrown, isNotNull, reason: 'the fixture dispatch must fail');
      },
    );
  });

  group('Streaming subscription cancellation active-map cleanup', () {
    test(
      'openai-compatible streaming subscription cancellation cleans up active dump without active-map leak',
      () async {
        final controller = StreamController<List<int>>();
        final adapter = BaseOpenAIAdapter(
          config(),
          const ProviderProfile(name: 'openai', apiMode: 'chat'),
          baseUrlOverride: 'https://dump.invalid/v1',
          apiKeyOverride: 'fixture-key',
          defaultModelOverride: 'dump-model',
          client: MockClient.streaming(
            (request, _) async => http.StreamedResponse(controller.stream, 200),
          ),
        );

        final options = compactionOptions(
          providerInstanceId: 'dump-openai-provider',
          modelId: 'dump-model',
        );

        controller.add(
          utf8.encode('data: {"choices":[{"delta":{"content":"first chunk"}}]}\n\n'),
        );

        final stream = adapter.generateStream(
          [Message(role: MessageRole.user, content: _compactionInstruction)],
          options: options,
        );

        final completer = Completer<void>();
        late StreamSubscription<AgentResponse> sub;
        sub = stream.listen((chunk) async {
          expect(
            LLMRequestDumper.hasActiveDump(requestId: options.requestId),
            isTrue,
            reason: 'in-flight dump mapping must exist during active streaming',
          );
          await sub.cancel();
          await controller.close();
          completer.complete();
        });

        await completer.future;

        expect(
          LLMRequestDumper.hasActiveDump(requestId: options.requestId),
          isFalse,
          reason: 'subscription cancellation must clean up the active dump mapping',
        );
        expect(LLMRequestDumper.lastDumpFilePath, isNull);
      },
    );

    test(
      'anthropic-compatible streaming subscription cancellation cleans up active dump without active-map leak',
      () async {
        final controller = StreamController<List<int>>();
        final adapter = BaseAnthropicAdapter(
          config(),
          _anthropicProfile,
          providerInstanceId: 'dump-anthropic-provider',
          baseUrlOverride: 'https://dump.invalid/v1',
          apiKeyOverride: 'fixture-key',
          client: MockClient.streaming(
            (request, _) async => http.StreamedResponse(controller.stream, 200),
          ),
        );

        final options = compactionOptions(
          providerInstanceId: 'dump-anthropic-provider',
          modelId: 'dump-model',
        );

        controller.add(
          utf8.encode(
            'event: content_block_delta\n'
            'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"chunk"}}\n\n',
          ),
        );

        final stream = adapter.generateStream(
          [Message(role: MessageRole.user, content: _compactionInstruction)],
          options: options,
        );

        final completer = Completer<void>();
        late StreamSubscription<AgentResponse> sub;
        sub = stream.listen((chunk) async {
          expect(
            LLMRequestDumper.hasActiveDump(requestId: options.requestId),
            isTrue,
            reason: 'in-flight dump mapping must exist during active streaming',
          );
          await sub.cancel();
          await controller.close();
          completer.complete();
        });

        await completer.future;

        expect(
          LLMRequestDumper.hasActiveDump(requestId: options.requestId),
          isFalse,
          reason: 'subscription cancellation must clean up the active dump mapping',
        );
        expect(LLMRequestDumper.lastDumpFilePath, isNull);
      },
    );

    test(
      'codex responses streaming subscription cancellation cleans up active dump without active-map leak',
      () async {
        final controller = StreamController<List<int>>();
        final adapter = CodexResponsesAdapter(
          codexConfig(),
          _codexProfile,
          providerInstanceId: 'dump-codex-provider',
          baseUrlOverride: 'https://dump.invalid/v1',
          apiKeyOverride: 'fixture-key',
          client: MockClient.streaming(
            (request, _) async => http.StreamedResponse(controller.stream, 200),
          ),
        );

        final options = compactionOptions(
          providerInstanceId: 'dump-codex-provider',
          modelId: 'gpt-5.4',
        );

        controller.add(
          utf8.encode(
            'data: {"type":"response.output_text.delta","delta":"codex chunk"}\n\n',
          ),
        );

        final stream = adapter.generateStream(
          [Message(role: MessageRole.user, content: _compactionInstruction)],
          options: options,
        );

        final completer = Completer<void>();
        late StreamSubscription<AgentResponse> sub;
        sub = stream.listen((chunk) async {
          expect(
            LLMRequestDumper.hasActiveDump(requestId: options.requestId),
            isTrue,
            reason: 'in-flight dump mapping must exist during active streaming',
          );
          await sub.cancel();
          await controller.close();
          completer.complete();
        });

        await completer.future;

        expect(
          LLMRequestDumper.hasActiveDump(requestId: options.requestId),
          isFalse,
          reason: 'subscription cancellation must clean up the active dump mapping',
        );
        expect(LLMRequestDumper.lastDumpFilePath, isNull);
      },
    );

    test(
      'streaming completion preserves capture_state completed and cleans up active dump',
      () async {
        final adapter = BaseOpenAIAdapter(
          config(),
          const ProviderProfile(name: 'openai', apiMode: 'chat'),
          baseUrlOverride: 'https://dump.invalid/v1',
          apiKeyOverride: 'fixture-key',
          defaultModelOverride: 'dump-model',
          client: MockClient.streaming(
            (request, _) async => http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  'data: {"choices":[{"delta":{"content":"full summary"},"finish_reason":"stop"}]}\n\n'
                  'data: [DONE]\n\n',
                ),
              ),
              200,
            ),
          ),
        );

        final options = compactionOptions(
          providerInstanceId: 'dump-openai-provider',
          modelId: 'dump-model',
        );

        final responses = await adapter.generateStream(
          [Message(role: MessageRole.user, content: _compactionInstruction)],
          options: options,
        ).toList();

        expect(responses, isNotEmpty);
        expect(
          LLMRequestDumper.hasActiveDump(requestId: options.requestId),
          isFalse,
          reason: 'completed stream must have cleaned up the active dump mapping',
        );
        expect(LLMRequestDumper.lastDumpFilePath, isNull);

        // Verify dump file written to disk has capture_state: 'completed'
        final dumpDir = Directory(p.join(scratch.path, 'request_dumps'));
        final dumpFiles = dumpDir.listSync().whereType<File>().toList();
        expect(dumpFiles, isNotEmpty);
        final dumpContent =
            jsonDecode(await dumpFiles.first.readAsString()) as Map<String, dynamic>;
        expect(dumpContent['capture_state'], equals('completed'));
        expect(
          dumpContent['response']['message']['content'],
          equals('full summary'),
        );
      },
    );
  });
}
