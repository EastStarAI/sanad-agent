/// Task 106 G7 acceptance closure — real adapter wire observation for
/// compaction-derived request options.
///
/// Wave A proved option/thinking preservation at the canonical builder,
/// `forSession`, and runner-forwarding boundaries, and validated attachments at
/// the wire codec. The still-open G7 acceptance asked for fixture adapters to
/// observe the exact expected options and thinking wire directive in all three
/// paths, plus an image-bearing request succeeding through the real adapter
/// builders with a verified temporary attachment store and specific pre-HTTP
/// failures for absent, corrupt, or unauthorized media.
///
/// This suite closes those gaps with fixture HTTP capture: requests are
/// dispatched through the production adapters (`BaseOpenAIAdapter`,
/// `BaseAnthropicAdapter`) with a `MockClient` carrier. The synthetic carrier
/// proves real adapter body construction from compaction-derived options; it is
/// not live vendor acceptance, and no network egress or user Home is involved.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/user_attachment.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/route_capability_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/engine/adapters/base_anthropic_adapter.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/models_dev_service.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/runtime/compaction_request_factory.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/evolution/compaction/model_projection_builder.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/db/session_history_revision_repository.dart';
import 'package:sanad_agent/evolution/db/session_projection_revision_repository.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:test/test.dart';

const _effortModel = 'compaction-effort-fixture';
const _adaptiveModel = 'compaction-adaptive-fixture';
const _wireProviderId = 'wire-openai-provider';
const _anthropicProviderId = 'wire-anthropic-provider';

// A minimal but real PNG header fixture (magic + IHDR) used to exercise the
// verified attachment reader without shipping binary test assets.
const _validPngBytes = [
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
];

const _customAnthropicProfile = ProviderProfile(
  name: 'custom',
  displayName: 'Custom Anthropic',
  description: 'Custom Anthropic provider',
  defaultBaseUrl: 'https://custom.anthropic.test',
  authType: 'api_key',
  apiMode: 'anthropic_messages',
  protocol: ProviderProtocol.anthropicCompatible,
  apiKeyRequirement: ApiKeyRequirement.optional,
  authMethods: [ProviderAuthMethod.apiKey],
);

RouteSignature _openAiRoute() => const RouteSignature(
  providerInstanceId: _wireProviderId,
  templateId: kCustomProviderTemplateId,
  protocol: 'openai_compatible',
  normalizedBaseUrl: 'https://wire.invalid/v1',
  modelId: _effortModel,
  configRevision: 1,
  credentialRevision: 1,
);

RouteSignature _anthropicRoute() => const RouteSignature(
  providerInstanceId: _anthropicProviderId,
  templateId: kCustomProviderTemplateId,
  protocol: 'anthropic_compatible',
  normalizedBaseUrl: 'https://wire.invalid/v1',
  modelId: _adaptiveModel,
  configRevision: 1,
  credentialRevision: 1,
);

RouteSignature _visionRoute() => const RouteSignature(
  providerInstanceId: 'custom-provider',
  templateId: kCustomProviderTemplateId,
  protocol: 'openai_compatible',
  normalizedBaseUrl: 'https://custom.invalid/v1',
  modelId: 'vision-model',
  configRevision: 1,
  credentialRevision: 1,
);

class _WireRuntimeService extends AgentRuntimeService {
  _WireRuntimeService(super.config, super.repo);

  @override
  RouteSignature resolveSignature({String? providerId, String? modelId}) {
    if (providerId == _anthropicProviderId) return _anthropicRoute();
    return _openAiRoute();
  }
}

void main() {
  late Directory scratch;
  late AgentStateDatabase state;
  late SessionDB sessions;
  late SessionHistoryRevisionRepository historyRepo;
  late SessionProjectionRevisionRepository projRepo;
  late ProviderInstanceRepository instances;
  late Config config;
  late List<Map<String, dynamic>> requests;

  setUp(() async {
    scratch = Directory.systemTemp.createTempSync('sanad-106-wire-');
    setSanadHomeOverride(scratch.path);
    requests = [];
    File(p.join(scratch.path, 'config.yaml')).writeAsStringSync('''
model_capabilities:
  vision-model:
    supports_image_input: true
  $_effortModel:
    thinking_control:
      status: supported
      wire: openai_chat_effort
      options:
        high: high
      default_option: high
  $_adaptiveModel:
    thinking_control:
      status: supported
      wire: anthropic_adaptive
      options:
        off: false
        high: high
      default_option: high
''');
    File(p.join(scratch.path, 'catalog.json')).writeAsStringSync('{}');

    state = AgentStateDatabase.inMemory();
    sessions = SessionDB.fromState(state);
    historyRepo = SessionHistoryRevisionRepository(state);
    projRepo = SessionProjectionRevisionRepository(state);
    instances = ProviderInstanceRepository.fromDatabase(state.db);
    config = Config(environment: {'SANAD_HOME': scratch.path});

    // Await the reset: an un-awaited GetIt reset continues asynchronously and
    // can wipe freshly registered singletons at the next event-loop yield.
    await getIt.reset();
    getIt.allowReassignment = true;
    SessionManager.resetForTesting();

    final now = DateTime.utc(2026, 10, 18);
    instances.createInstance(
      ProviderInstance(
        id: _wireProviderId,
        templateId: kCustomProviderTemplateId,
        displayName: 'Wire OpenAI Fixture',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        baseUrl: 'https://wire.invalid/v1',
        createdAt: now,
        updatedAt: now,
      ).copyWith(configRevision: 1, credentialRevision: 1),
    );
    instances.createInstance(
      ProviderInstance(
        id: _anthropicProviderId,
        templateId: kCustomProviderTemplateId,
        displayName: 'Wire Anthropic Fixture',
        protocol: ProviderProtocol.anthropicCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        baseUrl: 'https://wire.invalid/v1',
        createdAt: now,
        updatedAt: now,
      ).copyWith(configRevision: 1, credentialRevision: 1),
    );

    sessions.saveSession(
      SessionState(
        sessionId: 'wire-session',
        model: _effortModel,
        providerId: _wireProviderId,
        thinkingMode: 'high',
        createdAt: now,
        updatedAt: now,
        lastUserMessageAt: now,
      ),
    );
    sessions.replaceMessages('wire-session', [
      Message(role: MessageRole.user, content: 'goal: validate wire closure'),
      Message(role: MessageRole.assistant, content: 'working'),
    ]);

    final registry = buildProviderThinkingRegistry();
    final assembler = ThinkingCapabilityAssembler(registry, config);
    final thinkingResolver = ThinkingSelectionResolver(
      instances: instances,
      cacheResolver: ThinkingControlCacheResolver(instances),
      assembler: assembler,
      registry: registry,
      config: config,
    );

    getIt.registerSingleton<AgentStateDatabase>(state);
    getIt.registerSingleton<SessionHistoryRevisionRepository>(historyRepo);
    getIt.registerSingleton<SessionProjectionRevisionRepository>(projRepo);
    getIt.registerSingleton<ProviderInstanceRepository>(instances);
    getIt.registerSingleton<Config>(config);
    getIt.registerSingleton<SessionManager>(SessionManager());
    getIt.registerSingleton<ModelProjectionBuilder>(
      ModelProjectionBuilder(
        sessions: sessions,
        boundaries: CompactionBoundaryRepository(state, historyRepo),
      ),
    );
    getIt.registerSingleton<AgentRuntimeService>(
      _WireRuntimeService(config, instances),
    );
    getIt.registerSingleton<RouteCapabilityResolver>(
      RouteCapabilityResolver(
        instances: instances,
        config: config,
        thinkingResolver: thinkingResolver,
      ),
    );
  });

  tearDown(() {
    getIt.reset();
    SessionManager.resetForTesting();
    setSanadHomeOverride(null);
    state.dispose();
    try {
      scratch.deleteSync(recursive: true);
    } catch (_) {}
  });

  void expectEffortDirective(NativeThinkingDirective? directive) {
    expect(directive, isA<OpenAiEffortDirective>());
    expect((directive! as OpenAiEffortDirective).effort, 'high');
  }

  BaseOpenAIAdapter openAiAdapter() {
    return BaseOpenAIAdapter(
      config,
      ProviderRegistry.findByNameOrAlias(kCustomProviderTemplateId)!,
      providerInstanceId: _wireProviderId,
      client: MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'role': 'assistant', 'content': 'ok'},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
        );
      }),
      baseUrlOverride: 'https://wire.invalid/v1',
      apiKeyOverride: 'fixture-key',
      modelsDevService: ModelsDevService(
        cacheFilePathOverride: p.join(scratch.path, 'catalog.json'),
        client: MockClient((_) async => http.Response('{}', 200)),
      ),
    );
  }

  BaseAnthropicAdapter anthropicAdapter() {
    return BaseAnthropicAdapter(
      config,
      _customAnthropicProfile,
      providerInstanceId: _anthropicProviderId,
      client: MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(
          jsonEncode({
            'id': 'msg_1',
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'ok'},
            ],
            'model': _adaptiveModel,
            'stop_reason': 'end_turn',
            'usage': {'input_tokens': 10, 'output_tokens': 10},
          }),
          200,
        );
      }),
      baseUrlOverride: 'https://wire.invalid/v1',
      apiKeyOverride: 'fixture-key',
    );
  }

  group('Compaction-derived thinking directives reach real adapter wires', () {
    test(
      'manual, automatic and overflow derivations all emit the exact effort directive',
      () async {
        // Manual: the canonical factory derives from the persisted session
        // route and the stored selection.
        final manualRequest = await CompactionRequestFactory.forSession(
          sessionId: 'wire-session',
          trigger: CompactionTrigger.manual,
          compactionId: 'manual-derivation-uuid',
        );
        expect(manualRequest, isNotNull);
        final manualOptions = manualRequest!.providerRequestOptions;
        expect(manualOptions.requestId, 'compaction:manual-derivation-uuid');
        expect(manualOptions.thinkingMode, 'high');
        expectEffortDirective(manualOptions.thinkingDirective);
        expect(manualOptions.routeCapabilityProfile, isNotNull);

        // Automatic and overflow: the runner derives through the same
        // canonical builder from its admitted route and turn options. The
        // runner-level forwarding is asserted in the preflight/overflow
        // suites; this closes the wire observation for those shapes.
        final autoOptions =
            CompactionRequestFactory.buildCompactionRequestOptions(
              sessionId: 'wire-session',
              compactionId: 'auto:auto-derivation-uuid',
              routeSignature: _openAiRoute(),
              baseOptions: LLMRequestOptions(
                sessionId: 'wire-session',
                providerInstanceId: _wireProviderId,
                thinkingMode: 'high',
              ),
              fallbackThinkingMode: 'high',
            );
        final resolvedProfile = getIt<RouteCapabilityResolver>().resolveSync(
          providerInstanceId: _wireProviderId,
          modelId: _effortModel,
          thinkingMode: 'high',
        );
        final overflowOptions =
            CompactionRequestFactory.buildCompactionRequestOptions(
              sessionId: 'wire-session',
              compactionId: 'overflow:overflow-derivation-uuid',
              routeSignature: _openAiRoute(),
              baseOptions: LLMRequestOptions(
                sessionId: 'wire-session',
                providerInstanceId: _wireProviderId,
                thinkingMode: 'high',
                thinkingDirective: resolvedProfile.thinkingDirective,
              ),
              fallbackThinkingMode: 'high',
            );

        expect(autoOptions.requestId, 'compaction:auto:auto-derivation-uuid');
        expect(
          overflowOptions.requestId,
          'compaction:overflow:overflow-derivation-uuid',
        );
        expectEffortDirective(autoOptions.thinkingDirective);
        expect(
          overflowOptions.thinkingDirective,
          same(resolvedProfile.thinkingDirective),
        );

        final subject = openAiAdapter();
        for (final (label, options) in <(String, LLMRequestOptions)>[
          ('manual', manualOptions),
          ('auto', autoOptions),
          ('overflow', overflowOptions),
        ]) {
          requests.clear();
          await subject.generateResponse(
            [Message(role: MessageRole.user, content: 'compact now')],
            modelOverride: _effortModel,
            options: options,
          );
          expect(requests, hasLength(1));
          final body = requests.single;
          expect(
            body['reasoning_effort'],
            'high',
            reason:
                '$label compaction must carry the exact admitted effort '
                'without substitution.',
          );
          expect(
            body.containsKey('thinking'),
            isFalse,
            reason: '$label compaction must not fabricate a toggle field.',
          );
        }
      },
    );

    test(
      'anthropic-adaptive derivation emits the exact adaptive directive on the Messages wire',
      () async {
        final options =
            CompactionRequestFactory.buildCompactionRequestOptions(
              sessionId: 'wire-session',
              compactionId: 'manual-adaptive-uuid',
              routeSignature: _anthropicRoute(),
              baseOptions: LLMRequestOptions(
                sessionId: 'wire-session',
                providerInstanceId: _anthropicProviderId,
                thinkingMode: 'high',
              ),
              fallbackThinkingMode: 'high',
            );
        expect(options.thinkingDirective, isA<AnthropicAdaptiveDirective>());
        expect(
          (options.thinkingDirective! as AnthropicAdaptiveDirective).effort,
          'high',
        );
        expect(options.routeCapabilityProfile, isNotNull);

        await anthropicAdapter().generateResponse(
          [Message(role: MessageRole.user, content: 'compact now')],
          modelOverride: _adaptiveModel,
          options: options,
        );

        expect(requests, hasLength(1));
        final body = requests.single;
        expect(body['thinking'], {'type': 'adaptive'});
        expect((body['output_config'] as Map)['effort'], 'high');
      },
    );
  });

  group('Image attachments through compaction-derived options', () {
    BaseOpenAIAdapter visionAdapter() {
      return BaseOpenAIAdapter(
        config,
        ProviderRegistry.findByNameOrAlias(kCustomProviderTemplateId)!,
        providerInstanceId: 'custom-provider',
        client: MockClient((request) async {
          requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'role': 'assistant', 'content': 'ok'},
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
          );
        }),
        baseUrlOverride: 'https://custom.invalid/v1',
        apiKeyOverride: 'fixture-key',
        modelsDevService: ModelsDevService(
          cacheFilePathOverride: p.join(scratch.path, 'catalog.json'),
          client: MockClient((_) async => http.Response('{}', 200)),
        ),
      );
    }

    Future<AttachmentStore> stagePng({
      required String homePath,
      required String attachmentId,
      List<int>? bytes,
    }) async {
      final payload = bytes ?? _validPngBytes;
      final dir = Directory(p.join(homePath, 'attachments', attachmentId))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'payload')).writeAsBytesSync(payload);
      return AttachmentStore(state, stateHome: homePath);
    }

    UserAttachment pngAttachment({
      required String attachmentId,
      List<int>? bytes,
      String? declaredSha256,
      int? declaredSize,
    }) {
      final payload = bytes ?? _validPngBytes;
      return UserAttachment(
        id: attachmentId,
        safeName: 'closure.png',
        mimeType: 'image/png',
        sizeBytes: declaredSize ?? payload.length,
        sha256: declaredSha256 ?? sha256.convert(payload).toString(),
        kind: UserAttachmentKind.image,
        agentLocalReference: 'attachments/$attachmentId/payload',
        mediaId: 'media-$attachmentId',
      );
    }

    LLMRequestOptions derivedImageOptions(AttachmentStore store) {
      final options = CompactionRequestFactory.buildCompactionRequestOptions(
        sessionId: 'wire-session',
        compactionId: 'manual-image-uuid',
        routeSignature: _visionRoute(),
        baseOptions: LLMRequestOptions(
          sessionId: 'wire-session',
          providerInstanceId: 'custom-provider',
          attachmentStore: store,
        ),
      );
      expect(options.attachmentStore, same(store));
      return options;
    }

    test(
      'image-bearing compaction request succeeds through the real adapter builder',
      () async {
        final store = await stagePng(
          homePath: scratch.path,
          attachmentId: 'att-closure-1',
        );
        final attachment = pngAttachment(attachmentId: 'att-closure-1');
        final options = derivedImageOptions(store);

        await visionAdapter().generateResponse([
          Message(
            role: MessageRole.user,
            content: 'Describe this image',
            attachments: [attachment],
          ),
        ], modelOverride: 'vision-model', options: options);

        expect(requests, hasLength(1));
        final message = (requests.single['messages'] as List).first as Map;
        final content = message['content'] as List;
        expect(content.first, {'type': 'text', 'text': 'Describe this image'});
        expect(content.last['type'], 'image_url');
        expect(
          content.last['image_url']['url'],
          'data:image/png;base64,${base64Encode(_validPngBytes)}',
        );
      },
    );

    test(
      'corrupt media with compaction-derived options fails before HTTP',
      () async {
        final store = await stagePng(
          homePath: scratch.path,
          attachmentId: 'att-closure-2',
        );
        final attachment = pngAttachment(attachmentId: 'att-closure-2');
        final options = derivedImageOptions(store);

        // Corrupt the stored bytes after staging; the record still declares
        // the original hash and size.
        final mutated = List<int>.from(_validPngBytes)..[12] = 0xAA;
        File(
          p.join(scratch.path, 'attachments', 'att-closure-2', 'payload'),
        ).writeAsBytesSync(mutated);

        requests.clear();
        await expectLater(
          visionAdapter().generateResponse([
            Message(
              role: MessageRole.user,
              content: 'Describe this image',
              attachments: [attachment],
            ),
          ], modelOverride: 'vision-model', options: options),
          throwsA(isA<StateError>()),
        );
        expect(requests, isEmpty);
      },
    );

    test(
      'media outside the request Home jail fails before HTTP',
      () async {
        final home2 = Directory.systemTemp.createTempSync('sanad-106-wire2-');
        try {
          await stagePng(
            homePath: home2.path,
            attachmentId: 'att-closure-3',
          );
          // The request's attachment store belongs to an isolated Home that
          // does not contain the referenced payload.
          final store = AttachmentStore(state, stateHome: scratch.path);
          final attachment = pngAttachment(attachmentId: 'att-closure-3');
          final options = derivedImageOptions(store);

          requests.clear();
          await expectLater(
            visionAdapter().generateResponse([
              Message(
                role: MessageRole.user,
                content: 'Describe this image',
                attachments: [attachment],
              ),
            ], modelOverride: 'vision-model', options: options),
            throwsA(isA<StateError>()),
          );
          expect(requests, isEmpty);
        } finally {
          home2.deleteSync(recursive: true);
        }
      },
    );
  });
}
