import 'package:sanad_client/features/conversations/domain/models/thinking_control.dart';
import 'package:sanad_client/features/conversations/presentation/utils/route_thinking_control.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';
import 'package:test/test.dart';

/// Red/green client regression for the exact OpenCode Go `deepseek-v4.1-flash`
/// selector that used to disappear.
///
/// The descriptors below are the exact JSON the agent emits for
/// `model.snapshot_result.instances[].models[]` entries
/// (`ThinkingControlDescriptor.toMap()` in
/// `agent/lib/core/provider_thinking/thinking_control_models.dart`). Grounding
/// for the finite tiers: https://api-docs.deepseek.com/guides/thinking_mode
/// documents Chat `thinking.type: enabled/disabled`, finite
/// `reasoning_effort: low/high/max`, enabled by default at default effort
/// `high`, and treats `minimal`/`medium`/`xhigh`/`ultra` as request remaps
/// rather than distinct selectable tiers.
const v41ModelId = 'deepseek-v4.1-flash';

/// Exact supported descriptor for the DeepSeek V4.1 Flash route on OpenCode Go.
const v41SupportedDescriptorJson = <String, dynamic>{
  'status': 'supported',
  'kind': 'effort',
  'options': [
    {
      'id': 'off',
      'label': 'Off',
      'is_off': true,
      'is_provider_default': false,
    },
    {
      'id': 'low',
      'label': 'Low',
      'is_off': false,
      'is_provider_default': false,
    },
    {
      'id': 'high',
      'label': 'High',
      'is_off': false,
      'is_provider_default': true,
    },
    {
      'id': 'max',
      'label': 'Max',
      'is_off': false,
      'is_provider_default': false,
    },
  ],
  'default_option_id': 'high',
  'capability_revision': '1:2:deepseek_thinking:$v41ModelId',
  'source': 'profile',
};

/// The pre-fix (and near-ID) shape: generic Go policy returns unsupported.
const v41UnsupportedDescriptorJson = <String, dynamic>{
  'status': 'unsupported',
  'options': <dynamic>[],
  'capability_revision': '1:2:openai_chat_effort:$v41ModelId',
  'source': 'profile',
};

ModelCacheSnapshotDto _snapshotFor({
  required String modelId,
  required Map<String, dynamic> thinkingControl,
}) {
  return ModelCacheSnapshotDto.fromJson({
    'instances': [
      {
        'id': 'inst-v41-go',
        'display_name': 'OpenCode Go',
        'status': 'ready',
        'is_default': true,
        'cache_status': 'fetched',
        'models': [
          {
            'id': modelId,
            'name': 'DeepSeek V4.1 Flash',
            'supports_reasoning_output': true,
            'thinking_control': thinkingControl,
          },
        ],
      },
    ],
    'recent': <dynamic>[],
  });
}

const _modelControlsCapabilities = Capability(
  supportsThinkingModeChange: true,
  thinkingModeSource: ThinkingModeSource.model,
);

void main() {
  group('OpenCode Go exact deepseek-v4.1-flash client visibility', () {
    test('exact V4.1 descriptor is selectable with the real finite tiers', () {
      final snapshot = _snapshotFor(
        modelId: v41ModelId,
        thinkingControl: v41SupportedDescriptorJson,
      );

      final descriptor = RouteThinkingControl.resolveDescriptor(
        snapshot: snapshot,
        providerInstanceId: 'inst-v41-go',
        modelId: v41ModelId,
      );

      expect(descriptor, isNotNull);
      expect(descriptor!.status, ThinkingCapabilityStatus.supported);
      expect(descriptor.kind, ThinkingControlKind.effort);
      expect(descriptor.isSelectable, isTrue);
      expect(
        descriptor.options.map((option) => option.id).toList(),
        ['off', 'low', 'high', 'max'],
      );
      expect(
        descriptor.options.map((option) => option.label).toList(),
        ['Off', 'Low', 'High', 'Max'],
      );
      expect(descriptor.defaultOptionId, 'high');
      expect(
        descriptor.options.singleWhere((option) => option.isProviderDefault).id,
        'high',
      );
      expect(descriptor.options.singleWhere((option) => option.isOff).id, 'off');

      // Documented request remaps must never surface as distinct client tiers.
      for (final alias in ['minimal', 'medium', 'xhigh', 'ultra', 'none']) {
        expect(
          descriptor.options.any((option) => option.id == alias),
          isFalse,
          reason: '$alias must not be a visible V4.1 tier',
        );
      }

      expect(
        RouteThinkingControl.selectorState(
          capabilities: _modelControlsCapabilities,
          descriptor: descriptor,
        ),
        RouteThinkingSelectorState.selectable,
        reason: 'the exact V4.1 regression must not hide the selector',
      );
    });

    test('exact V4.1 default is the grounded tier, not a fabricated Default', () {
      final descriptor = RouteThinkingControl.resolveDescriptor(
        snapshot: _snapshotFor(
          modelId: v41ModelId,
          thinkingControl: v41SupportedDescriptorJson,
        ),
        providerInstanceId: 'inst-v41-go',
        modelId: v41ModelId,
      );

      expect(
        RouteThinkingControl.effectiveSelectionId(
          descriptor: descriptor,
          selectionId: null,
          legacyModes: const [],
        ),
        'high',
      );
      expect(
        RouteThinkingControl.labelForSelection(
          descriptor: descriptor,
          selectionId: null,
          legacyModes: const [],
        ),
        'High',
      );

      // Explicit Off remains an explicit, valid selection.
      expect(
        RouteThinkingControl.labelForSelection(
          descriptor: descriptor,
          selectionId: 'off',
          legacyModes: const [],
        ),
        'Off',
      );
      expect(
        RouteThinkingControl.isValidSelection(
          descriptor: descriptor,
          selectionId: 'max',
        ),
        isTrue,
      );
      expect(
        RouteThinkingControl.isValidSelection(
          descriptor: descriptor,
          selectionId: 'xhigh',
        ),
        isFalse,
        reason: 'a remapped alias is never a valid client selection',
      );

      // No authoritative descriptor stays honestly provider-managed.
      expect(
        RouteThinkingControl.labelForSelection(
          descriptor: null,
          selectionId: null,
          legacyModes: const [],
        ),
        'Default',
      );
    });

    test('near-ID and pre-fix descriptors stay hidden with no invented options', () {
      for (final modelId in [
        'deepseek-v4.1-flash-x',
        'deepseek-v41-flash',
        v41ModelId,
      ]) {
        final descriptor = ThinkingControlDescriptorDto.fromJson(
          v41UnsupportedDescriptorJson,
        );
        expect(descriptor.status, ThinkingCapabilityStatus.unsupported);
        expect(descriptor.options, isEmpty);
        expect(
          RouteThinkingControl.selectorState(
            capabilities: _modelControlsCapabilities,
            descriptor: descriptor,
          ),
          RouteThinkingSelectorState.hidden,
          reason: '$modelId must not gain a thinking selector',
        );
      }

      // A near-ID snapshot only resolves for its own exact id and stays hidden.
      final nearIdSnapshot = _snapshotFor(
        modelId: 'deepseek-v4.1-flash-x',
        thinkingControl: v41UnsupportedDescriptorJson,
      );
      expect(
        RouteThinkingControl.resolveDescriptor(
          snapshot: nearIdSnapshot,
          providerInstanceId: 'inst-v41-go',
          modelId: v41ModelId,
        ),
        isNull,
        reason: 'exact identity must not borrow a near-ID descriptor',
      );
    });
  });
}
