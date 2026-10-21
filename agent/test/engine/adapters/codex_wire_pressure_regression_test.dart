/// Task 106 G11 — repeat-compaction pressure regression at the real Codex wire
/// measurement and pressure boundary.
///
/// Live defect: `CodexResponsesAdapter.measureInput` priced
/// `jsonEncode(instructions/input/tools).length / 4`, so opaque Codex reasoning
/// replay (`encrypted_content`) and encoded image transport were priced as
/// ordinary text. The observed `505982` prospective measurement against roughly
/// `185000` model-visible tokens repeatedly tripped the automatic compaction
/// threshold and blocked the conversation.
///
/// These tests pin the corrected pricing, the confirmed-baseline mixing math,
/// and the fact that genuine model-visible growth still crosses the threshold.
///
/// The authoritative scenario numbers come from the principal read-only DB
/// receipts (`principal-pressure-db-receipt.json`,
/// `principal-previous-pressure-db-receipt.json`), not from the earlier
/// approximate `185000` observation: the latest requester case had a
/// `136213` confirmed input, then a `1472888`-character image carrier with
/// observed `1203x1321` dimensions; the previous case crossed providers with
/// `863592` characters of opaque replay and a `59984`-character image carrier.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/engine/adapters/codex_responses_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:sanad_agent/engine/compaction/compaction_enums.dart';
import 'package:sanad_agent/engine/context/request_pressure_evaluator.dart';
import 'package:sanad_agent/engine/context/request_pressure_snapshot.dart';
import 'package:test/test.dart';

/// Production-codex window from the live regression (258000 with 0.9).
const _contextWindow = 258_000;
const _thresholdRatio = 0.9;

/// `(258000 - 4096 - 1024) * 0.9` — the live automatic compaction threshold.
const _expectedThresholdTokens = 227_592;

const _fixtureProviderInstanceId = 'g11-codex-fixture';

RouteSignature _route() => const RouteSignature(
  providerInstanceId: _fixtureProviderInstanceId,
  templateId: 'openai-codex',
  protocol: 'openai_codex_responses',
  normalizedBaseUrl: 'https://g11.invalid/v1',
  modelId: 'gpt-5.4',
  configRevision: 1,
  credentialRevision: 1,
);

String _sseCompleted({
  required String reasoningId,
  required String encryptedContent,
  required String visibleText,
}) {
  return 'data: ${jsonEncode({
    'type': 'response.completed',
    'response': {
      'id': 'resp_$reasoningId',
      'status': 'completed',
      'model': 'gpt-5.4',
      'output': [
        {
          'id': reasoningId,
          'type': 'reasoning',
          'encrypted_content': encryptedContent,
          'summary': [
            {'type': 'summary_text', 'text': 'brief summary'},
          ],
        },
        {
          'id': 'msg_$reasoningId',
          'type': 'message',
          'role': 'assistant',
          'status': 'completed',
          'phase': 'final_answer',
          'content': [
            {'type': 'output_text', 'text': visibleText},
          ],
        },
      ],
      'usage': {'input_tokens': 10, 'output_tokens': 7, 'total_tokens': 17},
    },
  })}\n\n';
}

CodexResponsesAdapter _adapter({
  required String reasoningId,
  required String encryptedContent,
  String visibleText = 'visible answer',
}) {
  final config = Config(
    environment: {
      'ACTIVE_PROVIDER': 'openai-codex',
      'CHATGPT_SESSION_TOKEN': 'g11-fixture-key',
      'LLM_API_KEY': 'g11-fixture-key',
      'LLM_MODEL': 'gpt-5.4',
      'CHATGPT_MODEL': 'gpt-5.4',
      'LLM_BASE_URL': 'https://g11.invalid/v1',
    },
  );
  const profile = ProviderProfile(
    name: 'openai-codex',
    defaultBaseUrl: 'https://g11.invalid/v1',
    fallbackModels: ['gpt-5.4'],
    apiMode: 'codex_responses',
  );
  return CodexResponsesAdapter(
    config,
    profile,
    client: MockClient.streaming(
      (request, _) async => http.StreamedResponse(
        Stream.value(
          utf8.encode(
            _sseCompleted(
              reasoningId: reasoningId,
              encryptedContent: encryptedContent,
              visibleText: visibleText,
            ),
          ),
        ),
        200,
      ),
    ),
  );
}

const _measureOptions = LLMRequestOptions(
  providerInstanceId: _fixtureProviderInstanceId,
);

/// Adapter used only to obtain real wire measurements; its mock is never hit.
CodexResponsesAdapter _measurementAdapter() =>
    _adapter(reasoningId: 'unused', encryptedContent: 'unused');

/// Produces one assistant message whose provider state replays [encryptedChars]
/// characters of opaque Codex reasoning state (not base64-shaped, so the legacy
/// serialized basis priced it as plain text).
Future<Message> _assistantWithOpaqueReplay({
  required String reasoningId,
  required int encryptedChars,
}) async {
  final producer = _adapter(
    reasoningId: reasoningId,
    encryptedContent: 'E' * encryptedChars,
  );
  final response = await producer.generateResponse([
    Message(role: MessageRole.system, content: 'System instructions'),
    Message(role: MessageRole.user, content: 'Hello codex'),
  ], options: _measureOptions);
  final state = response.message.providerState;
  expect(state, isNotNull, reason: 'fixture must replay encrypted reasoning');
  final reasoningItems = state!.data['reasoning_items'] as List;
  expect(reasoningItems, hasLength(1));
  final item = reasoningItems.single as Map;
  expect(item['id'], reasoningId);
  expect((item['encrypted_content'] as String).length, encryptedChars);
  return response.message;
}

void main() {
  group('Codex wire measurement pricing (G11)', () {
    test(
      'opaque encrypted replay state is not priced as ordinary text',
      () async {
        const encryptedChars = 1_280_000;
        final adapter = _measurementAdapter();
        final carrier = await _assistantWithOpaqueReplay(
          reasoningId: 'rs_1',
          encryptedChars: encryptedChars,
        );
        final history = [
          Message(role: MessageRole.user, content: 'hello codex'),
          carrier,
        ];

        final measurement = await adapter.measureInput(
          history,
          options: _measureOptions,
        );

        expect(measurement, isNotNull);
        // Only the small visible material may be priced: the legacy serialized
        // basis charged encryptedChars / 4 (~320000) for the same request.
        expect(
          measurement!.estimatedTokens,
          lessThan(2_000),
          reason:
              'opaque encrypted replay leaked into token pricing '
              '(legacy basis would report ~320000 for this request)',
        );
        expect(
          measurement.estimatedTokens,
          greaterThan(0),
          reason: 'visible material must still be priced',
        );
        expect(
          measurement.inputItemFingerprints,
          isNotEmpty,
          reason: 'ordered fingerprints must stay intact',
        );
      },
    );

    test(
      'encoded image transport is priced from image dimensions, not from the base64 payload',
      () async {
        const imageBytes = 300 * 1024;
        final base64Image = base64Encode(
          List<int>.generate(imageBytes, (index) => index % 251),
        );
        final toolResult = ToolExecutionResult(
          blocks: [
            ToolTextBlock(text: 'structured payload'),
            ToolImageBlock(
              dataBase64: base64Image,
              mimeType: 'image/png',
              width: 1,
              height: 1,
              detail: ToolImageDetail.high,
            ),
          ],
        );
        final history = [
          Message(role: MessageRole.user, content: 'inspect'),
          Message(
            role: MessageRole.assistant,
            content: 'Calling view_image',
            toolCalls: [
              ToolCall(
                id: 'call_1',
                name: 'view_image',
                arguments: const {'path': 'fixture.png'},
              ),
            ],
          ),
          Message(
            role: MessageRole.tool,
            content: toolResult.displayText,
            toolCallId: 'call_1',
            toolResult: toolResult,
          ),
        ];
        final adapter = _measurementAdapter();

        final measurement = await adapter.measureInput(
          history,
          options: _measureOptions,
        );

        final encodedAllowance = (imageBytes ~/ 1024) * 85;
        expect(measurement, isNotNull);
        expect(
          measurement!.estimatedTokens,
          lessThan(5_000),
          reason:
              'a 1x1 image must not be charged the encoded transport '
              '(the byte basis charged $encodedAllowance tokens)',
        );
        expect(
          measurement.estimatedTokens,
          greaterThan(0),
          reason: 'image and text material must still be accounted',
        );
        expect(
          measurement.estimatedTokens,
          lessThan(base64Image.length ~/ 8),
          reason: 'the encoded transport must never dominate the estimate',
        );
      },
    );
  });

  group('Principal DB receipts (G11 R2)', () {
    RequestPressureEvaluator evaluator() => RequestPressureEvaluator();

    /// Observed latest-requester carrier: `1472888` canonical base64 characters
    /// decoding to roughly `1104666` bytes at `1203x1321`.
    List<Message> toolImageHistory({
      required int base64Characters,
      required int width,
      required int height,
      String toolText = 'structured payload',
    }) {
      final base64Image = base64Encode(
        List<int>.generate((base64Characters ~/ 4) * 3, (index) => index % 251),
      );
      expect(base64Image.length, base64Characters);
      final toolResult = ToolExecutionResult(
        blocks: [
          ToolTextBlock(text: toolText),
          ToolImageBlock(
            dataBase64: base64Image,
            mimeType: 'image/png',
            width: width,
            height: height,
            detail: ToolImageDetail.high,
          ),
        ],
      );
      return [
        Message(role: MessageRole.user, content: 'inspect the rendered view'),
        Message(
          role: MessageRole.assistant,
          content: 'Calling view_image',
          toolCalls: [
            ToolCall(
              id: 'call_image',
              name: 'view_image',
              arguments: const {'path': 'fixture.png'},
            ),
          ],
        ),
        Message(
          role: MessageRole.tool,
          content: toolResult.displayText,
          toolCallId: 'call_image',
          toolResult: toolResult,
        ),
      ];
    }

    test(
      'authoritative 136213 baseline plus the 1472888-character carrier stays below the auto threshold',
      () async {
        const confirmedInputTokens = 136_213;
        const carrierCharacters = 1_472_888;
        final adapter = _measurementAdapter();
        final baselineHistory = [
          Message(
            role: MessageRole.user,
            content: 'x' * (confirmedInputTokens * 4),
          ),
        ];
        final baseline = (await adapter.measureInput(
          baselineHistory,
          options: _measureOptions,
        ))!;
        expect(
          baseline.estimatedTokens,
          closeTo(confirmedInputTokens, 2_000),
          reason: 'the fixture must reproduce the authoritative baseline scale',
        );

        final carrierHistory = toolImageHistory(
          base64Characters: carrierCharacters,
          width: 1203,
          height: 1321,
        );
        final currentHistory = [...baselineHistory, ...carrierHistory];
        final current = (await adapter.measureInput(
          currentHistory,
          options: _measureOptions,
        ))!;
        expect(current.extendsMeasurement(baseline), isTrue);

        // Defect reference: pricing encoded transport at 85 tokens per KiB
        // charges ~91715 tokens for this 1.1 MB image and crosses the live
        // threshold with no genuine model-visible growth.
        final legacyEncodedAllowance =
            (carrierCharacters * 3 ~/ 4) ~/ 1024 * 85;
        expect(legacyEncodedAllowance, greaterThan(90_000));
        expect(
          confirmedInputTokens + legacyEncodedAllowance,
          greaterThan(_expectedThresholdTokens),
          reason: 'the regression scenario must reproduce the live crossing',
        );

        final snapshot = evaluator().evaluate(
          routeSignature: _route(),
          contextWindowTokens: _contextWindow,
          conversationMessages: currentHistory,
          systemPrompt: '',
          runtimeContext: '',
          toolSchemas: const [],
          confirmedInputUsage: ConfirmedInputUsageBaseline(
            routeSignature: _route(),
            inputTokens: confirmedInputTokens,
            conversationMessages: baselineHistory,
            systemPrompt: '',
            runtimeContext: '',
            toolSchemas: const [],
            wireMeasurement: baseline,
          ),
          wireEstimatedInputTokens: current.estimatedTokens,
          wireMeasurement: current,
          thresholdRatio: _thresholdRatio,
        );

        expect(snapshot.measurementKind, CompactionMeasurementKind.mixed);
        expect(
          snapshot.estimatedRequestTokens - confirmedInputTokens,
          lessThan(10_000),
          reason:
              'a single 1203x1321 image must not add ~91715 tokens of '
              'text pricing to the confirmed baseline',
        );
        expect(
          snapshot.estimatedRequestTokens - confirmedInputTokens,
          greaterThan(0),
          reason: 'image material must still carry a nonzero estimate',
        );
        expect(
          snapshot.estimatedRequestTokens,
          lessThan(_expectedThresholdTokens),
          reason: 'the live image suffix must not trigger automatic compaction',
        );
      },
    );

    test(
      'equivalent image content cannot be priced by its encoding size',
      () async {
        final adapter = _measurementAdapter();
        final large = (await adapter.measureInput(
          toolImageHistory(
            base64Characters: 1_472_888,
            width: 1203,
            height: 1321,
          ),
          options: _measureOptions,
        ))!;
        final small = (await adapter.measureInput(
          toolImageHistory(
            base64Characters: 300_000,
            width: 1203,
            height: 1321,
          ),
          options: _measureOptions,
        ))!;
        expect(
          small.estimatedTokens,
          large.estimatedTokens,
          reason:
              'identical image dimensions must cost the same regardless of '
              'compressed transport size',
        );
        final legacyLarge = (1_472_888 * 3 ~/ 4) ~/ 1024 * 85;
        final legacySmall = (300_000 * 3 ~/ 4) ~/ 1024 * 85;
        expect(legacyLarge - legacySmall, greaterThan(70_000));
      },
    );

    test(
      'genuine visible growth after the image still crosses the threshold',
      () async {
        const confirmedInputTokens = 136_213;
        final adapter = _measurementAdapter();
        final baselineHistory = [
          Message(
            role: MessageRole.user,
            content: 'x' * (confirmedInputTokens * 4),
          ),
        ];
        final baseline = (await adapter.measureInput(
          baselineHistory,
          options: _measureOptions,
        ))!;
        final currentHistory = [
          ...baselineHistory,
          ...toolImageHistory(
            base64Characters: 1_472_888,
            width: 1203,
            height: 1321,
          ),
          Message(role: MessageRole.user, content: 'g' * (100_000 * 4)),
        ];
        final current = (await adapter.measureInput(
          currentHistory,
          options: _measureOptions,
        ))!;
        final snapshot = evaluator().evaluate(
          routeSignature: _route(),
          contextWindowTokens: _contextWindow,
          conversationMessages: currentHistory,
          systemPrompt: '',
          runtimeContext: '',
          toolSchemas: const [],
          confirmedInputUsage: ConfirmedInputUsageBaseline(
            routeSignature: _route(),
            inputTokens: confirmedInputTokens,
            conversationMessages: baselineHistory,
            systemPrompt: '',
            runtimeContext: '',
            toolSchemas: const [],
            wireMeasurement: baseline,
          ),
          wireEstimatedInputTokens: current.estimatedTokens,
          wireMeasurement: current,
          thresholdRatio: _thresholdRatio,
        );
        expect(snapshot.exceedsThreshold, isTrue);
        expect(
          snapshot.estimatedRequestTokens,
          greaterThan(_expectedThresholdTokens),
          reason: 'real model-visible growth must still trigger compaction',
        );
      },
    );

    test(
      'cold cross-provider estimate excludes opaque replay and discards the foreign 207084 baseline',
      () async {
        const opaqueCharacters = 863_592;
        const toolTextCharacters = 487_801;
        const imageCharacters = 59_984;
        final adapter = _measurementAdapter();
        final carriers = <Message>[];
        for (var index = 0; index < 13; index++) {
          carriers.add(
            await _assistantWithOpaqueReplay(
              reasoningId: 'rs_cold_$index',
              encryptedChars: opaqueCharacters ~/ 13,
            ),
          );
        }
        final imageHistory = toolImageHistory(
          base64Characters: imageCharacters,
          width: 640,
          height: 480,
        );
        final history = [
          Message(role: MessageRole.user, content: 'y' * toolTextCharacters),
          ...carriers,
          ...imageHistory,
        ];

        final cold = (await adapter.measureInput(
          history,
          options: _measureOptions,
        ))!;
        expect(
          cold.estimatedTokens,
          lessThan(140_000),
          reason:
              'opaque replay must not be priced as visible text on a cold '
              'route-transition estimate (legacy basis charged ~215898 for '
              'the replay alone)',
        );
        expect(
          cold.estimatedTokens,
          greaterThan(120_000),
          reason: 'visible tool/state text must still be priced',
        );

        // The prior confirmed usage belongs to another route and must never be
        // carried onto the Codex route.
        final foreignBaseline = ConfirmedInputUsageBaseline(
          routeSignature: const RouteSignature(
            providerInstanceId: 'opencode-go',
            templateId: 'openai',
            protocol: 'openai_compatible',
            normalizedBaseUrl: 'https://opencode.invalid/v1',
            modelId: 'deepseek-v4.1-flash',
            configRevision: 1,
            credentialRevision: 1,
          ),
          inputTokens: 207_084,
          conversationMessages: const [],
          systemPrompt: '',
          runtimeContext: '',
          toolSchemas: const [],
        );
        final foreignSnapshot = evaluator().evaluate(
          routeSignature: _route(),
          contextWindowTokens: _contextWindow,
          conversationMessages: history,
          systemPrompt: '',
          runtimeContext: '',
          toolSchemas: const [],
          confirmedInputUsage: foreignBaseline,
          wireEstimatedInputTokens: cold.estimatedTokens,
          wireMeasurement: cold,
          thresholdRatio: _thresholdRatio,
        );
        expect(
          foreignSnapshot.measurementKind,
          CompactionMeasurementKind.estimated,
        );
        expect(foreignSnapshot.confirmedInputTokens, isNull);
        expect(foreignSnapshot.estimatedRequestTokens, cold.estimatedTokens);

        // A same-route baseline whose recorded prefix no longer matches the
        // prospective request is also discarded rather than mixed.
        final stalePrefixBaseline = ConfirmedInputUsageBaseline(
          routeSignature: _route(),
          inputTokens: 207_084,
          conversationMessages: [
            Message(role: MessageRole.user, content: 'different prefix'),
          ],
          systemPrompt: '',
          runtimeContext: '',
          toolSchemas: const [],
        );
        final staleSnapshot = evaluator().evaluate(
          routeSignature: _route(),
          contextWindowTokens: _contextWindow,
          conversationMessages: history,
          systemPrompt: '',
          runtimeContext: '',
          toolSchemas: const [],
          confirmedInputUsage: stalePrefixBaseline,
          wireEstimatedInputTokens: cold.estimatedTokens,
          wireMeasurement: cold,
          thresholdRatio: _thresholdRatio,
        );
        expect(
          staleSnapshot.measurementKind,
          CompactionMeasurementKind.estimated,
        );
        expect(staleSnapshot.estimatedRequestTokens, cold.estimatedTokens);
        expect(staleSnapshot.exceedsThreshold, isFalse);
      },
    );
  });

  group('Automatic compaction pressure boundary (G11)', () {
    RequestPressureEvaluator evaluator() => RequestPressureEvaluator();

    test(
      'opaque carrier growth leaves confirmed-baseline pressure under the auto threshold',
      () async {
        const visibleTokens = 185_000;
        const encryptedChars = 1_280_000;
        final adapter = _measurementAdapter();
        final baseCarrier = await _assistantWithOpaqueReplay(
          reasoningId: 'rs_base',
          encryptedChars: 4_000,
        );
        final baselineHistory = [
          Message(role: MessageRole.user, content: 'x' * (visibleTokens * 4)),
          baseCarrier,
        ];
        final baseline = (await adapter.measureInput(
          baselineHistory,
          options: _measureOptions,
        ))!;
        expect(baseline.estimatedTokens, closeTo(visibleTokens, 5_000));
        expect(baseline.estimatedTokens, lessThan(_expectedThresholdTokens));

        // Only opaque replay grows: no new model-visible content at all.
        final grownCarrier = await _assistantWithOpaqueReplay(
          reasoningId: 'rs_grown',
          encryptedChars: encryptedChars,
        );
        final extendedHistory = [...baselineHistory, grownCarrier];
        final current = (await adapter.measureInput(
          extendedHistory,
          options: _measureOptions,
        ))!;
        expect(current.extendsMeasurement(baseline), isTrue);

        // The defect reference: the legacy serialized basis charged
        // encryptedChars / 4 for this growth, pushing the mixed measurement
        // far past the auto threshold.
        final legacyOpaqueDelta = encryptedChars ~/ 4;
        expect(
          baseline.estimatedTokens + legacyOpaqueDelta,
          greaterThan(_expectedThresholdTokens),
          reason: 'the scenario must reproduce the live over-threshold shape',
        );

        final snapshot = evaluator().evaluate(
          routeSignature: _route(),
          contextWindowTokens: _contextWindow,
          conversationMessages: extendedHistory,
          systemPrompt: '',
          runtimeContext: '',
          toolSchemas: const [],
          confirmedInputUsage: ConfirmedInputUsageBaseline(
            routeSignature: _route(),
            inputTokens: baseline.estimatedTokens,
            conversationMessages: baselineHistory,
            systemPrompt: '',
            runtimeContext: '',
            toolSchemas: const [],
            wireMeasurement: baseline,
          ),
          wireEstimatedInputTokens: current.estimatedTokens,
          wireMeasurement: current,
          thresholdRatio: _thresholdRatio,
        );

        expect(snapshot.measurementKind, CompactionMeasurementKind.mixed);
        expect(
          snapshot.estimatedRequestTokens - baseline.estimatedTokens,
          lessThan(2_000),
          reason: 'opaque growth must not move the confirmed-baseline estimate',
        );
        expect(
          snapshot.estimatedRequestTokens,
          lessThan(_expectedThresholdTokens),
        );
        expect(
          snapshot.exceedsThreshold,
          isFalse,
          reason:
              'opaque replay growth must not trigger repeated automatic '
              'compaction',
        );
      },
    );

    test(
      'visible growth still crosses the threshold while a post-boundary projection does not re-trigger',
      () async {
        const visibleTokens = 185_000;
        const visibleGrowthTokens = 60_000;
        final adapter = _measurementAdapter();
        final baseCarrier = await _assistantWithOpaqueReplay(
          reasoningId: 'rs_base',
          encryptedChars: 4_000,
        );
        final baselineHistory = [
          Message(role: MessageRole.user, content: 'x' * (visibleTokens * 4)),
          baseCarrier,
        ];
        final baseline = (await adapter.measureInput(
          baselineHistory,
          options: _measureOptions,
        ))!;
        final carrier = await _assistantWithOpaqueReplay(
          reasoningId: 'rs_carrier',
          encryptedChars: 1_280_000,
        );

        final grownHistory = [
          ...baselineHistory,
          carrier,
          Message(
            role: MessageRole.user,
            content: 'g' * (visibleGrowthTokens * 4),
          ),
        ];
        final grown = (await adapter.measureInput(
          grownHistory,
          options: _measureOptions,
        ))!;
        expect(grown.extendsMeasurement(baseline), isTrue);

        final grownSnapshot = evaluator().evaluate(
          routeSignature: _route(),
          contextWindowTokens: _contextWindow,
          conversationMessages: grownHistory,
          systemPrompt: '',
          runtimeContext: '',
          toolSchemas: const [],
          confirmedInputUsage: ConfirmedInputUsageBaseline(
            routeSignature: _route(),
            inputTokens: baseline.estimatedTokens,
            conversationMessages: baselineHistory,
            systemPrompt: '',
            runtimeContext: '',
            toolSchemas: const [],
            wireMeasurement: baseline,
          ),
          wireEstimatedInputTokens: grown.estimatedTokens,
          wireMeasurement: grown,
          thresholdRatio: _thresholdRatio,
        );
        expect(
          grownSnapshot.estimatedRequestTokens,
          greaterThan(_expectedThresholdTokens),
          reason: 'real model-visible growth must still trigger compaction',
        );
        expect(grownSnapshot.exceedsThreshold, isTrue);

        // After a successful boundary the projection is the summary plus the
        // retained tail; the tail still carries opaque replay, which must not
        // immediately re-inflate pressure and re-trigger compaction.
        final postBoundaryHistory = [
          Message(role: MessageRole.user, content: 'compaction summary'),
          carrier,
          Message(role: MessageRole.user, content: 'continuation ${'c' * 400}'),
        ];
        final postBoundary = (await adapter.measureInput(
          postBoundaryHistory,
          options: _measureOptions,
        ))!;
        final postBoundarySnapshot = evaluator().evaluate(
          routeSignature: _route(),
          contextWindowTokens: _contextWindow,
          conversationMessages: postBoundaryHistory,
          systemPrompt: '',
          runtimeContext: '',
          toolSchemas: const [],
          wireEstimatedInputTokens: postBoundary.estimatedTokens,
          wireMeasurement: postBoundary,
          thresholdRatio: _thresholdRatio,
        );
        expect(
          postBoundarySnapshot.exceedsThreshold,
          isFalse,
          reason:
              'a retained tail with opaque replay must not immediately '
              're-trigger compaction',
        );
      },
    );

    test(
      'a stale pre-fix baseline cannot inflate the corrected measurement',
      () async {
        const visibleTokens = 185_000;
        final adapter = _measurementAdapter();
        final carrier = await _assistantWithOpaqueReplay(
          reasoningId: 'rs_stale',
          encryptedChars: 1_280_000,
        );
        final history = [
          Message(role: MessageRole.user, content: 'x' * (visibleTokens * 4)),
          carrier,
        ];
        final current = (await adapter.measureInput(
          history,
          options: _measureOptions,
        ))!;

        // Simulates a baseline persisted before the pricing repair: identical
        // ordered fingerprints, but a legacy inflated estimate.
        final staleBaseline = WireInputMeasurement(
          estimatedTokens: current.estimatedTokens + 320_000,
          stableMaterialFingerprint: current.stableMaterialFingerprint,
          inputItemFingerprints: current.inputItemFingerprints,
        );

        final snapshot = evaluator().evaluate(
          routeSignature: _route(),
          contextWindowTokens: _contextWindow,
          conversationMessages: history,
          systemPrompt: '',
          runtimeContext: '',
          toolSchemas: const [],
          confirmedInputUsage: ConfirmedInputUsageBaseline(
            routeSignature: _route(),
            inputTokens: 505_982,
            conversationMessages: history,
            systemPrompt: '',
            runtimeContext: '',
            toolSchemas: const [],
            wireMeasurement: staleBaseline,
          ),
          wireEstimatedInputTokens: current.estimatedTokens,
          wireMeasurement: current,
          thresholdRatio: _thresholdRatio,
        );

        expect(
          snapshot.estimatedRequestTokens,
          current.estimatedTokens,
          reason:
              'a non-extending (negative delta) baseline must be discarded '
              'instead of mixing stale inflated usage',
        );
        expect(
          snapshot.estimatedRequestTokens,
          lessThan(_expectedThresholdTokens),
        );
        expect(snapshot.exceedsThreshold, isFalse);
      },
    );
  });
}
