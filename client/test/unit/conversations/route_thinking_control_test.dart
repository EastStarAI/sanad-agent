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
            ModelCacheModelDto(id: 'o3', thinkingControl: supportedDescriptor),
          ],
        ),
      ],
      recent: [],
    );

    test('reloads snapshot when capabilities become model-scoped', () {
      expect(
        RouteThinkingControl.shouldReloadSnapshot(
          previouslyUsedModelControls: false,
          usesModelControls: true,
          previousProviderId: 'provider-1',
          providerId: 'provider-1',
          previousModelId: 'o3',
          modelId: 'o3',
          previousDeviceId: 'device-1',
          deviceId: 'device-1',
        ),
        isTrue,
      );
      expect(
        RouteThinkingControl.shouldReloadSnapshot(
          previouslyUsedModelControls: true,
          usesModelControls: true,
          previousProviderId: 'provider-1',
          providerId: 'provider-1',
          previousModelId: 'o3',
          modelId: 'o3',
          previousDeviceId: 'device-1',
          deviceId: 'device-1',
        ),
        isFalse,
      );
    });

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
        options: [ThinkingControlOptionDto(id: 'medium', label: 'Medium')],
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

    test(
      'prefers newly fetched snapshot descriptor when capability revision differs from session',
      () {
        const sessionDescriptor = ThinkingControlDescriptorDto(
          status: ThinkingCapabilityStatus.supported,
          capabilityRevision: 'rev-1',
          options: [
            ThinkingControlOptionDto(id: 'low', label: 'Low'),
            ThinkingControlOptionDto(id: 'high', label: 'High'),
          ],
        );

        const refreshedDescriptor = ThinkingControlDescriptorDto(
          status: ThinkingCapabilityStatus.supported,
          capabilityRevision: 'rev-2',
          options: [
            ThinkingControlOptionDto(id: 'off', label: 'Off'),
            ThinkingControlOptionDto(id: 'max', label: 'Max'),
          ],
        );

        const refreshedSnapshot = ModelCacheSnapshotDto(
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
                  thinkingControl: refreshedDescriptor,
                ),
              ],
            ),
          ],
          recent: [],
        );

        final descriptor = RouteThinkingControl.resolveDescriptor(
          snapshot: refreshedSnapshot,
          providerInstanceId: 'provider-1',
          modelId: 'o3',
          sessionDescriptor: sessionDescriptor,
          sessionRouteRevision: 3,
          activeRouteRevision: 3,
          sessionProviderId: 'provider-1',
          sessionModelId: 'o3',
        );

        expect(descriptor?.capabilityRevision, 'rev-2');
        expect(descriptor?.options.map((o) => o.id), ['off', 'max']);
      },
    );

    test(
      'authoritatively refreshed snapshot wins when legacy descriptors carry equal or absent capability revisions',
      () {
        const sessionDescriptor = ThinkingControlDescriptorDto(
          status: ThinkingCapabilityStatus.supported,
          capabilityRevision: '',
          options: [
            ThinkingControlOptionDto(id: 'low', label: 'Legacy Low'),
          ],
        );

        const refreshedDescriptor = ThinkingControlDescriptorDto(
          status: ThinkingCapabilityStatus.supported,
          capabilityRevision: '',
          options: [
            ThinkingControlOptionDto(id: 'quick', label: 'Fresh Quick'),
            ThinkingControlOptionDto(id: 'deep', label: 'Fresh Deep'),
          ],
        );

        const refreshedSnapshot = ModelCacheSnapshotDto(
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
                  thinkingControl: refreshedDescriptor,
                ),
              ],
            ),
          ],
          recent: [],
        );

        final legacyWins = RouteThinkingControl.resolveDescriptor(
          snapshot: refreshedSnapshot,
          providerInstanceId: 'provider-1',
          modelId: 'o3',
          sessionDescriptor: sessionDescriptor,
          sessionRouteRevision: 3,
          activeRouteRevision: 3,
          sessionProviderId: 'provider-1',
          sessionModelId: 'o3',
          isAuthoritative: false,
        );
        expect(legacyWins?.options.map((o) => o.id), ['low']);

        final authoritativeWins = RouteThinkingControl.resolveDescriptor(
          snapshot: refreshedSnapshot,
          providerInstanceId: 'provider-1',
          modelId: 'o3',
          sessionDescriptor: sessionDescriptor,
          sessionRouteRevision: 3,
          activeRouteRevision: 3,
          sessionProviderId: 'provider-1',
          sessionModelId: 'o3',
          isAuthoritative: true,
        );
        expect(authoritativeWins?.options.map((o) => o.id), ['quick', 'deep']);
      },
    );

    test(
      'reflects thinking control removal in authoritative snapshot when model has null thinkingControl',
      () {
        const sessionDescriptor = ThinkingControlDescriptorDto(
          status: ThinkingCapabilityStatus.supported,
          capabilityRevision: 'rev-1',
          options: [
            ThinkingControlOptionDto(id: 'low', label: 'Low'),
          ],
        );

        const removedSnapshot = ModelCacheSnapshotDto(
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
                  thinkingControl: null,
                ),
              ],
            ),
          ],
          recent: [],
        );

        final descriptor = RouteThinkingControl.resolveDescriptor(
          snapshot: removedSnapshot,
          providerInstanceId: 'provider-1',
          modelId: 'o3',
          sessionDescriptor: sessionDescriptor,
          sessionRouteRevision: 3,
          activeRouteRevision: 3,
          sessionProviderId: 'provider-1',
          sessionModelId: 'o3',
        );

        expect(descriptor, isNull);
      },
    );

    test(
      'reflects unsupported thinking control in authoritative snapshot when model becomes unsupported',
      () {
        const sessionDescriptor = ThinkingControlDescriptorDto(
          status: ThinkingCapabilityStatus.supported,
          capabilityRevision: 'rev-1',
          options: [
            ThinkingControlOptionDto(id: 'low', label: 'Low'),
          ],
        );

        const unsupportedDescriptor = ThinkingControlDescriptorDto(
          status: ThinkingCapabilityStatus.unsupported,
          capabilityRevision: 'unsupported',
        );

        const unsupportedSnapshot = ModelCacheSnapshotDto(
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
                  thinkingControl: unsupportedDescriptor,
                ),
              ],
            ),
          ],
          recent: [],
        );

        final descriptor = RouteThinkingControl.resolveDescriptor(
          snapshot: unsupportedSnapshot,
          providerInstanceId: 'provider-1',
          modelId: 'o3',
          sessionDescriptor: sessionDescriptor,
          sessionRouteRevision: 3,
          activeRouteRevision: 3,
          sessionProviderId: 'provider-1',
          sessionModelId: 'o3',
        );

        expect(descriptor?.status, ThinkingCapabilityStatus.unsupported);
        expect(descriptor?.capabilityRevision, 'unsupported');
      },
    );

    test('ignores stale session descriptor when route revision mismatches', () {
      const staleSessionDescriptor = ThinkingControlDescriptorDto(
        status: ThinkingCapabilityStatus.supported,
        options: [ThinkingControlOptionDto(id: 'max', label: 'Max')],
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

    test(
      'ignores session descriptor when provider or model no longer match',
      () {
        const sessionDescriptor = ThinkingControlDescriptorDto(
          status: ThinkingCapabilityStatus.supported,
          options: [ThinkingControlOptionDto(id: 'low', label: 'Low')],
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
      },
    );

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

    test('shows providerManaged state for null descriptors when idle', () {
      const capabilities = Capability(
        supportsThinkingModeChange: true,
        thinkingModeSource: ThinkingModeSource.model,
      );

      expect(
        RouteThinkingControl.selectorState(
          capabilities: capabilities,
          descriptor: null,
        ),
        RouteThinkingSelectorState.providerManaged,
      );
    });

    test('shows loading state when isLoading is true without descriptor', () {
      const capabilities = Capability(
        supportsThinkingModeChange: true,
        thinkingModeSource: ThinkingModeSource.model,
      );

      expect(
        RouteThinkingControl.selectorState(
          capabilities: capabilities,
          descriptor: null,
          isLoading: true,
        ),
        RouteThinkingSelectorState.loading,
      );
    });

    test(
      'shows fetchFailure state when hasFetchError is true without descriptor',
      () {
        const capabilities = Capability(
          supportsThinkingModeChange: true,
          thinkingModeSource: ThinkingModeSource.model,
        );

        expect(
          RouteThinkingControl.selectorState(
            capabilities: capabilities,
            descriptor: null,
            hasFetchError: true,
          ),
          RouteThinkingSelectorState.fetchFailure,
        );
      },
    );

    test('shows providerManaged state for status unknown descriptors', () {
      const capabilities = Capability(
        supportsThinkingModeChange: true,
        thinkingModeSource: ThinkingModeSource.model,
      );
      const descriptor = ThinkingControlDescriptorDto(
        status: ThinkingCapabilityStatus.unknown,
      );

      expect(
        RouteThinkingControl.selectorState(
          capabilities: capabilities,
          descriptor: descriptor,
        ),
        RouteThinkingSelectorState.providerManaged,
      );
    });

    test(
      'shows providerManaged state for status supported with empty options',
      () {
        const capabilities = Capability(
          supportsThinkingModeChange: true,
          thinkingModeSource: ThinkingModeSource.model,
        );
        const descriptor = ThinkingControlDescriptorDto(
          status: ThinkingCapabilityStatus.supported,
          options: [],
        );

        expect(
          RouteThinkingControl.selectorState(
            capabilities: capabilities,
            descriptor: descriptor,
          ),
          RouteThinkingSelectorState.providerManaged,
        );
      },
    );

    test('retains selectable state when descriptor is cached even if isLoading is true', () {
      const capabilities = Capability(
        supportsThinkingModeChange: true,
        thinkingModeSource: ThinkingModeSource.model,
      );
      const descriptor = ThinkingControlDescriptorDto(
        status: ThinkingCapabilityStatus.supported,
        options: [ThinkingControlOptionDto(id: 'high', label: 'High')],
      );

      expect(
        RouteThinkingControl.selectorState(
          capabilities: capabilities,
          descriptor: descriptor,
          isLoading: true,
        ),
        RouteThinkingSelectorState.selectable,
      );
    });

    test('ignores session descriptor when input route differs from session binding', () {
      const sessionDescriptor = ThinkingControlDescriptorDto(
        status: ThinkingCapabilityStatus.supported,
        options: [ThinkingControlOptionDto(id: 'max', label: 'Max')],
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
        options: [ThinkingControlOptionDto(id: 'max', label: 'Max')],
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
                  options: [ThinkingControlOptionDto(id: 'low', label: 'Low')],
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

  group('RouteThinkingControl.labelForSelection', () {
    const descriptor = ThinkingControlDescriptorDto(
      status: ThinkingCapabilityStatus.supported,
      kind: ThinkingControlKind.effort,
      defaultOptionId: 'medium',
      options: [
        ThinkingControlOptionDto(id: 'low', label: 'Low'),
        ThinkingControlOptionDto(
          id: 'medium',
          label: 'Medium',
          isProviderDefault: true,
        ),
        ThinkingControlOptionDto(id: 'high', label: 'High'),
      ],
    );

    test('returns option label when selectionId matches', () {
      expect(
        RouteThinkingControl.labelForSelection(
          descriptor: descriptor,
          selectionId: 'high',
          legacyModes: const [],
        ),
        'High',
      );
    });

    test('resolves defaultOptionId when selectionId is null', () {
      expect(
        RouteThinkingControl.labelForSelection(
          descriptor: descriptor,
          selectionId: null,
          legacyModes: const [],
        ),
        'Medium',
      );
    });

    test('resolves isProviderDefault when defaultOptionId is null and selectionId is null', () {
      const descriptorWithoutDefaultId = ThinkingControlDescriptorDto(
        status: ThinkingCapabilityStatus.supported,
        kind: ThinkingControlKind.effort,
        options: [
          ThinkingControlOptionDto(id: 'low', label: 'Low'),
          ThinkingControlOptionDto(
            id: 'medium',
            label: 'Medium',
            isProviderDefault: true,
          ),
          ThinkingControlOptionDto(id: 'high', label: 'High'),
        ],
      );

      expect(
        RouteThinkingControl.labelForSelection(
          descriptor: descriptorWithoutDefaultId,
          selectionId: null,
          legacyModes: const [],
        ),
        'Medium',
      );
    });

    test('resolves Default label when neither defaultOptionId nor isProviderDefault is set', () {
      const descriptorNoDefault = ThinkingControlDescriptorDto(
        status: ThinkingCapabilityStatus.supported,
        kind: ThinkingControlKind.effort,
        options: [
          ThinkingControlOptionDto(id: 'low', label: 'Low'),
          ThinkingControlOptionDto(id: 'medium', label: 'Medium'),
          ThinkingControlOptionDto(id: 'high', label: 'High'),
        ],
      );

      expect(
        RouteThinkingControl.labelForSelection(
          descriptor: descriptorNoDefault,
          selectionId: null,
          legacyModes: const [],
        ),
        'Default',
      );
    });

    test('resolves legacy balanced mode when descriptor is null', () {
      expect(
        RouteThinkingControl.labelForSelection(
          descriptor: null,
          selectionId: null,
          legacyModes: const ['quick', 'balanced', 'deep'],
        ),
        'balanced',
      );
    });

    test('falls back to Default when descriptor has no options and legacy modes is empty', () {
      expect(
        RouteThinkingControl.labelForSelection(
          descriptor: null,
          selectionId: null,
          legacyModes: const [],
        ),
        'Default',
      );
    });
  });

  group('RouteThinkingControl.effectiveSelectionId', () {
    const descriptor = ThinkingControlDescriptorDto(
      status: ThinkingCapabilityStatus.supported,
      kind: ThinkingControlKind.effort,
      defaultOptionId: 'medium',
      options: [
        ThinkingControlOptionDto(id: 'low', label: 'Low'),
        ThinkingControlOptionDto(
          id: 'medium',
          label: 'Medium',
          isProviderDefault: true,
        ),
        ThinkingControlOptionDto(id: 'high', label: 'High'),
      ],
    );

    test('returns selectionId when provided', () {
      expect(
        RouteThinkingControl.effectiveSelectionId(
          descriptor: descriptor,
          selectionId: 'low',
          legacyModes: const [],
        ),
        'low',
      );
    });

    test('resolves defaultOptionId when selectionId is null', () {
      expect(
        RouteThinkingControl.effectiveSelectionId(
          descriptor: descriptor,
          selectionId: null,
          legacyModes: const [],
        ),
        'medium',
      );
    });

    test('resolves isProviderDefault when defaultOptionId is null', () {
      const descriptorWithoutDefaultId = ThinkingControlDescriptorDto(
        status: ThinkingCapabilityStatus.supported,
        kind: ThinkingControlKind.effort,
        options: [
          ThinkingControlOptionDto(id: 'low', label: 'Low'),
          ThinkingControlOptionDto(
            id: 'high',
            label: 'High',
            isProviderDefault: true,
          ),
        ],
      );

      expect(
        RouteThinkingControl.effectiveSelectionId(
          descriptor: descriptorWithoutDefaultId,
          selectionId: null,
          legacyModes: const [],
        ),
        'high',
      );
    });

    test(
      'returns null when defaultOptionId and isProviderDefault are omitted',
      () {
        const descriptorNoDefault = ThinkingControlDescriptorDto(
          status: ThinkingCapabilityStatus.supported,
          kind: ThinkingControlKind.effort,
          options: [
            ThinkingControlOptionDto(id: 'low', label: 'Low'),
            ThinkingControlOptionDto(id: 'medium', label: 'Medium'),
            ThinkingControlOptionDto(id: 'high', label: 'High'),
          ],
        );

        expect(
          RouteThinkingControl.effectiveSelectionId(
            descriptor: descriptorNoDefault,
            selectionId: null,
            legacyModes: const [],
          ),
          isNull,
        );
      },
    );

    test('resolves balanced for legacy modes when descriptor is null', () {
      expect(
        RouteThinkingControl.effectiveSelectionId(
          descriptor: null,
          selectionId: null,
          legacyModes: const ['quick', 'balanced', 'deep'],
        ),
        'balanced',
      );
    });
  });

  group('RouteThinkingControl.isValidSelection', () {
    const descriptor = ThinkingControlDescriptorDto(
      status: ThinkingCapabilityStatus.supported,
      kind: ThinkingControlKind.effort,
      options: [
        ThinkingControlOptionDto(id: 'low', label: 'Low'),
        ThinkingControlOptionDto(id: 'high', label: 'High'),
      ],
    );

    test('returns true when selectionId is null or empty', () {
      expect(
        RouteThinkingControl.isValidSelection(
          descriptor: descriptor,
          selectionId: null,
        ),
        isTrue,
      );
      expect(
        RouteThinkingControl.isValidSelection(
          descriptor: descriptor,
          selectionId: '   ',
        ),
        isTrue,
      );
    });

    test('returns true when descriptor is null or not selectable so saved values are not erased', () {
      expect(
        RouteThinkingControl.isValidSelection(
          descriptor: null,
          selectionId: 'high',
        ),
        isTrue,
      );
      const unselectable = ThinkingControlDescriptorDto(
        status: ThinkingCapabilityStatus.unsupported,
      );
      expect(
        RouteThinkingControl.isValidSelection(
          descriptor: unselectable,
          selectionId: 'high',
        ),
        isTrue,
      );
    });

    test('validates matching selection against descriptor options', () {
      expect(
        RouteThinkingControl.isValidSelection(
          descriptor: descriptor,
          selectionId: 'high',
        ),
        isTrue,
      );
      expect(
        RouteThinkingControl.isValidSelection(
          descriptor: descriptor,
          selectionId: 'unknown-tier',
        ),
        isFalse,
      );
    });
  });

  group('RouteThinkingControl exact model identity', () {
    const descriptorA = ThinkingControlDescriptorDto(
      status: ThinkingCapabilityStatus.supported,
      kind: ThinkingControlKind.effort,
      options: [ThinkingControlOptionDto(id: 'low', label: 'Low')],
    );

    const descriptorB = ThinkingControlDescriptorDto(
      status: ThinkingCapabilityStatus.supported,
      kind: ThinkingControlKind.tokenBudget,
      options: [ThinkingControlOptionDto(id: 'high', label: 'High')],
    );

    const multiModelSnapshot = ModelCacheSnapshotDto(
      instances: [
        ModelCacheInstanceDto(
          id: 'provider-1',
          displayName: 'Provider 1',
          status: 'ready',
          isDefault: true,
          cacheStatus: 'fetched',
          models: [
            ModelCacheModelDto(
              id: 'VendorA/model',
              thinkingControl: descriptorA,
            ),
            ModelCacheModelDto(
              id: 'VendorB/model',
              thinkingControl: descriptorB,
            ),
            ModelCacheModelDto(id: 'CaseModel', thinkingControl: descriptorA),
            ModelCacheModelDto(id: 'casemodel', thinkingControl: descriptorB),
            ModelCacheModelDto(
              id: 'model:standard',
              thinkingControl: descriptorA,
            ),
            ModelCacheModelDto(
              id: 'model:reasoning',
              thinkingControl: descriptorB,
            ),
            ModelCacheModelDto(
              id: 'Meta-Llama-3.1-70B~Instruct',
              thinkingControl: descriptorA,
            ),
          ],
        ),
      ],
      recent: [],
    );

    test(
      'proves two namespaced IDs within one provider never share a descriptor',
      () {
        final vendorA = RouteThinkingControl.resolveDescriptor(
          snapshot: multiModelSnapshot,
          providerInstanceId: 'provider-1',
          modelId: 'VendorA/model',
        );
        final vendorB = RouteThinkingControl.resolveDescriptor(
          snapshot: multiModelSnapshot,
          providerInstanceId: 'provider-1',
          modelId: 'VendorB/model',
        );

        expect(vendorA?.options.map((o) => o.id), ['low']);
        expect(vendorB?.options.map((o) => o.id), ['high']);
        expect(vendorA, isNot(same(vendorB)));
      },
    );

    test('proves case-distinct custom IDs within one provider never share a descriptor', () {
      final upperCase = RouteThinkingControl.resolveDescriptor(
        snapshot: multiModelSnapshot,
        providerInstanceId: 'provider-1',
        modelId: 'CaseModel',
      );
      final lowerCase = RouteThinkingControl.resolveDescriptor(
        snapshot: multiModelSnapshot,
        providerInstanceId: 'provider-1',
        modelId: 'casemodel',
      );

      expect(upperCase?.options.map((o) => o.id), ['low']);
      expect(lowerCase?.options.map((o) => o.id), ['high']);
      expect(upperCase, isNot(same(lowerCase)));
    });

    test('resolves distinct descriptors for models with colons, tildes, and variant markers', () {
      final standard = RouteThinkingControl.resolveDescriptor(
        snapshot: multiModelSnapshot,
        providerInstanceId: 'provider-1',
        modelId: 'model:standard',
      );
      final reasoning = RouteThinkingControl.resolveDescriptor(
        snapshot: multiModelSnapshot,
        providerInstanceId: 'provider-1',
        modelId: 'model:reasoning',
      );
      final tildeModel = RouteThinkingControl.resolveDescriptor(
        snapshot: multiModelSnapshot,
        providerInstanceId: 'provider-1',
        modelId: 'Meta-Llama-3.1-70B~Instruct',
      );
      final lowerTildeMismatch = RouteThinkingControl.resolveDescriptor(
        snapshot: multiModelSnapshot,
        providerInstanceId: 'provider-1',
        modelId: 'meta-llama-3.1-70b~instruct',
      );

      expect(standard?.options.map((o) => o.id), ['low']);
      expect(reasoning?.options.map((o) => o.id), ['high']);
      expect(tildeModel?.options.map((o) => o.id), ['low']);
      expect(lowerTildeMismatch, isNull);
    });

    test('proves session-versus-active mismatches across namespaces never share session descriptor', () {
      final result = RouteThinkingControl.resolveDescriptor(
        snapshot: multiModelSnapshot,
        providerInstanceId: 'provider-1',
        modelId: 'VendorB/model',
        sessionDescriptor: descriptorA,
        sessionRouteRevision: 1,
        activeRouteRevision: 1,
        sessionProviderId: 'provider-1',
        sessionModelId: 'VendorA/model',
      );

      // Must not reuse sessionDescriptor (descriptorA with 'low'); must resolve VendorB/model from snapshot ('high').
      expect(result?.options.map((o) => o.id), ['high']);
      expect(result, isNot(descriptorA));
    });

    test('proves session-versus-active mismatches across case never share session descriptor', () {
      final result = RouteThinkingControl.resolveDescriptor(
        snapshot: multiModelSnapshot,
        providerInstanceId: 'provider-1',
        modelId: 'casemodel',
        sessionDescriptor: descriptorA,
        sessionRouteRevision: 1,
        activeRouteRevision: 1,
        sessionProviderId: 'provider-1',
        sessionModelId: 'CaseModel',
      );

      // Must not reuse sessionDescriptor (descriptorA with 'low'); must resolve casemodel from snapshot ('high').
      expect(result?.options.map((o) => o.id), ['high']);
      expect(result, isNot(descriptorA));
    });

    test('proves session-versus-active mismatches with variant markers never share session descriptor', () {
      final result = RouteThinkingControl.resolveDescriptor(
        snapshot: multiModelSnapshot,
        providerInstanceId: 'provider-1',
        modelId: 'model:reasoning',
        sessionDescriptor: descriptorA,
        sessionRouteRevision: 1,
        activeRouteRevision: 1,
        sessionProviderId: 'provider-1',
        sessionModelId: 'model:standard',
      );

      // Must not reuse sessionDescriptor (descriptorA with 'low'); must resolve model:reasoning from snapshot ('high').
      expect(result?.options.map((o) => o.id), ['high']);
      expect(result, isNot(descriptorA));
    });

    test(
      'correct exact matches with namespaced and case-distinct IDs still work',
      () {
        final namespacedMatch = RouteThinkingControl.resolveDescriptor(
          snapshot: null,
          providerInstanceId: 'provider-1',
          modelId: 'VendorA/model',
          sessionDescriptor: descriptorA,
          sessionRouteRevision: 2,
          activeRouteRevision: 2,
          sessionProviderId: 'provider-1',
          sessionModelId: 'VendorA/model',
        );
        expect(namespacedMatch, equals(descriptorA));

        final caseMatch = RouteThinkingControl.resolveDescriptor(
          snapshot: null,
          providerInstanceId: 'provider-1',
          modelId: 'CaseModel',
          sessionDescriptor: descriptorA,
          sessionRouteRevision: 2,
          activeRouteRevision: 2,
          sessionProviderId: 'provider-1',
          sessionModelId: 'CaseModel',
        );
        expect(caseMatch, equals(descriptorA));
      },
    );

    test('strips known transport-owned provider-instance prefix with exact boundaries', () {
      final prefixedActiveRoute = RouteThinkingControl.resolveDescriptor(
        snapshot: multiModelSnapshot,
        providerInstanceId: 'provider-1',
        modelId: 'provider-1/VendorA/model',
      );
      expect(prefixedActiveRoute?.options.map((o) => o.id), ['low']);

      final prefixedSessionMatch = RouteThinkingControl.resolveDescriptor(
        snapshot: null,
        providerInstanceId: 'provider-1',
        modelId: 'VendorA/model',
        sessionDescriptor: descriptorA,
        sessionRouteRevision: 5,
        activeRouteRevision: 5,
        sessionProviderId: 'provider-1',
        sessionModelId: 'provider-1/VendorA/model',
      );
      expect(prefixedSessionMatch, equals(descriptorA));
    });

    test('negative boundary tests: does not strip non-matching or arbitrary prefixes', () {
      // Different provider prefix should NOT be stripped from the model ID
      final wrongProviderPrefix = RouteThinkingControl.resolveDescriptor(
        snapshot: multiModelSnapshot,
        providerInstanceId: 'provider-1',
        modelId: 'provider-2/VendorA/model',
      );
      expect(wrongProviderPrefix, isNull);

      // Partial boundary (e.g. 'provider-1-extra/' vs 'provider-1/') must not be stripped
      final partialBoundary = RouteThinkingControl.resolveDescriptor(
        snapshot: multiModelSnapshot,
        providerInstanceId: 'provider-1',
        modelId: 'provider-1-extra/VendorA/model',
      );
      expect(partialBoundary, isNull);

      // Session matching with wrong provider prefix in modelId must not match
      final mismatchedPrefixedSession = RouteThinkingControl.resolveDescriptor(
        snapshot: null,
        providerInstanceId: 'provider-1',
        modelId: 'VendorA/model',
        sessionDescriptor: descriptorA,
        sessionRouteRevision: 5,
        activeRouteRevision: 5,
        sessionProviderId: 'provider-1',
        sessionModelId: 'provider-2/VendorA/model',
      );
      expect(mismatchedPrefixedSession, isNull);
    });
  });
}
