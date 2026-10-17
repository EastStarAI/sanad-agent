import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/route_capability_resolver.dart';
import 'package:sanad_agent/engine/adapters/models_dev_service.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

void main() {
  group('RouteCapabilityResolver.parseDeclaredImageSupport', () {
    test('parses supports_image_input', () {
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({
          'supports_image_input': true,
        }),
        isTrue,
      );
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({
          'supports_image_input': false,
        }),
        isFalse,
      );
    });

    test('parses image_input', () {
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({
          'image_input': true,
        }),
        isTrue,
      );
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({
          'image_input': false,
        }),
        isFalse,
      );
    });

    test('parses capabilities map', () {
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({
          'capabilities': {'vision': true},
        }),
        isTrue,
      );
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({
          'capabilities': {'vision': false},
        }),
        isFalse,
      );
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({
          'capabilities': {'image_input': true},
        }),
        isTrue,
      );
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({
          'capabilities': {'supports_image_input': true},
        }),
        isTrue,
      );
    });

    test('parses input_modalities list', () {
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({
          'input_modalities': ['text', 'image'],
        }),
        isTrue,
      );
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({
          'input_modalities': ['text'],
        }),
        isFalse,
      );
    });

    test('parses modalities.input list', () {
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({
          'modalities': {
            'input': ['text', 'image'],
          },
        }),
        isTrue,
      );
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({
          'modalities': {
            'input': ['text'],
          },
        }),
        isFalse,
      );
    });

    test('parses architecture.modality string', () {
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({
          'architecture': {'modality': 'text+image->text'},
        }),
        isTrue,
      );
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({
          'architecture': {'modality': 'text->text'},
        }),
        isFalse,
      );
    });

    test('parses supports_vision and vision', () {
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({
          'supports_vision': true,
        }),
        isTrue,
      );
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({
          'supports_vision': false,
        }),
        isFalse,
      );
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({'vision': true}),
        isTrue,
      );
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({'vision': false}),
        isFalse,
      );
    });

    test('returns null for unrecognized or empty metadata', () {
      expect(RouteCapabilityResolver.parseDeclaredImageSupport({}), isNull);
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({'random': 'value'}),
        isNull,
      );
    });
  });

  group('RouteCapabilityResolver precedence hierarchy', () {
    test(
      'tier 1: config override wins over endpoint metadata and catalog',
      () async {
        final config = Config(
          environment: const {},
          modelAwarePolicy: ModelAwareRuntimePolicy(
            contextModelLimits: const {},
            compaction: ModelAwareRuntimePolicy.defaults.compaction,
            modelCapabilities: {
              'my-model': const ModelCapabilityOverride(
                supportsImageInput: true,
              ),
            },
          ),
        );

        final resolver = RouteCapabilityResolver(config: config);

        final profile = await resolver.resolve(
          providerInstanceId: 'custom-1',
          modelId: 'my-model',
        );

        expect(profile.imageSupport, RouteImageSupport.supported);
        expect(profile.evidenceSource, 'override');
      },
    );

    test(
      'tier 2: declared endpoint metadata wins over catalog and unknown',
      () async {
        final repo = _FakeProviderInstanceRepository();
        final now = DateTime.now();
        repo.instances['custom-1'] = ProviderInstance(
          id: 'custom-1',
          templateId: kCustomProviderTemplateId,
          displayName: 'Custom One',
          protocol: 'openai_chat_completions',
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: now,
          updatedAt: now,
        );
        repo.modelCaches['custom-1:models'] = {
          'config_revision': 1,
          'credential_revision': 1,
          'models': [
            ModelOption(
              value: 'custom-model',
              label: 'Custom Model',
              modelMetadata: {
                'modalities': {
                  'input': ['text', 'image'],
                },
              },
            ).toJson(),
          ],
        };

        final resolver = RouteCapabilityResolver(instances: repo);

        final profile = await resolver.resolve(
          providerInstanceId: 'custom-1',
          modelId: 'custom-model',
        );

        expect(profile.imageSupport, RouteImageSupport.supported);
        expect(profile.evidenceSource, 'endpoint_metadata');
      },
    );

    test(
      'tier 3: official provider route uses catalog when metadata absent',
      () async {
        final repo = _FakeProviderInstanceRepository();
        final now = DateTime.now();
        repo.instances['opencode-1'] = ProviderInstance(
          id: 'opencode-1',
          templateId: 'opencode-go',
          displayName: 'OpenCode Go',
          protocol: 'openai_chat_completions',
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: now,
          updatedAt: now,
        );

        int mockNetworkCalls = 0;
        final tempDir = Directory.systemTemp.createTempSync('mdev-tier3-test-');
        final modelsDev = ModelsDevService(
          client: MockClient((_) async {
            mockNetworkCalls++;
            return http.Response(
              jsonEncode({
                'opencode-go': {
                  'api': 'https://opencode.ai/inference/go/v1',
                  'models': {
                    'catalog-vision-model': {
                      'modalities': {
                        'input': ['text', 'image'],
                      },
                    },
                  },
                },
              }),
              200,
            );
          }),
          cacheFilePathOverride: '${tempDir.path}/models_dev_cache.json',
        );

        // Catalog hydration happens before turn admission
        await modelsDev.ensureLoaded();
        expect(mockNetworkCalls, 1);

        final resolver = RouteCapabilityResolver(
          instances: repo,
          modelsDevService: modelsDev,
        );

        // Turn admission executes synchronously with zero hot-path network
        final profile = await resolver.resolve(
          providerInstanceId: 'opencode-1',
          modelId: 'catalog-vision-model',
        );

        expect(mockNetworkCalls, 1, reason: 'Zero network calls at turn admission');
        expect(profile.imageSupport, RouteImageSupport.supported);
        expect(profile.evidenceSource, 'catalog');
      },
    );

    test(
      'tier 4: custom routes without declared metadata remain unknown (no name guessing)',
      () async {
        final repo = _FakeProviderInstanceRepository();
        final now = DateTime.now();
        repo.instances['custom-1'] = ProviderInstance(
          id: 'custom-1',
          templateId: kCustomProviderTemplateId,
          displayName: 'Custom One',
          protocol: 'openai_chat_completions',
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: now,
          updatedAt: now,
        );

        final resolver = RouteCapabilityResolver(instances: repo);

        // Model name suggests vision, but on custom route it must NOT guess!
        final profile = await resolver.resolve(
          providerInstanceId: 'custom-1',
          modelId: 'claude-3-5-sonnet-vision',
        );

        expect(profile.imageSupport, RouteImageSupport.unknown);
        expect(profile.evidenceSource, 'unknown');
      },
    );
  });

  group('RouteCapabilityResolver cache validation & robustness', () {
    test(
      'stale cache rejected when config_revision or credential_revision changes',
      () async {
        final repo = _FakeProviderInstanceRepository();
        final now = DateTime.now();
        repo.instances['custom-uuid-1'] = ProviderInstance(
          id: 'custom-uuid-1',
          templateId: kCustomProviderTemplateId,
          displayName: 'Custom UUID',
          protocol: 'openai_chat_completions',
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: now,
          updatedAt: now,
        ).copyWith(configRevision: 2, credentialRevision: 1);

        // Cache recorded under old rev 1
        repo.modelCaches['custom-uuid-1:models'] = {
          'config_revision': 1,
          'credential_revision': 1,
          'models': [
            {'value': 'vision-model', 'supports_image_input': true},
          ],
        };

        final resolver = RouteCapabilityResolver(instances: repo);
        final profile = await resolver.resolve(
          providerInstanceId: 'custom-uuid-1',
          modelId: 'vision-model',
        );

        // Stale cache must be rejected => unknown!
        expect(profile.imageSupport, RouteImageSupport.unknown);
        expect(profile.evidenceSource, 'unknown');
      },
    );

    test('stale cache rejected when credential_revision changes', () async {
      final repo = _FakeProviderInstanceRepository();
      final now = DateTime.now();
      repo.instances['custom-uuid-1'] = ProviderInstance(
        id: 'custom-uuid-1',
        templateId: kCustomProviderTemplateId,
        displayName: 'Custom UUID',
        protocol: 'openai_chat_completions',
        authMethod: ProviderAuthMethod.apiKey,
        createdAt: now,
        updatedAt: now,
      ).copyWith(configRevision: 1, credentialRevision: 2);

      // Cache recorded under old cred 1
      repo.modelCaches['custom-uuid-1:models'] = {
        'config_revision': 1,
        'credential_revision': 1,
        'models': [
          {'value': 'vision-model', 'supports_image_input': true},
        ],
      };

      final resolver = RouteCapabilityResolver(instances: repo);
      final profile = await resolver.resolve(
        providerInstanceId: 'custom-uuid-1',
        modelId: 'vision-model',
      );

      expect(profile.imageSupport, RouteImageSupport.unknown);
      expect(profile.evidenceSource, 'unknown');
    });

    test(
      'gracefully skips malformed entries and matches minimal or id-based rows',
      () async {
        final repo = _FakeProviderInstanceRepository();
        final now = DateTime.now();
        repo.instances['custom-uuid-2'] = ProviderInstance(
          id: 'custom-uuid-2',
          templateId: kCustomProviderTemplateId,
          displayName: 'Custom UUID 2',
          protocol: 'openai_chat_completions',
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: now,
          updatedAt: now,
        ).copyWith(configRevision: 1, credentialRevision: 1);

        repo.modelCaches['custom-uuid-2:models'] = {
          'config_revision': 1,
          'credential_revision': 1,
          'models': [
            null, // not a map
            'just-a-string', // invalid type
            {'invalid_structure': true}, // missing value/id
            {'id': 'minimal-vision-id', 'supports_image_input': true},
          ],
        };

        final resolver = RouteCapabilityResolver(instances: repo);
        final profile = await resolver.resolve(
          providerInstanceId: 'custom-uuid-2',
          modelId: 'minimal-vision-id',
        );

        expect(profile.imageSupport, RouteImageSupport.supported);
        expect(profile.evidenceSource, 'endpoint_metadata');
      },
    );

    test(
      'rename invariance preserves cached capabilities for custom UUID instance',
      () async {
        final repo = _FakeProviderInstanceRepository();
        final now = DateTime.now();
        final uuid = '3fa85f64-5717-4562-b3fc-2c963f66afa6';

        // Instance renamed from "Old Name" to "New Name" without bumping config/credential rev
        repo.instances[uuid] = ProviderInstance(
          id: uuid,
          templateId: kCustomProviderTemplateId,
          displayName: 'Renamed Custom Provider',
          protocol: 'openai_chat_completions',
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: now,
          updatedAt: now,
        ).copyWith(configRevision: 1, credentialRevision: 1);

        repo.modelCaches['$uuid:models'] = {
          'config_revision': 1,
          'credential_revision': 1,
          'models': [
            {'value': 'custom-vision-uuid', 'supports_image_input': true},
          ],
        };

        final resolver = RouteCapabilityResolver(instances: repo);
        final profile = await resolver.resolve(
          providerInstanceId: uuid,
          modelId: 'custom-vision-uuid',
        );

        expect(profile.imageSupport, RouteImageSupport.supported);
        expect(profile.evidenceSource, 'endpoint_metadata');
      },
    );

    test('custom case-distinct models do not cross-grant capabilities', () async {
      final repo = _FakeProviderInstanceRepository();
      final now = DateTime.now();
      repo.instances['custom-case-1'] = ProviderInstance(
        id: 'custom-case-1',
        templateId: kCustomProviderTemplateId,
        displayName: 'Custom Case 1',
        protocol: 'openai_chat_completions',
        authMethod: ProviderAuthMethod.apiKey,
        createdAt: now,
        updatedAt: now,
      ).copyWith(configRevision: 1, credentialRevision: 1);

      repo.modelCaches['custom-case-1:models'] = {
        'config_revision': 1,
        'credential_revision': 1,
        'models': [
          {'value': 'Vision-Model-Upper', 'supports_image_input': true},
        ],
      };

      final resolver = RouteCapabilityResolver(instances: repo);
      // Query with different case
      final profileLower = await resolver.resolve(
        providerInstanceId: 'custom-case-1',
        modelId: 'vision-model-upper',
      );
      expect(profileLower.imageSupport, RouteImageSupport.unknown);

      // Query with exact case
      final profileExact = await resolver.resolve(
        providerInstanceId: 'custom-case-1',
        modelId: 'Vision-Model-Upper',
      );
      expect(profileExact.imageSupport, RouteImageSupport.supported);
    });

    test('custom tilde-distinct models do not cross-grant capabilities', () async {
      final repo = _FakeProviderInstanceRepository();
      final now = DateTime.now();
      repo.instances['custom-tilde-1'] = ProviderInstance(
        id: 'custom-tilde-1',
        templateId: kCustomProviderTemplateId,
        displayName: 'Custom Tilde 1',
        protocol: 'openai_chat_completions',
        authMethod: ProviderAuthMethod.apiKey,
        createdAt: now,
        updatedAt: now,
      ).copyWith(configRevision: 1, credentialRevision: 1);

      repo.modelCaches['custom-tilde-1:models'] = {
        'config_revision': 1,
        'credential_revision': 1,
        'models': [
          {'value': '~custom-model-pinned', 'supports_image_input': true},
        ],
      };

      final resolver = RouteCapabilityResolver(instances: repo);
      // Query bare model without tilde
      final profileBare = await resolver.resolve(
        providerInstanceId: 'custom-tilde-1',
        modelId: 'custom-model-pinned',
      );
      expect(profileBare.imageSupport, RouteImageSupport.unknown);

      // Query exact model with tilde
      final profileTilde = await resolver.resolve(
        providerInstanceId: 'custom-tilde-1',
        modelId: '~custom-model-pinned',
      );
      expect(profileTilde.imageSupport, RouteImageSupport.supported);
    });

    test('catalog capabilities for known model resolve through custom proxy endpoint', () async {
      final repo = _FakeProviderInstanceRepository();
      final now = DateTime.now();
      repo.instances['official-overridden-1'] = ProviderInstance(
        id: 'official-overridden-1',
        templateId: 'anthropic',
        displayName: 'Custom Proxy Anthropic',
        protocol: ProviderProtocol.anthropicCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        baseUrl: 'https://proxy.custom-enterprise.internal/v1',
        createdAt: now,
        updatedAt: now,
      ).copyWith(configRevision: 1, credentialRevision: 1);

      // models.dev service mock with standard anthropic models
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'anthropic': {
              'api': 'https://api.anthropic.com',
              'models': {
                'claude-3-5-sonnet-20241022': {
                  'modalities': {
                    'input': ['text', 'image'],
                  },
                },
              },
            },
          }),
          200,
        );
      });
      final tempDir = Directory.systemTemp.createTempSync('mdev-proxy-test-');
      final modelsDev = ModelsDevService(
        client: mockClient,
        cacheFilePathOverride: '${tempDir.path}/models_dev_cache.json',
      );
      await modelsDev.ensureLoaded();

      final resolver = RouteCapabilityResolver(
        instances: repo,
        modelsDevService: modelsDev,
      );

      final profile = await resolver.resolve(
        providerInstanceId: 'official-overridden-1',
        modelId: 'claude-3-5-sonnet-20241022',
        baseUrl: 'https://proxy.custom-enterprise.internal/v1',
      );

      // Known model resolves image capability from catalog across custom proxy endpoints
      expect(profile.imageSupport, RouteImageSupport.supported);
      expect(profile.evidenceSource, 'catalog');
    });

    test('ModelOption toJson/fromJson round-trip stability without nested growth of modelMetadata', () {
      final initial = ModelOption(
        value: 'test-model',
        label: 'Test Model',
        modelMetadata: {
          'supports_image_input': true,
          'custom_field': 'hello',
        },
      );
      final json1 = initial.toJson();
      final roundTrip1 = ModelOption.fromJson(json1);
      final json2 = roundTrip1.toJson();
      final roundTrip2 = ModelOption.fromJson(json2);

      expect(roundTrip1.modelMetadata, equals(initial.modelMetadata));
      expect(roundTrip2.modelMetadata, equals(initial.modelMetadata));
      expect(roundTrip2.modelMetadata.containsKey('model_metadata'), isFalse);
      expect(roundTrip2.modelMetadata.containsKey('thinking_control'), isFalse);
    });

    test('catalog and declared metadata grant supported, while custom names-only unknown models stay unknown', () async {
      final repo = _FakeProviderInstanceRepository();
      final now = DateTime.now();
      repo.instances['official-anthropic'] = ProviderInstance(
        id: 'official-anthropic',
        templateId: 'anthropic',
        displayName: 'Anthropic Claude',
        protocol: ProviderProtocol.anthropicCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        baseUrl: 'https://api.anthropic.com',
        createdAt: now,
        updatedAt: now,
      );
      repo.instances['custom-names-only'] = ProviderInstance(
        id: 'custom-names-only',
        templateId: kCustomProviderTemplateId,
        displayName: 'Custom Provider',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        baseUrl: 'https://custom.endpoint.internal/v1',
        createdAt: now,
        updatedAt: now,
      );

      // Model cache with declared endpoint metadata
      repo.modelCaches['official-anthropic:models'] = {
        'config_revision': 1,
        'credential_revision': 1,
        'models': [
          {
            'value': 'claude-declared',
            'label': 'Claude Declared',
            'model_metadata': {'supports_image_input': true},
          },
        ],
      };

      final tempDir = Directory.systemTemp.createTempSync('mdev-route-test-');
      final tempCachePath = '${tempDir.path}/models_dev_cache.json';

      // ModelsDevService with official catalog fixture
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'anthropic': {
              'api': 'https://api.anthropic.com',
              'models': {
                'claude-catalog': {
                  'modalities': {
                    'input': ['text', 'image'],
                  },
                },
                'claude-haiku-4.5': {
                  'modalities': {
                    'input': ['text', 'image'],
                  },
                },
              },
            },
          }),
          200,
        );
      });
      final modelsDev = ModelsDevService(
        client: mockClient,
        cacheFilePathOverride: tempCachePath,
      );
      await modelsDev.ensureLoaded();

      final resolver = RouteCapabilityResolver(
        instances: repo,
        modelsDevService: modelsDev,
      );

      // 1. Declared endpoint metadata grants supported
      final profileDeclared = await resolver.resolve(
        providerInstanceId: 'official-anthropic',
        modelId: 'claude-declared',
      );
      expect(profileDeclared.imageSupport, RouteImageSupport.supported);
      expect(profileDeclared.evidenceSource, 'endpoint_metadata');

      // 2. Exact ModelsDev catalog grants supported
      final profileCatalog = await resolver.resolve(
        providerInstanceId: 'official-anthropic',
        modelId: 'claude-catalog',
      );
      expect(profileCatalog.imageSupport, RouteImageSupport.supported);
      expect(profileCatalog.evidenceSource, 'catalog');

      // 3. Known model on proxy endpoint resolves supported from catalog
      final profileProxyEndpoint = await resolver.resolve(
        providerInstanceId: 'official-anthropic',
        modelId: 'claude-catalog',
        baseUrl: 'https://proxy.enterprise.corp/anthropic',
      );
      expect(profileProxyEndpoint.imageSupport, RouteImageSupport.supported);
      expect(profileProxyEndpoint.evidenceSource, 'catalog');

      // 4. Custom names-only provider with same-generation claude-haiku-4.5 resolves supported from catalog
      repo.modelCaches['custom-names-only:models'] = {
        'config_revision': 1,
        'credential_revision': 1,
        'models': [
          {
            'value': 'claude-haiku-4.5',
            'label': 'Claude Haiku 4.5',
          },
        ],
      };
      final profileCustomHaiku = await resolver.resolve(
        providerInstanceId: 'custom-names-only',
        modelId: 'claude-haiku-4.5',
      );
      expect(profileCustomHaiku.imageSupport, RouteImageSupport.supported);
      expect(profileCustomHaiku.evidenceSource, 'catalog');

      // 5. Custom names-only provider without declared metadata or catalog match stays unknown
      final profileCustomNamesOnly = await resolver.resolve(
        providerInstanceId: 'custom-names-only',
        modelId: 'some-custom-model',
      );
      expect(profileCustomNamesOnly.imageSupport, RouteImageSupport.unknown);

      // 6. resolveSync executes synchronously without network (no body-path network)
      final profileSync = resolver.resolveSync(
        providerInstanceId: 'official-anthropic',
        modelId: 'claude-declared',
      );
      expect(profileSync.imageSupport, RouteImageSupport.supported);
      expect(profileSync.evidenceSource, 'endpoint_metadata');
    });

    test('older-generation Haiku in catalog does NOT cross-grant capability to claude-haiku-4.5', () async {
      final repo = _FakeProviderInstanceRepository();
      final now = DateTime.now();
      repo.instances['custom-names-only'] = ProviderInstance(
        id: 'custom-names-only',
        templateId: kCustomProviderTemplateId,
        displayName: 'Custom Provider',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        baseUrl: 'https://custom.endpoint.internal/v1',
        createdAt: now,
        updatedAt: now,
      );

      final tempDir = Directory.systemTemp.createTempSync('mdev-old-haiku-test-');
      // Catalog contains ONLY older Haiku 3.5 and 3
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'anthropic': {
              'api': 'https://api.anthropic.com',
              'models': {
                'claude-3-5-haiku-20241022': {
                  'modalities': {
                    'input': ['text', 'image'],
                  },
                },
                'claude-3-haiku-20240307': {
                  'modalities': {
                    'input': ['text', 'image'],
                  },
                },
              },
            },
          }),
          200,
        );
      });

      final modelsDev = ModelsDevService(
        client: mockClient,
        cacheFilePathOverride: '${tempDir.path}/models_dev_cache.json',
      );
      await modelsDev.ensureLoaded();

      final resolver = RouteCapabilityResolver(
        instances: repo,
        modelsDevService: modelsDev,
      );

      // claude-haiku-4.5 must NOT fall back to older Haiku 3.5 / 3. It must stay unknown!
      final profile = await resolver.resolve(
        providerInstanceId: 'custom-names-only',
        modelId: 'claude-haiku-4.5',
      );
      expect(profile.imageSupport, RouteImageSupport.unknown);
    });

    test('same model ID with conflicting cross-vendor support fails closed to unknown unless namespaced', () async {
      final repo = _FakeProviderInstanceRepository();
      final now = DateTime.now();
      repo.instances['provider-a'] = ProviderInstance(
        id: 'provider-a',
        templateId: 'opencode-go',
        displayName: 'Provider A',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        createdAt: now,
        updatedAt: now,
      );
      repo.instances['provider-b'] = ProviderInstance(
        id: 'provider-b',
        templateId: 'anthropic',
        displayName: 'Provider B',
        protocol: ProviderProtocol.anthropicCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        createdAt: now,
        updatedAt: now,
      );

      final tempDir = Directory.systemTemp.createTempSync('mdev-conflict-test-');
      // vendorA says image: true, vendorB says image: false
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'opencode-go': {
              'api': 'https://opencode.ai/inference/go/v1',
              'models': {
                'ambiguous-model': {
                  'modalities': {
                    'input': ['text', 'image'],
                  },
                },
              },
            },
            'anthropic': {
              'api': 'https://api.anthropic.com',
              'models': {
                'ambiguous-model': {
                  'modalities': {
                    'input': ['text'],
                  },
                },
              },
            },
          }),
          200,
        );
      });

      final modelsDev = ModelsDevService(
        client: mockClient,
        cacheFilePathOverride: '${tempDir.path}/models_dev_cache.json',
      );
      await modelsDev.ensureLoaded();

      final resolver = RouteCapabilityResolver(
        instances: repo,
        modelsDevService: modelsDev,
      );

      // Bare model ID is ambiguous across vendors => fails closed to unknown regardless of provider instance!
      final profileA = await resolver.resolve(
        providerInstanceId: 'provider-a',
        modelId: 'ambiguous-model',
      );
      expect(profileA.imageSupport, RouteImageSupport.unknown);

      final profileB = await resolver.resolve(
        providerInstanceId: 'provider-b',
        modelId: 'ambiguous-model',
      );
      expect(profileB.imageSupport, RouteImageSupport.unknown);

      // Explicit namespacing resolves directly to that vendor's identity
      final profileNamespacedA = await resolver.resolve(
        providerInstanceId: 'provider-a',
        modelId: 'opencode-go/ambiguous-model',
      );
      expect(profileNamespacedA.imageSupport, RouteImageSupport.supported);
      expect(profileNamespacedA.evidenceSource, 'catalog');

      final profileNamespacedB = await resolver.resolve(
        providerInstanceId: 'provider-b',
        modelId: 'anthropic/ambiguous-model',
      );
      expect(profileNamespacedB.imageSupport, RouteImageSupport.unsupported);
      expect(profileNamespacedB.evidenceSource, 'catalog');
    });

    test('stale disk cache file preserves actual modified timestamp without freshening on read', () async {
      final tempDir = Directory.systemTemp.createTempSync('mdev-stale-test-');
      final cacheFile = File('${tempDir.path}/models_dev_cache.json');
      cacheFile.writeAsStringSync(
        jsonEncode({
          'anthropic': {
            'api': 'https://api.anthropic.com',
            'models': {
              'cached-model': {
                'modalities': {
                  'input': ['text', 'image'],
                },
              },
            },
          },
        }),
      );
      // Backdate the cache file modification time to 2 hours ago (> 1 hour cacheTtlSeconds)
      final twoHoursAgo = DateTime.now().subtract(const Duration(hours: 2));
      cacheFile.setLastModifiedSync(twoHoursAgo);

      int networkCalls = 0;
      final mockClient = MockClient((request) async {
        networkCalls++;
        return http.Response(
          jsonEncode({
            'anthropic': {
              'api': 'https://api.anthropic.com',
              'models': {
                'cached-model': {
                  'modalities': {
                    'input': ['text', 'image'],
                  },
                },
              },
            },
          }),
          200,
        );
      });

      final modelsDev = ModelsDevService(
        client: mockClient,
        cacheFilePathOverride: cacheFile.path,
      );

      // 1. Hot sync lookup reads disk cache without network
      final syncResult = modelsDev.supportsImageInputSync('cached-model');
      expect(syncResult, isTrue);
      expect(networkCalls, 0, reason: 'Sync lookup must not perform network calls');

      // 2. File modification time was NOT freshened merely by reading
      final fileStatAfterRead = cacheFile.statSync();
      expect(
        fileStatAfterRead.modified.isBefore(DateTime.now().subtract(const Duration(hours: 1))),
        isTrue,
        reason: 'Disk cache timestamp must not be freshened merely by reading',
      );

      // 3. Explicit ensureLoaded detects stale cache and performs network refresh
      await modelsDev.ensureLoaded();
      expect(networkCalls, 1, reason: 'Explicit refresh must refresh stale cache');
    });

    test('speculative model names (claude-4-5-haiku) fail closed to unknown', () async {
      final repo = _FakeProviderInstanceRepository();
      repo.instances['custom-p'] = ProviderInstance(
        id: 'custom-p',
        templateId: kCustomProviderTemplateId,
        displayName: 'Custom Provider',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final tempDir = Directory.systemTemp.createTempSync('mdev-speculative-test-');
      final modelsDev = ModelsDevService(
        cacheFilePathOverride: '${tempDir.path}/models_dev_cache.json',
        client: MockClient((request) async {
          return http.Response(
            jsonEncode({
              'anthropic': {
                'api': 'https://api.anthropic.com',
                'models': {
                  'claude-haiku-4-5': {
                    'modalities': {
                      'input': ['text', 'image'],
                    },
                  },
                },
              },
            }),
            200,
          );
        }),
      );
      await modelsDev.ensureLoaded();

      final resolver = RouteCapabilityResolver(
        instances: repo,
        modelsDevService: modelsDev,
      );

      // Grounded alias claude-haiku-4.5 succeeds
      final groundedProfile = await resolver.resolve(
        providerInstanceId: 'custom-p',
        modelId: 'claude-haiku-4.5',
      );
      expect(groundedProfile.imageSupport, RouteImageSupport.supported);

      // Speculative names without evidence fail closed
      for (final speculativeName in [
        'claude-4-5-haiku',
        'claude-4-5-haiku-20251001',
      ]) {
        final profile = await resolver.resolve(
          providerInstanceId: 'custom-p',
          modelId: speculativeName,
        );
        expect(profile.imageSupport, RouteImageSupport.unknown);
      }
    });

    group('combined vendor and alias aggregation regressions', () {
      late _FakeProviderInstanceRepository repo;
      late Directory tempDir;

      setUp(() {
        repo = _FakeProviderInstanceRepository();
        repo.instances['custom-p'] = ProviderInstance(
          id: 'custom-p',
          templateId: kCustomProviderTemplateId,
          displayName: 'Custom Provider',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        tempDir = Directory.systemTemp.createTempSync('mdev-combined-test-');
      });

      tearDown(() {
        tempDir.deleteSync(recursive: true);
      });

      test('contradictory alias vendor + positive other vendor fails closed to unknown', () async {
        final modelsDev = ModelsDevService(
          cacheFilePathOverride: '${tempDir.path}/models_dev_cache.json',
          client: MockClient((request) async {
            return http.Response(
              jsonEncode({
                'anthropic': {
                  'api': 'https://api.anthropic.com',
                  'models': {
                    'claude-haiku-4-5': {'modalities': {'input': ['text', 'image']}},
                    'claude-haiku-4-5-20251001': {'modalities': {'input': ['text']}},
                  },
                },
                'github-copilot': {
                  'api': 'https://api.github.com',
                  'models': {
                    'claude-haiku-4.5': {'modalities': {'input': ['text', 'image']}},
                  },
                },
              }),
              200,
            );
          }),
        );
        await modelsDev.ensureLoaded();

        final resolver = RouteCapabilityResolver(
          instances: repo,
          modelsDevService: modelsDev,
        );

        final profile = await resolver.resolve(
          providerInstanceId: 'custom-p',
          modelId: 'claude-haiku-4.5',
        );
        expect(profile.imageSupport, RouteImageSupport.unknown);
      });

      test('contradictory alias vendor + negative other vendor fails closed to unknown', () async {
        final modelsDev = ModelsDevService(
          cacheFilePathOverride: '${tempDir.path}/models_dev_cache.json',
          client: MockClient((request) async {
            return http.Response(
              jsonEncode({
                'anthropic': {
                  'api': 'https://api.anthropic.com',
                  'models': {
                    'claude-haiku-4-5': {'modalities': {'input': ['text', 'image']}},
                    'claude-haiku-4-5-20251001': {'modalities': {'input': ['text']}},
                  },
                },
                'github-copilot': {
                  'api': 'https://api.github.com',
                  'models': {
                    'claude-haiku-4.5': {'modalities': {'input': ['text']}},
                  },
                },
              }),
              200,
            );
          }),
        );
        await modelsDev.ensureLoaded();

        final resolver = RouteCapabilityResolver(
          instances: repo,
          modelsDevService: modelsDev,
        );

        final profile = await resolver.resolve(
          providerInstanceId: 'custom-p',
          modelId: 'claude-haiku-4.5',
        );
        expect(profile.imageSupport, RouteImageSupport.unknown);
      });

      test('all aliases agree across vendors resolves supported', () async {
        final modelsDev = ModelsDevService(
          cacheFilePathOverride: '${tempDir.path}/models_dev_cache.json',
          client: MockClient((request) async {
            return http.Response(
              jsonEncode({
                'anthropic': {
                  'api': 'https://api.anthropic.com',
                  'models': {
                    'claude-haiku-4-5': {'modalities': {'input': ['text', 'image']}},
                    'claude-haiku-4-5-20251001': {'modalities': {'input': ['text', 'image']}},
                  },
                },
                'github-copilot': {
                  'api': 'https://api.github.com',
                  'models': {
                    'claude-haiku-4.5': {'modalities': {'input': ['text', 'image']}},
                  },
                },
              }),
              200,
            );
          }),
        );
        await modelsDev.ensureLoaded();

        final resolver = RouteCapabilityResolver(
          instances: repo,
          modelsDevService: modelsDev,
        );

        final profile = await resolver.resolve(
          providerInstanceId: 'custom-p',
          modelId: 'claude-haiku-4.5',
        );
        expect(profile.imageSupport, RouteImageSupport.supported);
      });

      test('partial unknown other vendor does not veto unambiguous known fact', () async {
        final modelsDev = ModelsDevService(
          cacheFilePathOverride: '${tempDir.path}/models_dev_cache.json',
          client: MockClient((request) async {
            return http.Response(
              jsonEncode({
                'anthropic': {
                  'api': 'https://api.anthropic.com',
                  'models': {
                    'claude-haiku-4-5': {'modalities': {'input': ['text', 'image']}},
                  },
                },
                'github-copilot': {
                  'api': 'https://api.github.com',
                  'models': {
                    'claude-haiku-4.5': {'modalities': {}}, // missing input modality!
                  },
                },
                'openrouter': {
                  'api': 'https://openrouter.ai',
                  'models': {
                    'other-model': {'modalities': {'input': ['text']}}, // model completely absent!
                  },
                },
              }),
              200,
            );
          }),
        );
        await modelsDev.ensureLoaded();

        final resolver = RouteCapabilityResolver(
          instances: repo,
          modelsDevService: modelsDev,
        );

        // Bare claude-haiku-4.5 matches anthropic alias with image: true;
        // copilot's missing modality and openrouter's missing model do NOT veto it!
        final profile = await resolver.resolve(
          providerInstanceId: 'custom-p',
          modelId: 'claude-haiku-4.5',
        );
        expect(profile.imageSupport, RouteImageSupport.supported);
        expect(profile.evidenceSource, 'catalog');
      });

      test('explicit namespace scopes resolution strictly to targeted vendor', () async {
        final modelsDev = ModelsDevService(
          cacheFilePathOverride: '${tempDir.path}/models_dev_cache.json',
          client: MockClient((request) async {
            return http.Response(
              jsonEncode({
                'anthropic': {
                  'api': 'https://api.anthropic.com',
                  'models': {
                    'claude-haiku-4-5': {'modalities': {'input': ['text', 'image']}},
                    'claude-haiku-4-5-20251001': {'modalities': {'input': ['text']}},
                  },
                },
                'github-copilot': {
                  'api': 'https://api.github.com',
                  'models': {
                    'claude-haiku-4.5': {'modalities': {'input': ['text', 'image']}},
                  },
                },
              }),
              200,
            );
          }),
        );
        await modelsDev.ensureLoaded();

        final resolver = RouteCapabilityResolver(
          instances: repo,
          modelsDevService: modelsDev,
        );

        // Explicit copilot namespace targets only copilot -> supported
        final copilotProfile = await resolver.resolve(
          providerInstanceId: 'custom-p',
          modelId: 'copilot/claude-haiku-4.5',
        );
        expect(copilotProfile.imageSupport, RouteImageSupport.supported);
        expect(copilotProfile.evidenceSource, 'catalog');

        // Explicit anthropic namespace targets anthropic which has conflicting aliases -> unknown
        final anthropicProfile = await resolver.resolve(
          providerInstanceId: 'custom-p',
          modelId: 'anthropic/claude-haiku-4.5',
        );
        expect(anthropicProfile.imageSupport, RouteImageSupport.unknown);
      });

      test('exact selected ID within same vendor remains authoritative despite alias difference', () async {
        final modelsDev = ModelsDevService(
          cacheFilePathOverride: '${tempDir.path}/models_dev_cache.json',
          client: MockClient((request) async {
            return http.Response(
              jsonEncode({
                'anthropic': {
                  'api': 'https://api.anthropic.com',
                  'models': {
                    'claude-haiku-4-5': {'modalities': {'input': ['text', 'image']}},
                    'claude-haiku-4-5-20251001': {'modalities': {'input': ['text']}},
                  },
                },
              }),
              200,
            );
          }),
        );
        await modelsDev.ensureLoaded();

        final resolver = RouteCapabilityResolver(
          instances: repo,
          modelsDevService: modelsDev,
        );

        // Exact ID claude-haiku-4-5 is present in anthropic -> authoritative true
        final exactProfile = await resolver.resolve(
          providerInstanceId: 'custom-p',
          modelId: 'claude-haiku-4-5',
        );
        expect(exactProfile.imageSupport, RouteImageSupport.supported);

        // Exact ID claude-haiku-4-5-20251001 is present in anthropic -> authoritative false
        final datedProfile = await resolver.resolve(
          providerInstanceId: 'custom-p',
          modelId: 'claude-haiku-4-5-20251001',
        );
        expect(datedProfile.imageSupport, RouteImageSupport.unsupported);
      });
    });

    test('production startup warmup prepares catalog before admission with zero HTTP at admission', () async {
      final repo = _FakeProviderInstanceRepository();
      repo.instances['custom-p'] = ProviderInstance(
        id: 'custom-p',
        templateId: kCustomProviderTemplateId,
        displayName: 'Custom Provider',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      int httpCalls = 0;
      final tempDir = Directory.systemTemp.createTempSync('mdev-warmup-test-');
      final modelsDev = ModelsDevService(
        cacheFilePathOverride: '${tempDir.path}/models_dev_cache.json',
        client: MockClient((request) async {
          httpCalls++;
          return http.Response(
            jsonEncode({
              'anthropic': {
                'api': 'https://api.anthropic.com',
                'models': {
                  'claude-haiku-4-5': {
                    'modalities': {
                      'input': ['text', 'image'],
                    },
                  },
                },
              },
            }),
            200,
          );
        }),
      );

      // 1. Startup warmup phase
      await modelsDev.ensureLoaded();
      expect(httpCalls, 1, reason: 'Warmup hydrates catalog once at startup');

      final resolver = RouteCapabilityResolver(
        instances: repo,
        modelsDevService: modelsDev,
      );

      // 2. Turn admission phase: synchronously resolves capabilities without HTTP
      final profile = resolver.resolveSync(
        providerInstanceId: 'custom-p',
        modelId: 'claude-haiku-4.5',
      );
      expect(profile.imageSupport, RouteImageSupport.supported);
      expect(profile.evidenceSource, 'catalog');
      expect(httpCalls, 1, reason: 'Zero HTTP calls during turn admission');
    });
  });
}

class _FakeProviderInstanceRepository implements ProviderInstanceRepository {
  final Map<String, ProviderInstance> instances = {};
  final Map<String, Map<String, dynamic>> modelCaches = {};

  @override
  ProviderInstance? findById(String id) => instances[id];

  @override
  Map<String, dynamic>? readModelCache(String instanceId, String cacheKey) {
    return modelCaches['$instanceId:$cacheKey'];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
