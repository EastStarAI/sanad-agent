/// Registry-derived per-kind thinking matrix, verified against real adapters.
///
/// Plan77 G4 requires every project-supported provider kind to be mapped to:
/// * its authoritative descriptor (status/kind/options/default),
/// * the typed native directive for each advertised option,
/// * the actual request body produced by the production adapter for that route.
///
/// Per row the test asserts the descriptor's documented `status`, `kind`,
/// advertised option set and `default_option_id` metadata, then proves that
/// every option the composer can advertise resolves to a non-default directive
/// AND changes the real wire body. An advertised option that silently produces
/// no wire effect is a defect, not a coverage gap. Unknown or unsupported rows
/// assert their documented absent control instead.
///
/// Scope note: this test mirrors the runtime factory's selection (the same
/// template/protocol/api-mode inputs the factory reads) and then drives the real
/// production adapters with a `MockClient`; it does not construct or invoke the
/// runtime adapter factory itself. Actual daemon/runtime wiring is verified
/// separately, not here.
///
/// Every expectation in this file is written from the documented contract (the
/// provider docs, the fixture declarations and the native producer metadata
/// below) and never derived from the catalog, policy, resolver or descriptor
/// under test. The fixture list below holds 53 rows; the file's remaining tests
/// are the identity and negative-control groups.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_thinking/google_model_catalog.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:sanad_agent/core/provider_thinking/xai_model_catalog.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_errors.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/engine/adapters/base_anthropic_adapter.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/codex_responses_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/ollama_adapter.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

/// Thinking-related body keys per route family used to prove a wire effect.
const _chatKeys = [
  'reasoning_effort',
  'thinking',
  'reasoning',
  'extra_body',
  'chat_template_kwargs',
];
const _responsesKeys = ['reasoning', 'reasoning_effort'];
const _messagesKeys = ['thinking', 'output_config'];
const _ollamaKeys = ['think'];

/// One independently written expected fact inside the captured provider body.
///
/// `value == null` asserts that the path is absent from the body.
class _WireFact {
  final List<String> path;
  final Object? value;

  const _WireFact(this.path, this.value);
}

/// Independent expected body facts for one advertised selection id. These are
/// written from the documented wire contracts, never produced by calling the
/// production serializer.
class _OptionWireFacts {
  final List<_WireFact> facts;
  final List<List<String>> absentPaths;

  const _OptionWireFacts({this.facts = const [], this.absentPaths = const []});
}

Map<String, _OptionWireFacts> _chatEffortWire(List<String> effortIds) => {
  for (final id in effortIds)
    id: _OptionWireFacts(
      facts: [
        _WireFact(['reasoning_effort'], id),
      ],
    ),
};

Map<String, _OptionWireFacts> _responsesEffortWire(List<String> effortIds) => {
  for (final id in effortIds)
    id: _OptionWireFacts(
      facts: [
        _WireFact(['reasoning', 'effort'], id),
        _WireFact(['reasoning', 'summary'], 'auto'),
      ],
    ),
};

/// Chat toggle wire: `on`/`off` carry only the thinking envelope.
Map<String, _OptionWireFacts> _toggleWire() => const {
  'on': _OptionWireFacts(
    facts: [
      _WireFact(['thinking', 'type'], 'enabled'),
    ],
    absentPaths: [
      ['reasoning_effort'],
    ],
  ),
  'off': _OptionWireFacts(
    facts: [
      _WireFact(['thinking', 'type'], 'disabled'),
    ],
    absentPaths: [
      ['reasoning_effort'],
    ],
  ),
};

/// Effort wire that enables thinking alongside the effort value. The model
/// family documents an explicit `off` disable with no effort field.
Map<String, _OptionWireFacts> _enabledToggleEffortWire(
  List<String> effortIds,
) => {
  'off': _toggleWire()['off']!,
  for (final id in effortIds) id: _enabledEffortFacts(id),
};

/// Effort wire for a family that documents effort tiers only (always-on
/// thinking, no `off`).
Map<String, _OptionWireFacts> _forcedEffortWire(List<String> effortIds) => {
  for (final id in effortIds) id: _enabledEffortFacts(id),
};

_OptionWireFacts _enabledEffortFacts(String effortId) => _OptionWireFacts(
  facts: [
    _WireFact(['thinking', 'type'], 'enabled'),
    _WireFact(['reasoning_effort'], effortId),
  ],
);

/// Effort wire that sends only the effort value (no thinking envelope).
Map<String, _OptionWireFacts> _effortOnlyWire(List<String> effortIds) => {
  for (final id in effortIds)
    id: _OptionWireFacts(
      facts: [
        _WireFact(['reasoning_effort'], id),
      ],
      absentPaths: [
        ['thinking'],
      ],
    ),
};

/// Google budget wire inside `extra_body.google.thinking_config`.
Map<String, _OptionWireFacts> _googleBudgetWire({
  required Map<String, int> tierTokens,
  required bool supportsOff,
}) => {
  if (supportsOff)
    'off': const _OptionWireFacts(
      facts: [
        _WireFact([
          'extra_body',
          'google',
          'thinking_config',
          'thinking_budget',
        ], 0),
      ],
    ),
  for (final entry in tierTokens.entries)
    entry.key: _OptionWireFacts(
      facts: [
        _WireFact([
          'extra_body',
          'google',
          'thinking_config',
          'thinking_budget',
        ], entry.value),
      ],
    ),
};

Map<String, _OptionWireFacts> _googleLevelWire(List<String> levelIds) => {
  for (final id in levelIds)
    id: _OptionWireFacts(
      facts: [
        _WireFact([
          'extra_body',
          'google',
          'thinking_config',
          'thinking_level',
        ], id),
      ],
    ),
};

/// Anthropic Messages manual budget: active tiers enable thinking with the
/// documented budget; `off` disables thinking without a budget field.
Map<String, _OptionWireFacts> _anthropicBudgetWire(
  Map<String, int> tierTokens,
) => {
  'off': const _OptionWireFacts(
    facts: [
      _WireFact(['thinking', 'type'], 'disabled'),
    ],
    absentPaths: [
      ['thinking', 'budget_tokens'],
    ],
  ),
  for (final entry in tierTokens.entries)
    entry.key: _OptionWireFacts(
      facts: [
        _WireFact(['thinking', 'type'], 'enabled'),
        _WireFact(['thinking', 'budget_tokens'], entry.value),
      ],
    ),
};

/// Anthropic Messages adaptive effort: effort travels in `output_config`;
/// `off` disables thinking and emits no effort.
Map<String, _OptionWireFacts> _anthropicAdaptiveWire(List<String> effortIds) =>
    {
      'off': const _OptionWireFacts(
        facts: [
          _WireFact(['thinking', 'type'], 'disabled'),
        ],
        absentPaths: [
          ['output_config'],
        ],
      ),
      for (final id in effortIds)
        id: _OptionWireFacts(
          facts: [
            _WireFact(['thinking', 'type'], 'adaptive'),
            _WireFact(['output_config', 'effort'], id),
          ],
        ),
    };

/// Aggregator envelope effort.
Map<String, _OptionWireFacts> _aggregatorEffortWire(List<String> effortIds) => {
  for (final id in effortIds)
    id: _OptionWireFacts(
      facts: [
        _WireFact(['reasoning', 'enabled'], true),
        _WireFact(['reasoning', 'effort'], id),
      ],
    ),
};

/// Aggregator envelope budget: the documented positive budget arrives as
/// `max_tokens`, and every disable selection uses the documented
/// `reasoning.effort: "none"` envelope instead of an enabled zero budget.
Map<String, _OptionWireFacts> _aggregatorBudgetWire(
  Map<String, int> tierTokens,
) => {
  'off': const _OptionWireFacts(
    facts: [
      _WireFact(['reasoning', 'effort'], 'none'),
    ],
    absentPaths: [
      ['reasoning', 'enabled'],
      ['reasoning', 'max_tokens'],
    ],
  ),
  for (final entry in tierTokens.entries)
    entry.key: _OptionWireFacts(
      facts: [
        _WireFact(['reasoning', 'enabled'], true),
        _WireFact(['reasoning', 'max_tokens'], entry.value),
      ],
    ),
};

/// Aggregator envelope effort where `none` is the documented disable: it must
/// not keep a contradictory `enabled: true`.
Map<String, _OptionWireFacts> _aggregatorEffortWithNoneWire(
  List<String> effortIds,
) => {
  'none': const _OptionWireFacts(
    facts: [
      _WireFact(['reasoning', 'effort'], 'none'),
    ],
    absentPaths: [
      ['reasoning', 'enabled'],
    ],
  ),
  for (final id in effortIds)
    id: _OptionWireFacts(
      facts: [
        _WireFact(['reasoning', 'enabled'], true),
        _WireFact(['reasoning', 'effort'], id),
      ],
    ),
};

/// Native Ollama `think` field.
Map<String, _OptionWireFacts> _ollamaThinkWire(Map<String, Object> byOption) =>
    {
      for (final entry in byOption.entries)
        entry.key: _OptionWireFacts(
          facts: [
            _WireFact(['think'], entry.value),
          ],
        ),
    };

/// NIM hosted effort wire: the documented `reasoning_effort` field only. No
/// `thinking` envelope is documented for the hosted NIM catalog, so its absence
/// is asserted for every selection.
Map<String, _OptionWireFacts> _nimEffortWire(List<String> effortIds) => {
  for (final id in effortIds)
    id: _OptionWireFacts(
      facts: [
        _WireFact(['reasoning_effort'], id),
      ],
      absentPaths: [
        ['thinking'],
        ['chat_template_kwargs'],
      ],
    ),
};

/// NIM hosted template-kwargs Boolean toggle.
Map<String, _OptionWireFacts> _nimTemplateToggleWire(String key) => {
  'on': _OptionWireFacts(
    facts: [
      _WireFact(['chat_template_kwargs', key], true),
    ],
    absentPaths: [
      ['reasoning_effort'],
      ['thinking'],
    ],
  ),
  'off': _OptionWireFacts(
    facts: [
      _WireFact(['chat_template_kwargs', key], false),
    ],
    absentPaths: [
      ['reasoning_effort'],
      ['thinking'],
    ],
  ),
};

const _openAiTierTokens = {'low': 1024, 'medium': 8192, 'high': 24576};
const _anthropicTierTokens = {'low': 2048, 'medium': 8192, 'high': 16384};

class _MatrixRow {
  final String kind;
  final String protocol;
  final String modelId;
  final ThinkingCapabilityStatus expectedStatus;

  /// Independent expected descriptor kind from the documented control contract
  /// for this route and model (`null` where the documented contract advertises
  /// no control at all).
  final ThinkingControlKind? expectedKind;

  /// Independent expected descriptor default metadata, written from the
  /// documented contract: a producer-metadata fixture or an explicit
  /// declaration states its default, while `null` records that no default is
  /// documented for that route+model. It is never inferred from the first
  /// advertised option.
  final String? expectedDefaultOptionId;

  final Map<String, Object?> metadata;

  /// Independent expected body facts for every advertised selection id.
  final Map<String, _OptionWireFacts> wireFacts;
  final List<String> wireKeys;

  /// Container keys the route legitimately keeps on default omission because
  /// they carry no thinking-control value (e.g. the Responses `summary: auto`).
  final List<String> omissionToleratedKeys;

  /// Individual documented facts that legitimately survive default omission,
  /// such as the Responses `reasoning.summary = auto` display option which is
  /// not a thinking-control value.
  final List<List<String>> omissionRetainedPaths;

  const _MatrixRow({
    required this.kind,
    required this.protocol,
    required this.modelId,
    required this.expectedStatus,
    required this.expectedKind,
    required this.expectedDefaultOptionId,
    required this.wireKeys,
    this.wireFacts = const {},
    this.omissionToleratedKeys = const [],
    this.omissionRetainedPaths = const [],
    this.metadata = const {},
  });
}

void main() {
  late Directory tempHome;
  late AgentStateDatabase state;
  late ProviderInstanceRepository repo;
  late ThinkingCapabilityAssembler assembler;
  late ThinkingSelectionResolver resolver;
  late Config isolatedConfig;

  setUp(() {
    tempHome = Directory.systemTemp.createTempSync('sanad_kind_wire_home_');
    setSanadHomeOverride(tempHome.path);
    File(p.join(tempHome.path, 'config.yaml')).writeAsStringSync('''
model_capabilities:
  declared-chat-effort-fixture:
    thinking_control:
      status: supported
      wire: openai_chat_effort
      options:
        low: low
        high: high
  declared-toggle-fixture:
    thinking_control:
      status: supported
      wire: toggle_effort
      options:
        off: false
        on: true
  declared-anthropic-adaptive-fixture:
    thinking_control:
      status: supported
      wire: anthropic_adaptive
      options:
        off: false
        high: high
  declared-effort-vocabulary-fixture:
    thinking_control:
      status: supported
      wire: openai_chat_effort
      options:
        minimal: minimal
        max: max
      default_option: max
  declared-responses-vocabulary-fixture:
    thinking_control:
      status: supported
      wire: codex_responses_effort
      options:
        minimal: minimal
        max: max
      default_option: max
  declared-incompatible-fixture:
    thinking_control:
      status: supported
      wire: google_thinking
      options:
        high: high
''');

    state = AgentStateDatabase.inMemory();
    repo = ProviderInstanceRepository.fromDatabase(state.db);
    if (getIt.isRegistered<ProviderInstanceRepository>()) {
      getIt.unregister<ProviderInstanceRepository>();
    }
    getIt.registerSingleton<ProviderInstanceRepository>(repo);

    isolatedConfig = Config(environment: {'SANAD_HOME': tempHome.path});

    final registry = buildProviderThinkingRegistry();
    assembler = ThinkingCapabilityAssembler(registry, isolatedConfig);
    resolver = ThinkingSelectionResolver(
      instances: repo,
      cacheResolver: ThinkingControlCacheResolver(repo),
      assembler: assembler,
      registry: registry,
      config: isolatedConfig,
    );
  });

  tearDown(() {
    try {
      if (getIt.isRegistered<ProviderInstanceRepository>()) {
        getIt.unregister<ProviderInstanceRepository>();
      }
      setSanadHomeOverride(null);
      state.dispose();
    } finally {
      if (tempHome.existsSync()) {
        tempHome.deleteSync(recursive: true);
      }
    }
  });

  ProviderInstance instanceFor(_MatrixRow row) {
    final profile = ProviderRegistry.findByNameOrAlias(row.kind);
    final id = 'inst-${row.kind}-${row.modelId.hashCode.abs()}'.toLowerCase();
    final inst = ProviderInstance(
      id: id,
      templateId: profile?.name ?? row.kind,
      displayName: 'Matrix ${row.kind}',
      protocol: row.protocol,
      authMethod: ProviderAuthMethod.apiKey,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    repo.createInstance(inst);
    return inst;
  }

  Future<Map<String, dynamic>> dispatchBody({
    required _MatrixRow row,
    required ProviderInstance inst,
    required NativeThinkingDirective directive,
  }) async {
    final profile = ProviderRegistry.findByNameOrAlias(row.kind)!;
    Map<String, dynamic>? capturedBody;
    final client = MockClient((request) async {
      capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
      if (row.kind == 'ollama') {
        return http.Response(
          jsonEncode({
            'message': {'role': 'assistant', 'content': 'ok'},
            'done': true,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (profile.apiMode == 'codex_responses') {
        return http.Response(
          jsonEncode({
            'id': 'resp-1',
            'status': 'completed',
            'output': [
              {
                'type': 'message',
                'role': 'assistant',
                'content': [
                  {'type': 'text', 'text': 'ok'},
                ],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (row.protocol == ProviderProtocol.anthropicCompatible) {
        return http.Response(
          jsonEncode({
            'id': 'msg-1',
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'ok'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'id': 'chatcmpl-1',
          'choices': [
            {
              'message': {'role': 'assistant', 'content': 'ok'},
              'finish_reason': 'stop',
            },
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final config = isolatedConfig;

    // Mirrors AgentRuntimeService._buildAdapter adapter selection for the
    // route; the dispatch itself uses the shared LLMAdapter interface, so every
    // protocol distinction is preserved without duplicating the call.
    final LLMAdapter adapter =
        row.protocol == ProviderProtocol.anthropicCompatible
        ? BaseAnthropicAdapter(
            config,
            profile,
            providerInstanceId: inst.id,
            client: client,
            baseUrlOverride: 'https://matrix.invalid/v1',
            apiKeyOverride: 'test-key',
          )
        : profile.apiMode == 'codex_responses'
        ? CodexResponsesAdapter(
            config,
            profile,
            providerInstanceId: inst.id,
            client: client,
            baseUrlOverride: 'https://matrix.invalid/v1',
            apiKeyOverride: 'test-key',
          )
        : profile.apiMode == 'ollama'
        ? OllamaAdapter(
            config,
            profile,
            providerInstanceId: inst.id,
            client: client,
            baseUrlOverride: 'https://matrix.invalid',
            apiKeyOverride: 'test-key',
          )
        : BaseOpenAIAdapter(
            config,
            profile,
            providerInstanceId: inst.id,
            client: client,
            baseUrlOverride: 'https://matrix.invalid/v1',
            apiKeyOverride: 'test-key',
          );

    await adapter.generateResponse(
      [Message(role: MessageRole.user, content: 'matrix')],
      modelOverride: row.modelId,
      options: LLMRequestOptions(
        thinkingDirective: directive,
        providerInstanceId: inst.id,
        maxOutputTokens: 32000,
      ),
    );

    expect(
      capturedBody,
      isNotNull,
      reason: '${row.kind} / ${row.modelId} must dispatch exactly one request',
    );
    return capturedBody!;
  }

  Object? readPath(Map<String, dynamic> body, List<String> path) {
    Object? current = body;
    for (final key in path) {
      if (current is Map && current.containsKey(key)) {
        current = current[key];
      } else {
        return null;
      }
    }
    return current;
  }

  /// Asserts the independently expected body facts for one advertised
  /// selection: every documented path/value must match exactly and every
  /// documented absent path must be missing.
  void expectOptionWireFacts(
    Map<String, dynamic> body,
    _MatrixRow row,
    String selection,
  ) {
    final expected = row.wireFacts[selection];
    expect(
      expected,
      isNotNull,
      reason:
          '${row.kind} / ${row.modelId} advertises "$selection" without an '
          'independent expected wire fact',
    );
    final hasEffect = row.wireKeys.any(body.containsKey);
    expect(
      hasEffect,
      isTrue,
      reason:
          '${row.kind} / ${row.modelId} / $selection must change the real '
          '${row.wireKeys.join("/")} wire field, got keys: ${body.keys.toList()}',
    );
    for (final fact in expected!.facts) {
      expect(
        readPath(body, fact.path),
        fact.value,
        reason:
            '${row.kind} / ${row.modelId} / $selection expected '
            '${fact.path.join(".")}=${fact.value}',
      );
    }
    for (final absent in expected.absentPaths) {
      expect(
        readPath(body, absent),
        isNull,
        reason:
            '${row.kind} / ${row.modelId} / $selection must not emit '
            '${absent.join(".")}',
      );
    }
  }

  final rows = <_MatrixRow>[
    // ---- OpenAI Chat effort
    _MatrixRow(
      kind: 'openai',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'o3-mini',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: 'medium',
      wireFacts: _chatEffortWire(['low', 'medium', 'high']),
      wireKeys: _chatKeys,
    ),
    // ---- Codex Responses effort
    _MatrixRow(
      kind: 'openai-codex',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'gpt-5.2-codex',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: null,
      wireFacts: _responsesEffortWire(['low', 'medium', 'high', 'xhigh']),
      wireKeys: _responsesKeys,
      omissionToleratedKeys: const ['reasoning'],
      omissionRetainedPaths: const [
        ['reasoning', 'summary'],
      ],
    ),
    // ---- Anthropic Messages: adaptive + manual budget
    _MatrixRow(
      kind: 'anthropic',
      protocol: ProviderProtocol.anthropicCompatible,
      modelId: 'claude-opus-4-7',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.adaptive,
      expectedDefaultOptionId: null,
      wireFacts: _anthropicAdaptiveWire(['low', 'medium', 'high', 'max']),
      wireKeys: _messagesKeys,
    ),
    _MatrixRow(
      kind: 'anthropic',
      protocol: ProviderProtocol.anthropicCompatible,
      modelId: 'claude-3-7-sonnet',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.tokenBudget,
      expectedDefaultOptionId: null,
      wireFacts: _anthropicBudgetWire(_anthropicTierTokens),
      wireKeys: _messagesKeys,
    ),
    // ---- Gemini 2.5 budget family (grounded: disable only where documented)
    _MatrixRow(
      kind: 'gemini',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'gemini-2.5-flash',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.tokenBudget,
      expectedDefaultOptionId: null,
      wireFacts: _googleBudgetWire(
        tierTokens: _openAiTierTokens,
        supportsOff: true,
      ),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'gemini',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'gemini-2.5-pro',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.tokenBudget,
      expectedDefaultOptionId: null,
      wireFacts: _googleBudgetWire(
        tierTokens: _openAiTierTokens,
        supportsOff: false,
      ),
      wireKeys: _chatKeys,
    ),
    // ---- Gemini 3/4 level family (grounded per model)
    _MatrixRow(
      kind: 'gemini',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'gemini-3.8-flash',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.level,
      expectedDefaultOptionId: 'medium',
      wireFacts: _googleLevelWire(['low', 'medium', 'high']),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'gemini',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'gemini-4-argon',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.level,
      expectedDefaultOptionId: 'medium',
      wireFacts: _googleLevelWire(['low', 'medium', 'high']),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'gemini',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'gemini-3.6-flash',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.level,
      expectedDefaultOptionId: 'medium',
      wireFacts: _googleLevelWire(['minimal', 'low', 'medium', 'high']),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'gemini',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'gemini-3.5-flash-lite',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.level,
      expectedDefaultOptionId: 'minimal',
      wireFacts: _googleLevelWire(['minimal', 'low', 'medium', 'high']),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'gemini',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'gemini-3-flash-preview',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.level,
      expectedDefaultOptionId: 'high',
      wireFacts: _googleLevelWire(['minimal', 'low', 'medium', 'high']),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'gemini',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'gemini-3.1-pro-preview',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.level,
      expectedDefaultOptionId: 'high',
      wireFacts: _googleLevelWire(['low', 'medium', 'high']),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'gemini',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'gemini-3-pro-preview',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.level,
      expectedDefaultOptionId: 'high',
      wireFacts: _googleLevelWire(['low', 'high']),
      wireKeys: _chatKeys,
    ),
    // ---- DeepSeek toggle + toggle/effort
    _MatrixRow(
      kind: 'deepseek',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'deepseek-chat',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.toggle,
      expectedDefaultOptionId: 'on',
      wireFacts: _toggleWire(),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'deepseek',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'deepseek-v4-flash',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: 'high',
      wireFacts: _enabledToggleEffortWire(['low', 'high', 'max']),
      wireKeys: _chatKeys,
    ),
    // ---- Kimi effort + toggle
    _MatrixRow(
      kind: 'kimi',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'kimi-k3',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: 'max',
      wireFacts: _effortOnlyWire(['low', 'high', 'max']),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'kimi',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'kimi-k2.6',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.toggle,
      expectedDefaultOptionId: 'on',
      wireFacts: _toggleWire(),
      wireKeys: _chatKeys,
    ),
    // ---- Z.AI (and its coding route)
    _MatrixRow(
      kind: 'zai',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'glm-5.3',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: 'max',
      wireFacts: _forcedEffortWire(['low', 'high', 'max']),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'zai-coding',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'glm-4.5',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.toggle,
      expectedDefaultOptionId: null,
      wireFacts: _toggleWire(),
      wireKeys: _chatKeys,
    ),
    // ---- Canonical documented vocabulary on a declared Chat route
    _MatrixRow(
      kind: kCustomProviderTemplateId,
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'declared-effort-vocabulary-fixture',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: 'max',
      wireFacts: _chatEffortWire(['minimal', 'max']),
      wireKeys: _chatKeys,
    ),
    // ---- The same canonical values on the aggregator envelope
    _MatrixRow(
      kind: 'openrouter',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'declared-effort-vocabulary-fixture',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: 'max',
      wireFacts: _aggregatorEffortWire(['minimal', 'max']),
      wireKeys: _chatKeys,
    ),
    // ---- Canonical values on a declared Responses route
    _MatrixRow(
      kind: 'openai-codex',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'declared-responses-vocabulary-fixture',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: 'max',
      wireFacts: _responsesEffortWire(['minimal', 'max']),
      wireKeys: _responsesKeys,
      omissionToleratedKeys: const ['reasoning'],
      omissionRetainedPaths: const [
        ['reasoning', 'summary'],
      ],
    ),
    // ---- Aggregator serialization boundary
    _MatrixRow(
      kind: 'openrouter',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'openai/o3-mini',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: 'medium',
      wireFacts: _aggregatorEffortWire(['low', 'medium', 'high']),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'openrouter',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'openai/gpt-5.6-sol',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: 'medium',
      wireFacts: _aggregatorEffortWithNoneWire([
        'low',
        'medium',
        'high',
        'xhigh',
        'max',
      ]),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'openrouter',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'anthropic/claude-3.7-sonnet',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.tokenBudget,
      expectedDefaultOptionId: null,
      wireFacts: _aggregatorBudgetWire(_anthropicTierTokens),
      wireKeys: _chatKeys,
    ),
    // ---- Ollama native boolean declaration
    _MatrixRow(
      kind: 'ollama',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'gemma4:e2b',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.toggle,
      expectedDefaultOptionId: 'on',
      wireFacts: _ollamaThinkWire({'off': false, 'on': true}),
      wireKeys: _ollamaKeys,
      metadata: {
        'ollama_capabilities': ['completion', 'thinking'],
        'ollama_thinking': {
          'values': [false, true],
          'default': true,
        },
      },
    ),
    // ---- OpenCode Go exact model fact overrides generic host policy
    _MatrixRow(
      kind: 'opencode-go',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'deepseek-v4.1-flash',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: 'high',
      wireFacts: _enabledToggleEffortWire(['low', 'high', 'max']),
      wireKeys: _chatKeys,
    ),
    // ---- xAI: exact Grok facts on the documented Chat effort wire
    _MatrixRow(
      kind: 'xai',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'grok-4.5',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: 'high',
      wireFacts: _chatEffortWire(['low', 'medium', 'high']),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'xai',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'grok-4.7',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: 'high',
      wireFacts: _chatEffortWire(['low', 'medium', 'high', 'xhigh']),
      wireKeys: _chatKeys,
    ),
    // ---- NVIDIA NIM: documented `gpt-oss` adjustable reasoning effort
    _MatrixRow(
      kind: 'nvidia',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'openai/gpt-oss-120b',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: null,
      wireFacts: _chatEffortWire(['low', 'medium', 'high']),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'nvidia',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'openai/gpt-oss-20b',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: null,
      wireFacts: _chatEffortWire(['low', 'medium', 'high']),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'openai',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'gpt-oss-120b',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: null,
      wireFacts: _chatEffortWire(['low', 'medium', 'high']),
      wireKeys: _chatKeys,
    ),
    // ---- Same intrinsic `gpt-oss` facts across other compatible Chat kinds
    _MatrixRow(
      kind: 'lm-studio',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'openai/gpt-oss-20b',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: null,
      wireFacts: _chatEffortWire(['low', 'medium', 'high']),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'llama-cpp',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'gpt-oss-20b',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: null,
      wireFacts: _chatEffortWire(['low', 'medium', 'high']),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: kCustomProviderTemplateId,
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'gpt-oss-120b',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: null,
      wireFacts: _chatEffortWire(['low', 'medium', 'high']),
      wireKeys: _chatKeys,
    ),
    // ---- `gpt-oss` on an incompatible mode advertises nothing
    _MatrixRow(
      kind: kCustomProviderTemplateId,
      protocol: ProviderProtocol.anthropicCompatible,
      modelId: 'gpt-oss-120b',
      expectedStatus: ThinkingCapabilityStatus.unknown,
      expectedKind: null,
      expectedDefaultOptionId: null,
      wireFacts: _chatEffortWire(['low', 'medium', 'high']),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'openai-codex',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'gpt-oss-120b',
      expectedStatus: ThinkingCapabilityStatus.unsupported,
      expectedKind: null,
      expectedDefaultOptionId: null,
      wireFacts: const {},
      wireKeys: _responsesKeys,
      omissionToleratedKeys: const ['reasoning'],
    ),
    // ---- Custom route: model-only exact fact on the actual Chat mode
    // Carrier (custom) route: only the documented standard effort ladder is
    // evidenced here; the family's native envelope and disable are not.
    _MatrixRow(
      kind: kCustomProviderTemplateId,
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'deepseek-v4-flash',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: null,
      wireFacts: {
        for (final id in ['low', 'high', 'max'])
          id: _OptionWireFacts(
            facts: [
              _WireFact(['reasoning_effort'], id),
            ],
            absentPaths: [
              ['thinking'],
            ],
          ),
      },
      wireKeys: _chatKeys,
    ),
    // ---- Custom route: model-only declared override (Chat)
    _MatrixRow(
      kind: kCustomProviderTemplateId,
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'declared-chat-effort-fixture',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: null,
      wireFacts: _chatEffortWire(['low', 'high']),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: kCustomProviderTemplateId,
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'declared-toggle-fixture',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.toggle,
      expectedDefaultOptionId: null,
      wireFacts: _toggleWire(),
      wireKeys: _chatKeys,
    ),
    // ---- Custom route: model-only declared override (Messages mode)
    _MatrixRow(
      kind: kCustomProviderTemplateId,
      protocol: ProviderProtocol.anthropicCompatible,
      modelId: 'declared-anthropic-adaptive-fixture',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.adaptive,
      expectedDefaultOptionId: null,
      wireFacts: _anthropicAdaptiveWire(['high']),
      wireKeys: _messagesKeys,
    ),
    _MatrixRow(
      kind: kCustomProviderTemplateId,
      protocol: ProviderProtocol.anthropicCompatible,
      modelId: 'claude-haiku-4.5',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.tokenBudget,
      expectedDefaultOptionId: null,
      wireFacts: _anthropicBudgetWire(_anthropicTierTokens),
      wireKeys: _messagesKeys,
    ),
    // ---- Genuinely unknown model on a custom route stays unknown
    _MatrixRow(
      kind: kCustomProviderTemplateId,
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'unconfigured-unknown-model',
      expectedStatus: ThinkingCapabilityStatus.unknown,
      expectedKind: null,
      expectedDefaultOptionId: null,
      wireFacts: const {},
      wireKeys: _chatKeys,
    ),
    // ---- Hosted NVIDIA NIM catalog: exact documented per-model contracts
    _MatrixRow(
      kind: 'nvidia',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'deepseek-ai/deepseek-v4-flash',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: 'high',
      wireFacts: _nimEffortWire(['none', 'high', 'max']),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'nvidia',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'deepseek-ai/deepseek-v4-pro',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: 'high',
      wireFacts: _nimEffortWire(['none', 'high', 'max']),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'nvidia',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'moonshotai/kimi-k3',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: 'max',
      wireFacts: _nimEffortWire(['low', 'high', 'max']),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'nvidia',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'moonshotai/kimi-k2.6',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.toggle,
      expectedDefaultOptionId: null,
      wireFacts: _nimTemplateToggleWire('thinking'),
      wireKeys: _chatKeys,
    ),
    _MatrixRow(
      kind: 'nvidia',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'qwen/qwen3.5-122b-a10b',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.toggle,
      expectedDefaultOptionId: null,
      wireFacts: _nimTemplateToggleWire('enable_thinking'),
      wireKeys: _chatKeys,
    ),
    // ---- Second/third exact model families on unknown-policy kinds
    _MatrixRow(
      kind: 'xai',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'kimi-k3',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: null,
      wireFacts: _effortOnlyWire(['low', 'high', 'max']),
      wireKeys: _chatKeys,
    ),
    // Carrier (local) route hosting a ZAI model: the family's only documented
    // control is its native envelope, which this wire does not evidence.
    _MatrixRow(
      kind: 'llama-cpp',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'glm-4.5',
      expectedStatus: ThinkingCapabilityStatus.unknown,
      expectedKind: null,
      expectedDefaultOptionId: null,
      wireKeys: _chatKeys,
    ),
    // ---- Ollama level declaration keeps native string levels
    _MatrixRow(
      kind: 'ollama',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'level-capable-local',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.effort,
      expectedDefaultOptionId: 'medium',
      wireFacts: _ollamaThinkWire({
        'off': 'off',
        'low': 'low',
        'medium': 'medium',
        'high': 'high',
      }),
      wireKeys: _ollamaKeys,
      metadata: {
        'ollama_capabilities': ['completion', 'thinking'],
        'ollama_thinking': {
          'values': ['off', 'low', 'medium', 'high'],
          'default': 'medium',
        },
      },
    ),
    // ---- Aggregator delegates the grounded Google namespace exactly
    _MatrixRow(
      kind: 'openrouter',
      protocol: ProviderProtocol.openaiCompatible,
      modelId: 'google/gemini-2.5-flash',
      expectedStatus: ThinkingCapabilityStatus.supported,
      expectedKind: ThinkingControlKind.tokenBudget,
      expectedDefaultOptionId: null,
      wireFacts: _aggregatorBudgetWire(_openAiTierTokens),
      wireKeys: _chatKeys,
    ),
    // ---- Declaration incompatible with the actual API mode is rejected
    _MatrixRow(
      kind: kCustomProviderTemplateId,
      protocol: ProviderProtocol.anthropicCompatible,
      modelId: 'declared-incompatible-fixture',
      expectedStatus: ThinkingCapabilityStatus.unsupported,
      expectedKind: null,
      expectedDefaultOptionId: null,
      wireFacts: const {},
      wireKeys: _messagesKeys,
    ),
  ];

  group('Registry-derived per-kind thinking wire matrix', () {
    for (final row in rows) {
      test('${row.kind} / ${row.modelId} (${row.protocol}): descriptor, '
          'advertised options and real wire body agree', () async {
        final inst = instanceFor(row);
        final model = ModelOption(
          value: row.modelId,
          label: row.modelId,
          modelMetadata: row.metadata,
        );
        // Production shape: discovery enriches the descriptor and the
        // enriched model is what the route cache and resolver read back.
        final enriched = assembler.enrich(instance: inst, model: model);
        repo.upsertModelCache(
          instanceId: inst.id,
          cacheKey: 'models',
          models: [enriched.toJson()],
          fetchedAt: DateTime.now(),
          source: 'live',
          configRevision: inst.configRevision,
          credentialRevision: inst.credentialRevision,
        );
        final descriptor = enriched.thinkingControl!;
        expect(
          descriptor.status,
          row.expectedStatus,
          reason:
              '${row.kind} / ${row.modelId} descriptor status '
              '(source: ${descriptor.source})',
        );
        expect(
          descriptor.kind,
          row.expectedKind,
          reason: '${row.kind} / ${row.modelId} documented control kind',
        );
        expect(
          descriptor.defaultOptionId,
          row.expectedDefaultOptionId,
          reason:
              '${row.kind} / ${row.modelId} documented default metadata '
              '(never inferred from the first advertised option)',
        );

        if (descriptor.status != ThinkingCapabilityStatus.supported) {
          // Unsupported/unknown advertises no selectable control and must
          // never reach the wire as a fabricated native parameter.
          expect(descriptor.options, isEmpty);
          final omitted = resolver.resolve(
            providerInstanceId: inst.id,
            modelId: row.modelId,
            selectionId: null,
          );
          expect(omitted.directive, isA<UseProviderDefault>());
          final body = await dispatchBody(
            row: row,
            inst: inst,
            directive: omitted.directive,
          );
          for (final key in row.wireKeys) {
            if (row.omissionToleratedKeys.contains(key)) continue;
            expect(
              body.containsKey(key),
              isFalse,
              reason:
                  '${row.kind} / ${row.modelId} must not emit $key without '
                  'an authoritative capability',
            );
          }
          for (final optionFacts in row.wireFacts.values) {
            for (final fact in optionFacts.facts) {
              expect(
                readPath(body, fact.path),
                isNull,
                reason:
                    '${row.kind} / ${row.modelId} must not emit '
                    '${fact.path.join(".")} without an authoritative '
                    'capability',
              );
            }
          }
          return;
        }

        expect(
          descriptor.options,
          isNotEmpty,
          reason:
              '${row.kind} / ${row.modelId} supported must advertise a '
              'finite option set',
        );
        if (descriptor.defaultOptionId != null) {
          expect(
            descriptor.options.map((o) => o.id),
            contains(descriptor.defaultOptionId),
            reason: 'declared default must be a real advertised option',
          );
        }

        // The advertised option set must match the independently written
        // expectation set exactly, so neither a missing nor an extra
        // advertised option can pass unnoticed.
        expect(
          descriptor.options.map((option) => option.id).toSet(),
          row.wireFacts.keys.toSet(),
          reason:
              '${row.kind} / ${row.modelId} advertised options must match the '
              'independent expectation set',
        );

        // Every advertised option must be selectable, must change the wire and
        // must carry its exact independently documented semantic value.
        for (final option in descriptor.options) {
          final resolution = resolver.resolve(
            providerInstanceId: inst.id,
            modelId: row.modelId,
            selectionId: option.id,
          );
          expect(
            resolution.directive,
            isNot(isA<UseProviderDefault>()),
            reason:
                '${row.kind} / ${row.modelId} advertises "${option.id}" in '
                'the composer but resolves to provider default',
          );
          final body = await dispatchBody(
            row: row,
            inst: inst,
            directive: resolution.directive,
          );
          expectOptionWireFacts(body, row, option.id);
        }

        // Default omission never fabricates a native parameter.
        final omitted = resolver.resolve(
          providerInstanceId: inst.id,
          modelId: row.modelId,
          selectionId: null,
        );
        expect(omitted.directive, isA<UseProviderDefault>());
        final omittedBody = await dispatchBody(
          row: row,
          inst: inst,
          directive: omitted.directive,
        );
        for (final key in row.wireKeys) {
          if (row.omissionToleratedKeys.contains(key)) continue;
          expect(
            omittedBody.containsKey(key),
            isFalse,
            reason:
                '${row.kind} / ${row.modelId} default omission must not emit '
                '$key',
          );
        }
        for (final optionFacts in row.wireFacts.values) {
          for (final fact in optionFacts.facts) {
            if (row.omissionRetainedPaths.any(
              (path) => path.join('.') == fact.path.join('.'),
            )) {
              continue;
            }
            expect(
              readPath(omittedBody, fact.path),
              isNull,
              reason:
                  '${row.kind} / ${row.modelId} default omission must not '
                  'emit ${fact.path.join(".")}',
            );
          }
        }

        // A selection outside the advertised set is rejected, never clamped.
        expect(
          () => resolver.resolve(
            providerInstanceId: inst.id,
            modelId: row.modelId,
            selectionId: 'not-an-advertised-option',
          ),
          throwsA(isA<ThinkingSelectionException>()),
          reason: 'unknown option must be rejected before dispatch',
        );
      });
    }
  });

  group('Exact model identity: unverified names never acquire controls', () {
    // Route-scoped negatives: a name can only acquire intrinsic controls on the
    // routes whose policy actually consults that model family.
    const geminiNegatives = <String>[
      'gemini-3-pro-preview-fake',
      'gemini-3-ultra-beta',
      'gemini-3.6-flash-fake',
      'GEMINI-3-PRO-PREVIEW',
      'gemini-2.5',
      'gemini-2.5_flash',
      'models/gemini-3.6-flash',
      'untrusted/gemini-3-pro-preview',
      // Ids without an obtained per-model finite set/default must stay
      // unresolved instead of inheriting a neighbouring model's tiers.
      'gemini-3-flash',
      'gemini-3.1-flash',
      'gemini-pro-latest',
      'gemini-3.8-pro',
      'gemini-2.5-pro-thinking',
      'gemini-3.1-flash-lite',
      'gemini-3.5-flash',
      'gemini-3.6-flash-lite',
    ];
    const aggregatorNegatives = <String>[
      'google/gemini-3-pro-preview-fake',
      'google/gemini-3-ultra-beta',
      'google/GEMINI-2.5-FLASH',
      'google/gemini-pro-latest',
      'google/gemini-3-flash',
    ];
    const xaiNegatives = <String>[
      'grok-4.5-mini',
      'GROK-4.5',
      'xai/grok-4.5',
      'grok-4.5-thinking',
      'grok-4.20-0309-reasoning',
      'grok-4.20-0309-non-reasoning',
      'grok-4.3',
      'grok-4',
    ];
    const nimNegatives = <String>[
      // Hosted pages document no request-time control for these exact ids.
      'deepseek-ai/deepseek-v4.1-flash',
      'moonshotai/kimi-k2-thinking',
      'qwen/qwen3-next-80b-a3b-thinking',
      // Self-hosted-only id: never advertised from hosted availability or from
      // a generic Chat route without an explicit declaration.
      'qwen/qwen3.8-27b',
      // Bare/other-transport ids are not hosted NIM facts.
      'deepseek-v4-flash',
      'kimi-k3',
      'kimi-k2.6',
      'qwen/qwen3.5-122b-a10b-thinking',
      'DEEPSEEK-AI/DEEPSEEK-V4-FLASH',
    ];

    const gptOssNearMissNegatives = <String>[
      'gpt-oss',
      'gpt-oss-120b-turbo',
      'GPT-OSS-120B',
      'openai/gpt-oss-120b-turbo',
      'gpt-oss-20b-fake',
    ];
    const customRouteNegatives = <String>[
      'untrusted/o3-mini',
      'O3-MINI',
      'gpt-6-astra-thinking',
      'untrusted/kimi-k3',
      'moonshotai/kimi-k3',
      'KIMI-K2.6',
      'untrusted/glm-5.3',
      'GLM-5.3',
      'untrusted/deepseek-v4.1-flash',
      'untrusted/gemini-3-pro-preview',
    ];

    ProviderInstance instanceForTemplate(String templateId) {
      final inst = ProviderInstance(
        id: 'inst-neg-$templateId',
        templateId: templateId,
        displayName: 'Negative $templateId',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      repo.createInstance(inst);
      return inst;
    }

    void expectUnknownOnRoute({
      required String templateId,
      required String modelId,
    }) {
      final inst = instanceForTemplate(templateId);
      final descriptor = assembler.assemble(
        instance: inst,
        model: ModelOption(value: modelId, label: modelId),
      );
      expect(
        descriptor.status,
        ThinkingCapabilityStatus.unknown,
        reason:
            '$modelId must not acquire intrinsic thinking controls on $templateId',
      );
      expect(descriptor.options, isEmpty);
      expect(
        () => resolver.resolve(
          providerInstanceId: inst.id,
          modelId: modelId,
          selectionId: 'high',
        ),
        throwsA(
          isA<ThinkingSelectionException>().having(
            (e) => e.code,
            'code',
            ThinkingSelectionErrorCode.capabilityUnknown,
          ),
        ),
      );
    }

    for (final modelId in geminiNegatives) {
      test('gemini / $modelId stays unknown', () {
        expectUnknownOnRoute(templateId: 'gemini', modelId: modelId);
      });
    }
    for (final modelId in aggregatorNegatives) {
      test('openrouter / $modelId stays unknown', () {
        expectUnknownOnRoute(templateId: 'openrouter', modelId: modelId);
      });
    }
    for (final modelId in xaiNegatives) {
      test('xai / $modelId stays unknown', () {
        expectUnknownOnRoute(templateId: 'xai', modelId: modelId);
      });
    }
    for (final modelId in ['qwen/qwen3.8-27b']) {
      test(
        'custom / $modelId stays unknown without an explicit declaration',
        () {
          expectUnknownOnRoute(
            templateId: kCustomProviderTemplateId,
            modelId: modelId,
          );
        },
      );
    }
    for (final modelId in gptOssNearMissNegatives) {
      test('nvidia / $modelId stays unknown', () {
        expectUnknownOnRoute(templateId: 'nvidia', modelId: modelId);
      });
    }
    for (final modelId in nimNegatives) {
      test('nvidia / $modelId stays unknown', () {
        expectUnknownOnRoute(templateId: 'nvidia', modelId: modelId);
      });
    }
    for (final modelId in customRouteNegatives) {
      test('custom / $modelId stays unknown', () {
        expectUnknownOnRoute(
          templateId: kCustomProviderTemplateId,
          modelId: modelId,
        );
      });
    }

    test(
      'grounded Gemini ids expose their own finite set and default',
      () async {
        final inst = instanceForTemplate('gemini');

        // Per-model documented finite sets (no shared family set).
        const expectedLevels = <String, List<String>>{
          'gemini-3.8-flash': ['low', 'medium', 'high'],
          'gemini-4-argon': ['low', 'medium', 'high'],
          'gemini-3.6-flash': ['minimal', 'low', 'medium', 'high'],
          'gemini-3.5-flash-lite': ['minimal', 'low', 'medium', 'high'],
          'gemini-3-flash-preview': ['minimal', 'low', 'medium', 'high'],
          'gemini-3.1-pro-preview': ['low', 'medium', 'high'],
          'gemini-3-pro-preview': ['low', 'high'],
        };
        for (final entry in expectedLevels.entries) {
          expect(
            GoogleModelCatalog.levelOptionIdsForModel(entry.key),
            entry.value,
            reason: '${entry.key} must expose exactly its documented levels',
          );
        }

        // Per-model documented defaults.
        final expectedDefaults = <String, String?>{
          'gemini-3.8-flash': 'medium',
          'gemini-4-argon': 'medium',
          'gemini-3.6-flash': 'medium',
          'gemini-3.5-flash-lite': 'minimal',
          'gemini-3-flash-preview': 'high',
          'gemini-3.1-pro-preview': 'high',
          'gemini-3-pro-preview': 'high',
        };
        for (final entry in expectedDefaults.entries) {
          final descriptor = assembler.assemble(
            instance: inst,
            model: ModelOption(value: entry.key, label: entry.key),
          );
          expect(
            descriptor.defaultOptionId,
            entry.value,
            reason: '${entry.key} documented default',
          );
        }

        final grounded = <String, ThinkingControlKind>{
          'gemini-2.5-flash': ThinkingControlKind.tokenBudget,
          'gemini-2.5-pro': ThinkingControlKind.tokenBudget,
          'gemini-3.8-flash': ThinkingControlKind.level,
          'gemini-4-argon': ThinkingControlKind.level,
          'gemini-3.6-flash': ThinkingControlKind.level,
          'gemini-3.5-flash-lite': ThinkingControlKind.level,
          'gemini-3-flash-preview': ThinkingControlKind.level,
          'gemini-3.1-pro-preview': ThinkingControlKind.level,
          'gemini-3-pro-preview': ThinkingControlKind.level,
          'google/gemini-3.8-flash': ThinkingControlKind.level,
          'google/gemini-2.5-flash': ThinkingControlKind.tokenBudget,
        };
        for (final entry in grounded.entries) {
          final descriptor = assembler.assemble(
            instance: inst,
            model: ModelOption(value: entry.key, label: entry.key),
          );
          expect(
            descriptor.status,
            ThinkingCapabilityStatus.supported,
            reason: '${entry.key} is a grounded Gemini id',
          );
          expect(descriptor.kind, entry.value);
        }

        // Gemini 2.5 models keep a model-managed dynamic default by omission.
        for (final modelId in ['gemini-2.5-flash', 'gemini-2.5-pro']) {
          expect(
            assembler
                .assemble(
                  instance: inst,
                  model: ModelOption(value: modelId, label: modelId),
                )
                .defaultOptionId,
            isNull,
          );
        }

        // Off is only advertised where Google documents an explicit disable, and
        // Gemini 3/4 cannot be turned off at all.
        expect(GoogleModelCatalog.budgetOptionIdsForModel('gemini-2.5-flash'), [
          'off',
          'low',
          'medium',
          'high',
        ]);
        expect(GoogleModelCatalog.budgetOptionIdsForModel('gemini-2.5-pro'), [
          'low',
          'medium',
          'high',
        ]);
        for (final modelId in expectedLevels.keys) {
          final descriptor = assembler.assemble(
            instance: inst,
            model: ModelOption(value: modelId, label: modelId),
          );
          expect(
            descriptor.options.any((o) => o.isOff),
            isFalse,
            reason: '$modelId must never advertise Off',
          );
        }

        // Gemini 3 Pro preview documents Low/High only: `medium` is rejected.
        expect(
          () => resolver.resolve(
            providerInstanceId: inst.id,
            modelId: 'gemini-3-pro-preview',
            selectionId: 'medium',
          ),
          throwsA(
            isA<ThinkingSelectionException>().having(
              (e) => e.code,
              'code',
              ThinkingSelectionErrorCode.optionUnavailable,
            ),
          ),
        );
        // Gemini 3.8 Flash does not advertise `minimal`, so a stored legacy
        // `minimal` selection migrates to its legacy `low` alias instead of
        // reaching the wire as an unsupported native level.
        final legacyMinimal = resolver.resolve(
          providerInstanceId: inst.id,
          modelId: 'gemini-3.8-flash',
          selectionId: 'minimal',
        );
        expect((legacyMinimal.directive as GoogleLevelDirective).level, 'low');
        // The documented `minimal` identity stays an exact, unremapped option.
        final minimalResolution = resolver.resolve(
          providerInstanceId: inst.id,
          modelId: 'gemini-3.6-flash',
          selectionId: 'minimal',
        );
        expect(
          (minimalResolution.directive as GoogleLevelDirective).level,
          'minimal',
        );

        // Non-thinking legacy models stay explicitly unsupported.
        expect(
          GoogleModelCatalog.thinkingKindForModel('gemini-1.5-pro'),
          GoogleRouteThinkingKind.unsupported,
        );
      },
    );

    test('exact xAI Grok facts advertise documented effort only', () {
      final inst = instanceForTemplate('xai');

      final grok45 = assembler.assemble(
        instance: inst,
        model: ModelOption(value: 'grok-4.5', label: 'Grok 4.5'),
      );
      expect(grok45.status, ThinkingCapabilityStatus.supported);
      expect(grok45.options.map((o) => o.id), ['low', 'medium', 'high']);
      expect(grok45.defaultOptionId, 'high');
      expect(grok45.options.any((o) => o.isOff), isFalse);

      final grok47 = assembler.assemble(
        instance: inst,
        model: ModelOption(value: 'grok-4.7', label: 'Grok 4.7'),
      );
      expect(grok47.options.map((o) => o.id), [
        'low',
        'medium',
        'high',
        'xhigh',
      ]);
      expect(
        XaiModelCatalog.allowsEffortId(modelId: 'grok-4.5', effortId: 'xhigh'),
        isFalse,
        reason: 'xhigh maps to high before grok-4.6 and must not be advertised',
      );
      expect(
        XaiModelCatalog.supportsExplicitDisable,
        isFalse,
        reason: 'xAI documents that reasoning cannot be disabled',
      );
    });
  });

  test('every shipped kind appears in the matrix', () {
    final covered = rows.map((row) => row.kind).toSet();
    expect(
      covered,
      equals(ProviderRegistry.profiles.map((p) => p.name).toSet()),
      reason: 'each registered provider kind must have a real-wire row',
    );
  });
}
