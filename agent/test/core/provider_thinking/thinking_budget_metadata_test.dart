/// Bounded regression coverage for truthful budget metadata and honest
/// explicit-budget dispatch.
///
/// Scope, matching the approved closure decisions:
/// * a token-budget option discloses the exact positive token count the route
///   resolves for it, from the owning catalog's own budget authority;
/// * Off, effort/level/toggle options, and unknown counts disclose nothing;
/// * an omitted/null selection stays provider default by omission even when the
///   descriptor publishes native default metadata;
/// * an explicitly selected budget reaches the wire unchanged, and a request
///   that cannot honour it fails actionably instead of silently sending a
///   smaller value.
library;

import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_thinking/anthropic_thinking_policy.dart';
import 'package:sanad_agent/core/provider_thinking/anthropic_thinking_wire_codec.dart';
import 'package:sanad_agent/core/provider_thinking/google_thinking_policy.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_policy_context.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_wire_vocabulary.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

ThinkingPolicyContext _context(String modelId, {String apiMode = 'messages'}) =>
    ThinkingPolicyContext(
      providerInstanceId: 'instance-1',
      templateId: 'anthropic',
      protocol: ProviderProtocol.anthropicCompatible,
      apiMode: apiMode,
      modelId: modelId,
      capabilityRevision: 'rev-1',
    );

int? _budgetOf(ThinkingControlDescriptor descriptor, String id) =>
    descriptor.options.firstWhere((option) => option.id == id).budgetTokens;

void main() {
  group('ThinkingControlOption budget_tokens serialization', () {
    test('round-trips a positive budget and keeps it off non-budget options', () {
      const withBudget = ThinkingControlOption(
        id: 'medium',
        label: 'Medium',
        budgetTokens: 8192,
      );
      const withoutBudget = ThinkingControlOption(
        id: 'off',
        label: 'Off',
        isOff: true,
      );

      expect(withBudget.toMap()['budget_tokens'], equals(8192));
      expect(withoutBudget.toMap().containsKey('budget_tokens'), isFalse);

      expect(
        ThinkingControlOption.fromMap(withBudget.toMap()).budgetTokens,
        equals(8192),
      );
      expect(
        ThinkingControlOption.fromMap(withoutBudget.toMap()).budgetTokens,
        isNull,
      );
    });

    test('never carries a non-positive or malformed count', () {
      const zero = ThinkingControlOption(
        id: 'zero',
        label: 'Zero',
        budgetTokens: 0,
      );
      const negative = ThinkingControlOption(
        id: 'negative',
        label: 'Negative',
        budgetTokens: -1,
      );

      expect(zero.toMap().containsKey('budget_tokens'), isFalse);
      expect(negative.toMap().containsKey('budget_tokens'), isFalse);

      expect(
        ThinkingControlOption.fromMap({
          'id': 'bad',
          'label': 'Bad',
          'budget_tokens': 0,
        }).budgetTokens,
        isNull,
      );
      expect(
        ThinkingControlOption.fromMap({
          'id': 'bad',
          'label': 'Bad',
          'budget_tokens': 'not_a_number',
        }).budgetTokens,
        isNull,
      );
    });

    for (final malformed in <Object>[
      8192.5,
      0.5,
      double.infinity,
      double.negativeInfinity,
      double.nan,
    ]) {
      test('treats the unusable count $malformed as unavailable', () {
        expect(
          ThinkingControlOption.fromMap({
            'id': 'bad',
            'label': 'Bad',
            'budget_tokens': malformed,
          }).budgetTokens,
          isNull,
          reason:
              '$malformed is neither a whole positive token count nor '
              'dispatchable, so it must not become one',
        );
      });
    }

    test('keeps a whole count that arrives as a double', () {
      expect(
        ThinkingControlOption.fromMap({
          'id': 'whole',
          'label': 'Whole',
          'budget_tokens': 8192.0,
        }).budgetTokens,
        equals(8192),
      );
    });

    test('descriptor round-trip preserves budget metadata and native default', () {
      const descriptor = ThinkingControlDescriptor(
        status: ThinkingCapabilityStatus.supported,
        kind: ThinkingControlKind.tokenBudget,
        options: [
          ThinkingControlOption(id: 'off', label: 'Off', isOff: true),
          ThinkingControlOption(
            id: 'medium',
            label: 'Medium',
            isProviderDefault: true,
            budgetTokens: 8192,
          ),
        ],
        defaultOptionId: 'medium',
        capabilityRevision: 'rev-1',
        source: 'profile',
      );

      final restored = ThinkingControlDescriptor.fromMap(descriptor.toMap());

      expect(restored.defaultOptionId, equals('medium'));
      expect(_budgetOf(restored, 'off'), isNull);
      expect(_budgetOf(restored, 'medium'), equals(8192));
      expect(
        restored.options.firstWhere((o) => o.id == 'medium').isProviderDefault,
        isTrue,
      );
    });
  });

  group('Anthropic descriptor budget metadata', () {
    const policy = AnthropicThinkingPolicy();

    test('manual budget options disclose the exact catalog token counts', () {
      final descriptor = policy.resolveCapability(
        _context('claude-sonnet-4-5'),
      );

      expect(descriptor.status, ThinkingCapabilityStatus.supported);
      expect(descriptor.kind, ThinkingControlKind.tokenBudget);
      expect(_budgetOf(descriptor, 'off'), isNull);
      expect(_budgetOf(descriptor, 'low'), equals(2048));
      expect(_budgetOf(descriptor, 'medium'), equals(8192));
      expect(_budgetOf(descriptor, 'high'), equals(16384));
    });

    test('adaptive options carry no token budget', () {
      final descriptor = policy.resolveCapability(_context('claude-opus-4-7'));

      expect(descriptor.kind, ThinkingControlKind.adaptive);
      expect(descriptor.options, isNotEmpty);
      expect(
        descriptor.options.every((option) => option.budgetTokens == null),
        isTrue,
      );
    });

    test('an omitted selection stays provider default by omission', () {
      for (final omitted in <String?>[null, '', '   ']) {
        expect(
          policy.resolveDirective(_context('claude-sonnet-4-5'), omitted),
          isA<UseProviderDefault>(),
        );
      }
      expect(
        policy.resolveDirective(_context('claude-sonnet-4-5'), 'high'),
        isA<AnthropicBudgetDirective>(),
      );
    });
  });

  group('Google descriptor budget metadata', () {
    const policy = GoogleThinkingPolicy();

    test('budget models disclose exact counts and Off stays a non-budget', () {
      final descriptor = policy.resolveCapability(_context('gemini-2.5-flash'));

      expect(descriptor.kind, ThinkingControlKind.tokenBudget);
      final off = descriptor.options.firstWhere((option) => option.id == 'off');
      expect(off.isOff, isTrue);
      expect(off.budgetTokens, isNull);
      expect(_budgetOf(descriptor, 'low'), equals(1024));
      expect(_budgetOf(descriptor, 'medium'), equals(8192));
      expect(_budgetOf(descriptor, 'high'), equals(24576));
    });

    test('always-on budget models expose no Off option', () {
      final descriptor = policy.resolveCapability(_context('gemini-2.5-pro'));

      expect(descriptor.kind, ThinkingControlKind.tokenBudget);
      expect(
        descriptor.options.any((option) => option.isOff),
        isFalse,
      );
      expect(_budgetOf(descriptor, 'high'), equals(24576));
    });

    test('level models carry no token budget on any option', () {
      final descriptor = policy.resolveCapability(_context('gemini-4-argon'));

      expect(descriptor.kind, ThinkingControlKind.level);
      expect(descriptor.options, isNotEmpty);
      expect(
        descriptor.options.every((option) => option.budgetTokens == null),
        isTrue,
      );
    });
  });

  group('Declared endpoint budget metadata', () {
    ProviderInstance customAnthropicInstance() => ProviderInstance(
      id: 'inst-custom-anthropic',
      templateId: kCustomProviderTemplateId,
      displayName: 'Custom Anthropic',
      protocol: ProviderProtocol.anthropicCompatible,
      authMethod: ProviderAuthMethod.apiKey,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );

    ProviderInstance customGoogleInstance() => ProviderInstance(
      id: 'inst-custom-google',
      templateId: kCustomProviderTemplateId,
      displayName: 'Custom Google',
      protocol: ProviderProtocol.openaiCompatible,
      authMethod: ProviderAuthMethod.apiKey,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );

    test('declared budget values become budget metadata', () {
      final assembler = ThinkingCapabilityAssembler(
        buildProviderThinkingRegistry(),
      );
      final descriptor = assembler.assemble(
        instance: customAnthropicInstance(),
        model: ModelOption(
          value: 'claude-custom',
          label: 'Claude Custom',
          modelMetadata: const {
            'thinking_control': {
              'status': 'supported',
              'wire': 'anthropic_budget',
              'options': {'tier_min': 2048, 'tier_max': 8192},
              'default_option': 'tier_min',
            },
          },
        ),
      );

      expect(descriptor.status, ThinkingCapabilityStatus.supported);
      expect(descriptor.kind, ThinkingControlKind.tokenBudget);
      expect(_budgetOf(descriptor, 'tier_min'), equals(2048));
      expect(_budgetOf(descriptor, 'tier_max'), equals(8192));
      // Native default stays descriptor metadata; it is not an emitted value.
      expect(descriptor.defaultOptionId, equals('tier_min'));
    });

    test('a malformed declared budget fails the declaration closed', () {
      final assembler = ThinkingCapabilityAssembler(
        buildProviderThinkingRegistry(),
      );
      final descriptor = assembler.assemble(
        instance: customAnthropicInstance(),
        model: ModelOption(
          value: 'claude-invalid-budget',
          label: 'Claude Invalid Budget',
          modelMetadata: const {
            'thinking_control': {
              'status': 'supported',
              'wire': 'anthropic_budget',
              'options': {'invented': 'not_a_number', 'too_small': 500},
            },
          },
        ),
      );

      // No fabricated budget is advertised from an invalid declaration, and
      // no option carries an invented token count.
      expect(descriptor.options, isEmpty);
      expect(
        descriptor.status,
        isNot(ThinkingCapabilityStatus.supported),
      );
    });

    test('declared Google budgets carry counts while levels and Off do not', () {
      final assembler = ThinkingCapabilityAssembler(
        buildProviderThinkingRegistry(),
      );
      final descriptor = assembler.assemble(
        instance: customGoogleInstance(),
        model: ModelOption(
          value: 'gemini-custom',
          label: 'Gemini Custom',
          modelMetadata: const {
            'thinking_control': {
              'status': 'supported',
              'wire': 'google_thinking',
              'options': {'off': 0, 'low': 'low', 'budget': 4096},
            },
          },
        ),
      );

      expect(descriptor.status, ThinkingCapabilityStatus.supported);
      expect(_budgetOf(descriptor, 'budget'), equals(4096));
      expect(_budgetOf(descriptor, 'off'), isNull);
      expect(_budgetOf(descriptor, 'low'), isNull);
    });
  });

  group('Explicit budget dispatch is exact or rejected', () {
    test('a feasible explicit budget reaches the wire unchanged', () {
      final body = <String, dynamic>{
        'model': 'claude-sonnet-4-5',
        'max_tokens': 16384,
      };

      AnthropicThinkingWireCodec.applyThinking(
        body,
        const AnthropicBudgetDirective(16384 - 1),
      );

      expect(body['thinking'], {
        'type': 'enabled',
        'budget_tokens': 16383,
      });
    });

    test('an infeasible explicit budget is rejected, never replaced', () {
      final body = <String, dynamic>{
        'model': 'claude-sonnet-4-5',
        'max_tokens': 4096,
      };

      expect(
        () => AnthropicThinkingWireCodec.applyThinking(
          body,
          const AnthropicBudgetDirective(16384),
        ),
        throwsA(isA<ThinkingWireSerializationException>()),
      );
      expect(body.containsKey('thinking'), isFalse);
    });

    for (final maxTokens in <Object>[1, 0, -1]) {
      test('rejects a positive budget under a max_tokens of $maxTokens', () {
        final body = <String, dynamic>{
          'model': 'claude-sonnet-4-5',
          'max_tokens': maxTokens,
        };

        expect(
          () => AnthropicThinkingWireCodec.applyThinking(
            body,
            const AnthropicBudgetDirective(1024),
          ),
          throwsA(isA<ThinkingWireSerializationException>()),
          reason: 'max_tokens $maxTokens cannot host budget_tokens 1024',
        );
        expect(body.containsKey('thinking'), isFalse);
      });
    }

    test('an undeclared ceiling leaves the explicit budget untouched', () {
      final body = <String, dynamic>{'model': 'claude-sonnet-4-5'};

      AnthropicThinkingWireCodec.applyThinking(
        body,
        const AnthropicBudgetDirective(8192),
      );

      expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 8192});
    });
  });
}
