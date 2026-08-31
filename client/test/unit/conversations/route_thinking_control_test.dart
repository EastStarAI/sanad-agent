import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/thinking_control.dart';
import 'package:sanad_client/features/conversations/presentation/utils/route_thinking_control.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';
import 'package:test/test.dart';

void main() {
  group('RouteThinkingControl', () {
    const supportedDescriptor = ThinkingControlDescriptorDto(
      status: ThinkingCapabilityStatus.supported,
      kind: ThinkingControlKind.effort,
      options: [
        ThinkingControlOptionDto(id: 'low', label: 'Low'),
        ThinkingControlOptionDto(id: 'high', label: 'High'),
      ],
    );

    const snapshot = ModelCacheSnapshotDto(
      instances: [
        ModelCacheInstanceDto(
          id: 'provider-1',
          displayName: 'OpenAI',
          status: 'ready',
          isDefault: true,
          cacheStatus: 'fetched',
          models: [
            ModelCacheModelDto(
              id: 'o3',
              thinkingControl: supportedDescriptor,
            ),
          ],
        ),
      ],
      recent: [],
    );

    test('resolves thinking_control from model cache snapshot', () {
      final descriptor = RouteThinkingControl.resolveDescriptor(
        snapshot: snapshot,
        providerInstanceId: 'provider-1',
        modelId: 'o3',
      );

      expect(descriptor?.isSelectable, isTrue);
      expect(descriptor?.options.map((option) => option.id), ['low', 'high']);
    });

    test('prefers route-bound session descriptor over model cache', () {
      const sessionDescriptor = ThinkingControlDescriptorDto(
        status: ThinkingCapabilityStatus.supported,
        options: [
          ThinkingControlOptionDto(id: 'medium', label: 'Medium'),
        ],
      );

      final descriptor = RouteThinkingControl.resolveDescriptor(
        snapshot: snapshot,
        providerInstanceId: 'provider-1',
        modelId: 'o3',
        sessionDescriptor: sessionDescriptor,
        sessionRouteRevision: 3,
        activeRouteRevision: 3,
        sessionProviderId: 'provider-1',
        sessionModelId: 'o3',
      );

      expect(descriptor?.options.map((option) => option.id), ['medium']);
    });

    test('ignores stale session descriptor when route revision mismatches', () {
      const staleSessionDescriptor = ThinkingControlDescriptorDto(
        status: ThinkingCapabilityStatus.supported,
        options: [
          ThinkingControlOptionDto(id: 'max', label: 'Max'),
        ],
      );

      final descriptor = RouteThinkingControl.resolveDescriptor(
        snapshot: null,
        providerInstanceId: 'provider-1',
        modelId: 'o3',
        sessionDescriptor: staleSessionDescriptor,
        sessionRouteRevision: 1,
        activeRouteRevision: 2,
        sessionProviderId: 'provider-1',
        sessionModelId: 'o3',
      );

      expect(descriptor, isNull);
    });

    test('ignores session descriptor when provider or model no longer match', () {
      const sessionDescriptor = ThinkingControlDescriptorDto(
        status: ThinkingCapabilityStatus.supported,
        options: [
          ThinkingControlOptionDto(id: 'low', label: 'Low'),
        ],
      );

      final descriptor = RouteThinkingControl.resolveDescriptor(
        snapshot: snapshot,
        providerInstanceId: 'provider-1',
        modelId: 'gpt-5',
        sessionDescriptor: sessionDescriptor,
        sessionRouteRevision: 4,
        activeRouteRevision: 4,
        sessionProviderId: 'provider-1',
        sessionModelId: 'o3',
      );

      expect(descriptor, isNull);
    });

    test('uses legacy device list when thinking source is absent', () {
      const capabilities = Capability(
        supportsThinkingModeChange: true,
        thinkingModesList: ['fast', 'balanced', 'deep'],
      );

      expect(
        RouteThinkingControl.selectorState(
          capabilities: capabilities,
          descriptor: null,
        ),
        RouteThinkingSelectorState.legacy,
      );
    });

    test('hides selector for unsupported model routes', () {
      const capabilities = Capability(
        supportsThinkingModeChange: true,
        thinkingModeSource: ThinkingModeSource.model,
      );
      const descriptor = ThinkingControlDescriptorDto(
        status: ThinkingCapabilityStatus.unsupported,
      );

      expect(
        RouteThinkingControl.selectorState(
          capabilities: capabilities,
          descriptor: descriptor,
        ),
        RouteThinkingSelectorState.hidden,
      );
    });

    test('shows unavailable state for unknown descriptors', () {
      const capabilities = Capability(
        supportsThinkingModeChange: true,
        thinkingModeSource: ThinkingModeSource.model,
      );

      expect(
        RouteThinkingControl.selectorState(
          capabilities: capabilities,
          descriptor: null,
        ),
        RouteThinkingSelectorState.unavailable,
      );
    });

    test('ignores session descriptor when input route differs from session binding', () {
      const sessionDescriptor = ThinkingControlDescriptorDto(
        status: ThinkingCapabilityStatus.supported,
        options: [
          ThinkingControlOptionDto(id: 'max', label: 'Max'),
        ],
      );

      final descriptor = RouteThinkingControl.resolveDescriptor(
        snapshot: snapshot,
        providerInstanceId: 'provider-1',
        modelId: 'gpt-5',
        sessionDescriptor: sessionDescriptor,
        sessionRouteRevision: 4,
        activeRouteRevision: 4,
        sessionProviderId: 'provider-1',
        sessionModelId: 'o3',
      );

      expect(descriptor, isNull);
    });

    test('falls back to snapshot after route switch when revision matches new model', () {
      const staleSessionDescriptor = ThinkingControlDescriptorDto(
        status: ThinkingCapabilityStatus.supported,
        options: [
          ThinkingControlOptionDto(id: 'max', label: 'Max'),
        ],
      );
      const switchedSnapshot = ModelCacheSnapshotDto(
        instances: [
          ModelCacheInstanceDto(
            id: 'provider-1',
            displayName: 'OpenAI',
            status: 'ready',
            isDefault: true,
            cacheStatus: 'fetched',
            models: [
              ModelCacheModelDto(
                id: 'gpt-5',
                thinkingControl: ThinkingControlDescriptorDto(
                  status: ThinkingCapabilityStatus.supported,
                  options: [
                    ThinkingControlOptionDto(id: 'low', label: 'Low'),
                  ],
                ),
              ),
            ],
          ),
        ],
        recent: [],
      );

      final descriptor = RouteThinkingControl.resolveDescriptor(
        snapshot: switchedSnapshot,
        providerInstanceId: 'provider-1',
        modelId: 'gpt-5',
        sessionDescriptor: staleSessionDescriptor,
        sessionRouteRevision: 2,
        activeRouteRevision: 2,
        sessionProviderId: 'provider-1',
        sessionModelId: 'o3',
      );

      expect(descriptor?.options.map((option) => option.id), ['low']);
    });
  });

  group('Session thinking correction', () {
    test('clears corrected thinking mode when correction payload omits replacement', () {
      final session = Session.fromJson({
        'id': 'session-1',
        'title': 'Test',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
        'thinking_correction': {
          'reason': 'thinking_option_unavailable_for_route',
          'previous_selection_id': 'max',
          'corrected_at': '2026-01-01T00:00:00Z',
        },
      });

      expect(session.thinkingMode, isNull);
    });

    test('keeps replacement thinking mode after correction payload', () {
      final session = Session.fromJson({
        'id': 'session-1',
        'title': 'Test',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
        'thinking_mode': 'low',
        'thinking_correction': {
          'reason': 'thinking_option_unavailable_for_route',
          'previous_selection_id': 'max',
          'corrected_at': '2026-01-01T00:00:00Z',
        },
      });

      expect(session.thinkingMode, 'low');
    });
  });
}
