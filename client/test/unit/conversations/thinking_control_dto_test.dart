import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/thinking_control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ThinkingControlDescriptorDto', () {
    test('parses supported, unsupported, and unknown statuses', () {
      final supported = ThinkingControlDescriptorDto.fromJson({
        'status': 'supported',
        'kind': 'effort',
        'options': [
          {'id': 'low', 'label': 'Low'},
        ],
      });
      final unsupported = ThinkingControlDescriptorDto.fromJson({
        'status': 'unsupported',
      });
      final unknown = ThinkingControlDescriptorDto.fromJson({
        'status': 'unknown',
      });
      final invalid = ThinkingControlDescriptorDto.fromJson({
        'status': 'unexpected',
      });

      expect(supported.status, ThinkingCapabilityStatus.supported);
      expect(supported.kind, ThinkingControlKind.effort);
      expect(unsupported.status, ThinkingCapabilityStatus.unsupported);
      expect(unknown.status, ThinkingCapabilityStatus.unknown);
      expect(invalid.status, ThinkingCapabilityStatus.unknown);
    });

    test('parses only declared positive budget tokens', () {
      ThinkingControlOptionDto parseOption(Object? raw) =>
          ThinkingControlOptionDto.fromJson({'id': 'high', 'label': 'High', 'budget_tokens': raw});

      expect(parseOption(8192).budgetTokens, 8192);
      expect(parseOption(2048.0).budgetTokens, 2048);
      expect(parseOption(null).budgetTokens, isNull);
      expect(parseOption(0).budgetTokens, isNull);
      expect(parseOption(-1).budgetTokens, isNull);
      expect(parseOption('8192').budgetTokens, isNull);
      expect(parseOption(true).budgetTokens, isNull);
      expect(parseOption(double.nan).budgetTokens, isNull);
      expect(parseOption(double.infinity).budgetTokens, isNull);
    });

    test('never truncates a fractional budget into an invented token count', () {
      ThinkingControlOptionDto parseOption(Object? raw) => ThinkingControlOptionDto.fromJson({
        'id': 'high',
        'label': 'High',
        'budget_tokens': raw,
      });

      // A fractional value is not an integral token count: truncating it would
      // invent a budget the agent never declared.
      expect(parseOption(1.5).budgetTokens, isNull);
      expect(parseOption(1024.5).budgetTokens, isNull);
      expect(parseOption(-0.5).budgetTokens, isNull);
      // Integral doubles remain exact declared budgets.
      expect(parseOption(1024.0).budgetTokens, 1024);
    });

    test('round-trips budget tokens only when present', () {
      final withBudget = ThinkingControlDescriptorDto.fromJson({
        'status': 'supported',
        'kind': 'token_budget',
        'options': [
          {'id': 'off', 'label': 'Off', 'is_off': true},
          {'id': 'high', 'label': 'High', 'budget_tokens': 8192},
        ],
        'default_option_id': 'high',
        'capability_revision': 'rev-budget',
        'source': 'profile',
      });

      expect(withBudget.kind, ThinkingControlKind.tokenBudget);
      expect(withBudget.options.first.budgetTokens, isNull);
      expect(withBudget.options.last.budgetTokens, 8192);

      final roundTripped = ThinkingControlDescriptorDto.fromJson(withBudget.toJson());
      expect(roundTripped.options.last.budgetTokens, 8192);
      expect(roundTripped.options.last.id, 'high');
      expect(roundTripped.options.last.label, 'High');
      expect(roundTripped.defaultOptionId, 'high');
      expect(roundTripped.capabilityRevision, 'rev-budget');
      expect(
        roundTripped.toJson()['options'],
        <Map<String, dynamic>>[
          {'id': 'off', 'label': 'Off', 'is_off': true, 'is_provider_default': false},
          {
            'id': 'high',
            'label': 'High',
            'is_off': false,
            'is_provider_default': false,
            'budget_tokens': 8192,
          },
        ],
      );
    });

    test('keeps descriptors without budget metadata byte-compatible', () {
      final descriptor = ThinkingControlDescriptorDto.fromJson({
        'status': 'supported',
        'kind': 'effort',
        'options': [
          {'id': 'low', 'label': 'Low'},
        ],
      });

      expect(descriptor.options.single.budgetTokens, isNull);
      expect(descriptor.toJson()['options'], <Map<String, dynamic>>[
        {'id': 'low', 'label': 'Low', 'is_off': false, 'is_provider_default': false},
      ]);
    });

    test('keeps a fractional budget absent in the serialized descriptor', () {
      final descriptor = ThinkingControlDescriptorDto.fromJson({
        'status': 'supported',
        'kind': 'token_budget',
        'options': [
          {'id': 'high', 'label': 'High', 'budget_tokens': 1024.5},
        ],
      });

      expect(descriptor.options.single.budgetTokens, isNull);
      expect(
        descriptor.toJson()['options'],
        <Map<String, dynamic>>[
          {
            'id': 'high',
            'label': 'High',
            'is_off': false,
            'is_provider_default': false,
          },
        ],
        reason: 'a truncated budget must never be written back as a real count',
      );
    });
  });

  group('Session thinking_control parsing', () {
    test('parses route thinking_control from session payload', () {
      final session = Session.fromJson({
        'id': 'session-1',
        'title': 'Test',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
        'thinking_control': {
          'status': 'supported',
          'kind': 'effort',
          'options': [
            {'id': 'low', 'label': 'Low'},
          ],
          'capability_revision': 'rev-1',
          'source': 'profile',
        },
      });

      expect(session.thinkingControl?.status, ThinkingCapabilityStatus.supported);
      expect(session.thinkingControl?.capabilityRevision, 'rev-1');
    });

    test('omits thinking_control on old agent payloads', () {
      final session = Session.fromJson({
        'id': 'session-1',
        'title': 'Test',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
        'thinking_mode': 'balanced',
      });

      expect(session.thinkingControl, isNull);
      expect(session.thinkingMode, 'balanced');
    });
  });
}
