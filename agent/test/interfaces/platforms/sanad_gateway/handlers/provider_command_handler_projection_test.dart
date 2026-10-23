// Characterization coverage for `ProviderCommandHandler` projections
// (plan 138-06 / A5).
//
// Second half of the direct handler suite: the bounded `model.snapshot`
// projection, the two-stage `model.refresh` delivery, recent-selection
// projection, and the capability/configured-provider projections. The routing
// spine, readiness, and instance/credential lifecycle live in
// `provider_command_handler_test.dart`.

import 'dart:async';
import 'dart:convert';

import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/recent_model_selection_service.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:test/test.dart';

import 'support/provider_handler_harness.dart';

void main() {
  final h = installProviderHandlerHarness();

  group('model snapshot projection', () {
    test('the instance projection is a bounded key set', () async {
      h.createInstance();

      final snapshot =
          (h.payloadOf(await h.snapshot())['instances'] as List).single as Map;

      expect(snapshot.keys.toSet(), {
        'id',
        'display_name',
        'default_model',
        'status',
        'is_default',
        'cache_status',
        'fetched_at',
        'warning',
        'models',
      });
      expect(snapshot.containsKey('template_id'), isFalse);
      expect(snapshot.containsKey('credential'), isFalse);
    });

    test(
      'an empty snapshot reports no instances, recents, or default',
      () async {
        final payload = h.payloadOf(
          await h.snapshot(body: {'request_id': 's'}),
        );

        expect(payload['request_id'], 's');
        expect(payload['instances'], isEmpty);
        expect(payload['recent'], isEmpty);
        expect(payload['default_instance_id'], isNull);
      },
    );

    test('an instance without a cache row reports empty', () async {
      h.createInstance();

      final snapshot =
          (h.payloadOf(await h.snapshot())['instances'] as List).single as Map;

      expect(snapshot['cache_status'], 'empty');
      expect(snapshot['models'], isEmpty);
      expect(snapshot['fetched_at'], isNull);
      expect(snapshot['warning'], isNull);
    });

    test(
      'a verified cache row is ready and never carries model_metadata',
      () async {
        final instance = h.createInstance();
        h.repo.upsertModelCache(
          instanceId: instance.id,
          cacheKey: 'models',
          models: const [
            {
              'value': 'openai/gpt-4o',
              'label': 'GPT-4o',
              'supports_reasoning': true,
              'model_metadata': {'raw': 'provider payload'},
            },
            {'value': 'models/gpt-4o-mini'},
            'not-a-map',
          ],
          fetchedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
          source: 'live',
          configRevision: instance.configRevision,
          credentialRevision: instance.credentialRevision,
        );

        final envelope = await h.snapshot(body: {'request_id': 'req-snapshot'});
        final snapshot =
            (h.payloadOf(envelope)['instances'] as List).single as Map;
        final models = snapshot['models'] as List;

        expect(snapshot['cache_status'], 'ready');
        expect(snapshot['fetched_at'], '2026-01-02T03:04:05.000Z');
        expect(snapshot['warning'], isNull);

        final first = Map<String, dynamic>.from(models[0] as Map);
        expect(first['value'], 'gpt-4o');
        expect(first['id'], 'gpt-4o');
        expect(first['name'], 'GPT-4o');
        expect(first['supports_reasoning'], isTrue);
        expect(first['supports_reasoning_output'], isTrue);
        expect(first.containsKey('model_metadata'), isFalse);

        final second = Map<String, dynamic>.from(models[1] as Map);
        expect(second['value'], 'gpt-4o-mini');
        expect(second['id'], 'gpt-4o-mini');
        expect(second.containsKey('name'), isFalse);

        // Non-map cache entries pass through untouched.
        expect(models[2], 'not-a-map');
        expect(jsonEncode(envelope), isNot(contains('model_metadata')));
        expect(jsonEncode(envelope), isNot(contains('provider payload')));
      },
    );

    test('a stale cache row keeps its models but reports stale', () async {
      final instance = h.createInstance();
      h.repo.upsertModelCache(
        instanceId: instance.id,
        cacheKey: 'models',
        models: const [
          {'value': 'gpt-4o'},
        ],
        fetchedAt: DateTime.utc(2026, 1, 2),
        source: 'live',
        configRevision: instance.configRevision + 5,
        credentialRevision: instance.credentialRevision,
      );

      final snapshot =
          (h.payloadOf(await h.snapshot())['instances'] as List).single as Map;

      expect(snapshot['cache_status'], 'stale');
      expect(snapshot['models'], hasLength(1));
    });

    test('a failed row without models reports error while a partial failure '
        'stays ready', () async {
      final failing = h.createInstance(displayName: 'Failing');
      h.repo.upsertModelCache(
        instanceId: failing.id,
        cacheKey: 'models',
        models: const [],
        fetchedAt: DateTime.utc(2026, 1, 2),
        source: 'cache_stale',
        configRevision: failing.configRevision,
        credentialRevision: failing.credentialRevision,
        lastError: 'Connection refused',
      );
      final partial = h.createInstance(displayName: 'Partial');
      h.repo.upsertModelCache(
        instanceId: partial.id,
        cacheKey: 'models',
        models: const [
          {'value': 'gpt-4o'},
        ],
        fetchedAt: DateTime.utc(2026, 1, 2),
        source: 'cache_stale',
        configRevision: partial.configRevision,
        credentialRevision: partial.credentialRevision,
        lastError: 'Refresh timed out',
      );

      final instances = h.payloadOf(await h.snapshot())['instances'] as List;
      final failingEntry =
          instances.firstWhere((entry) => (entry as Map)['id'] == failing.id)
              as Map;
      final partialEntry =
          instances.firstWhere((entry) => (entry as Map)['id'] == partial.id)
              as Map;

      expect(failingEntry['cache_status'], 'error');
      expect(failingEntry['warning'], 'Connection refused');
      expect(failingEntry['models'], isEmpty);
      // The warning survives a successful partial fetch without downgrading
      // the cache status.
      expect(partialEntry['cache_status'], 'ready');
      expect(partialEntry['warning'], 'Refresh timed out');
    });

    test(
      'default_model is normalized on read even for a raw stored value',
      () async {
        h.repo.createInstance(
          ProviderInstance(
            id: 'legacy-raw-model',
            templateId: 'openai',
            displayName: 'Legacy',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'openai/gpt-4o',
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        );

        final snapshot =
            (h.payloadOf(await h.snapshot())['instances'] as List).single
                as Map;

        expect(snapshot['default_model'], 'gpt-4o');
      },
    );

    test('a default instance is projected as default_instance_id', () async {
      final instance = h.createInstance();
      h.repo.setDefault(instance.id);

      final payload = h.payloadOf(await h.snapshot());

      expect(payload['default_instance_id'], instance.id);
      expect(
        ((payload['instances'] as List).single as Map)['is_default'],
        isTrue,
      );
    });

    test('recent selections are listed with normalized model ids', () async {
      final instance = h.createInstance();
      RecentModelSelectionService(h.repo).selectModel(
        instanceId: instance.id,
        modelId: 'openai/gpt-4o',
        selectedAt: DateTime.utc(2026, 3, 1),
      );

      final envelope = await h.recentList(body: {'request_id': 'req-recent'});
      final recentList = h.payloadOf(envelope)['recent'] as List;
      final entry = Map<String, dynamic>.from(recentList.single as Map);

      expect(envelope['event'], CanonicalEventTypes.modelRecentResult);
      expect(recentList, hasLength(1));
      expect(entry['instance_id'], instance.id);
      expect(entry['model_id'], 'gpt-4o');
      expect(entry['instance_display_name'], 'OpenAI Work');
    });

    test('model.recent.record echoes the submitted id and stores the '
        'normalized id', () async {
      final instance = h.createInstance();

      final envelope = await h.recentRecord({
        'request_id': 'req-record',
        'provider_instance_id': instance.id,
        'model_id': 'openai/gpt-4o',
      });

      expect(envelope['event'], CanonicalEventTypes.modelRecentRecorded);
      // Current behavior: the echo keeps the submitted value while the stored
      // selection is normalized.
      expect(h.payloadOf(envelope)['model_id'], 'openai/gpt-4o');
      expect(
        RecentModelSelectionService(
          h.repo,
        ).getRecentSelections().single['model_id'],
        'gpt-4o',
      );
    });
  });

  group('model refresh two-stage delivery', () {
    test('started is emitted first and the terminal failure is a family '
        'event', () async {
      final envelopes = <Map<String, dynamic>>[];
      final terminal = Completer<void>();

      await h.handler.handleModelRefreshCommand(
        h.event(CanonicalEventTypes.modelRefresh, {
          'request_id': 'req-refresh',
          'provider_instance_id': 'missing-id',
          'manual': true,
        }),
        (envelope) async {
          envelopes.add(envelope);
          if (envelopes.length == 2 && !terminal.isCompleted) {
            terminal.complete();
          }
        },
      );

      expect(envelopes, hasLength(1));
      expect(envelopes.single['event'], CanonicalEventTypes.modelCacheUpdated);
      final started = h.payloadOf(envelopes.single);
      expect(started['status'], 'started');
      expect(started['request_id'], 'req-refresh');
      expect((envelopes.single['delivery'] as Map)['scope'], 'origin');

      await terminal.future;

      final finished = envelopes.last;
      final finishedPayload = h.payloadOf(finished);
      expect(finished['event'], CanonicalEventTypes.modelCacheUpdated);
      expect(finishedPayload['status'], 'failed');
      expect(finishedPayload['error'], contains('Instance not found'));
      expect(finishedPayload['request_id'], 'req-refresh');
      final delivery = finished['delivery'] as Map;
      expect(delivery['scope'], 'platform_family');
      expect(delivery['platform_family'], PlatformFamily.sanadClient.value);
    });

    test('an uncorrelated refresh omits request_id from both stages', () async {
      final envelopes = <Map<String, dynamic>>[];
      final terminal = Completer<void>();

      await h.handler.handleModelRefreshCommand(
        h.event(CanonicalEventTypes.modelRefresh, {
          'provider_instance_id': 'missing-id',
        }),
        (envelope) async {
          envelopes.add(envelope);
          if (envelopes.length == 2 && !terminal.isCompleted) {
            terminal.complete();
          }
        },
      );
      await terminal.future;

      expect(envelopes, hasLength(2));
      for (final envelope in envelopes) {
        expect(envelope.containsKey('request_id'), isFalse);
        expect(h.payloadOf(envelope).containsKey('request_id'), isFalse);
      }
    });

    test('a terminal delivery failure stays contained', () async {
      var calls = 0;

      await h.handler.handleModelRefreshCommand(
        h.event(CanonicalEventTypes.modelRefresh, {
          'provider_instance_id': 'missing-id',
        }),
        (envelope) async {
          calls += 1;
          if (calls == 2) {
            throw StateError('emit failed');
          }
        },
      );

      await pumpEventQueue();

      expect(calls, 2);
      // The handler survives the delivery failure and keeps serving commands.
      final envelope = await h.templates();
      expect(envelope['event'], CanonicalEventTypes.providerTemplatesResult);
    });
  });

  group('capability and model selection projections', () {
    test(
      'capabilities_changed is a family event with the active route',
      () async {
        final envelope = await h.capabilities(body: {'request_id': 'req-caps'});

        expect(envelope['event'], CanonicalEventTypes.capabilitiesChanged);
        final delivery = envelope['delivery'] as Map;
        expect(delivery['scope'], 'platform_family');
        expect(delivery['platform_family'], PlatformFamily.sanadClient.value);

        final payload = h.payloadOf(envelope);
        expect(payload['active_provider'], 'openai');
        expect(payload['active_model'], h.config.llmModel);
        final groups = payload['configured_providers'] as List;
        final openaiGroup =
            groups.firstWhere(
                  (group) => (group as Map)['provider_id'] == 'openai',
                )
                as Map;
        expect(openaiGroup['runtime_ready'], isTrue);
        expect(openaiGroup['display_name'], isNotEmpty);
        // Live discovery is forced here, so the fallback path is visible.
        final models = openaiGroup['models'] as Map;
        expect(models['source'], 'fallback');
        expect(
          models['warning'],
          'Live model list unavailable; using fallback presets.',
        );
      },
    );

    test(
      'instances broadcast is a family event with credential summaries',
      () async {
        h.createInstance();

        final envelope = await h.instancesChanged();

        expect(envelope['event'], CanonicalEventTypes.providerInstancesChanged);
        final delivery = envelope['delivery'] as Map;
        expect(delivery['scope'], 'platform_family');
        expect(delivery['platform_family'], PlatformFamily.sanadClient.value);
        final list = h.payloadOf(envelope)['instances'] as List;
        expect(list, hasLength(1));
        expect((list.single as Map)['credential'], isA<Map>());
        expect(envelope.toString(), isNot(contains(harnessApiKey)));
      },
    );

    test('model.options resolves one provider or every provider', () async {
      final single = await h.modelOptions({
        'request_id': 'req-options',
        'provider_id': 'openai',
      });
      final options = h.payloadOf(single)['options'] as List;

      expect(single['event'], CanonicalEventTypes.modelOptionsResult);
      expect(options, hasLength(1));
      expect((options.single as Map)['provider_id'], 'openai');
      // `fetch_live` defaults to false on this command.
      expect((options.single as Map)['source'], 'fallback');

      final all = await h.modelOptions(const {});
      expect(
        h.payloadOf(all)['options'],
        hasLength(ProviderRegistry.profiles.length),
      );
    });

    test(
      'model.recommended_default and model.set_default project the model',
      () async {
        final recommended = await h.recommendedDefault({
          'request_id': 'req-recommended',
          'provider_id': 'openai',
        });

        expect(
          recommended['event'],
          CanonicalEventTypes.modelRecommendedDefaultResult,
        );
        expect(h.payloadOf(recommended)['model'], 'gpt-4o-mini');

        final applied = await h.setDefaultModel({
          'request_id': 'req-set-default',
          'provider_id': 'openai',
          'model': 'gpt-4o',
        });
        final payload = h.payloadOf(applied);

        expect(applied['event'], CanonicalEventTypes.modelSetDefaultResult);
        expect(payload['model'], 'gpt-4o');
        expect(payload['saved'], isTrue);
        expect(h.env.get('ACTIVE_PROVIDER'), 'openai');
        expect(h.env.get('LLM_MODEL'), 'gpt-4o');
      },
    );
  });
}
