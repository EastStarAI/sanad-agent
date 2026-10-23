// Characterization coverage for `ProviderCommandHandler` (plan 138-06 / A5).
//
// The handler had no direct suite: it was only reached through
// `sanad_bridge_provider*_test.dart`. These tests pin command-to-envelope
// routing, validation errors, readiness projection, instance/credential
// lifecycle, and the auth flows so the deferred split can prove parity.
//
// This is a snapshot of current behavior, not a specification of desired
// behavior. The model snapshot, refresh, and capability projections live in
// `provider_command_handler_projection_test.dart`.

import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/secret_record.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:test/test.dart';

import 'support/provider_handler_harness.dart';

void main() {
  final h = installProviderHandlerHarness();

  group('envelope spine and command routing', () {
    test('provider.setup_status maps to provider_readiness_result', () async {
      final envelope = await h.setupStatus(body: {'request_id': 'req-setup'});

      expect(envelope['type'], 'event');
      expect(envelope['event'], CanonicalEventTypes.providerReadinessResult);
      expect(envelope['request_id'], 'req-setup');
      expect(envelope['device_id'], harnessHardwareId);
      expect(envelope['hardware_id'], harnessHardwareId);
      expect(envelope['event_id'], isNotNull);
      expect(envelope.containsKey('session_id'), isFalse);
      expect(envelope.containsKey('run_id'), isFalse);
      expect(h.payloadOf(envelope)['request_id'], 'req-setup');
    });

    test('provider.runtime_check maps to the same readiness result', () async {
      final envelope = await h.runtimeCheck(body: {'request_id': 'req-rt'});

      expect(envelope['event'], CanonicalEventTypes.providerReadinessResult);
      expect(h.payloadOf(envelope)['request_id'], 'req-rt');
    });

    test('an uncorrelated command carries no top-level request_id', () async {
      final envelope = await h.recommendedDefault({'provider_id': 'openai'});

      expect(
        envelope['event'],
        CanonicalEventTypes.modelRecommendedDefaultResult,
      );
      expect(envelope.containsKey('request_id'), isFalse);
      // The payload always carries the key, even when it is null.
      expect(h.payloadOf(envelope).containsKey('request_id'), isTrue);
      expect(h.payloadOf(envelope)['request_id'], isNull);
    });

    test('every envelope gets its own opaque event id', () async {
      final first = await h.authCancel({'session_id': 's-1'});
      final second = await h.authCancel({'session_id': 's-1'});

      expect(first['event_id'], isNotNull);
      expect(first['event_id'], isNot(equals(second['event_id'])));
    });

    test('provider.templates.list maps to provider_templates.result', () async {
      final envelope = await h.templates(body: {'request_id': 'req-tpl'});

      expect(envelope['event'], CanonicalEventTypes.providerTemplatesResult);
      expect(h.payloadOf(envelope)['templates'], isNotEmpty);
    });

    test(
      'provider.instances.list is newest first with a credential summary',
      () async {
        h.createInstance(displayName: 'Older', now: DateTime.utc(2026, 1, 1));
        h.createInstance(displayName: 'Newer', now: DateTime.utc(2026, 2, 1));

        final envelope = await h.instancesList(body: {'request_id': 'req-l'});
        final list = h.payloadOf(envelope)['instances'] as List;

        expect(envelope['event'], CanonicalEventTypes.providerInstancesResult);
        expect(list, hasLength(2));
        expect((list.first as Map)['display_name'], 'Newer');
        expect((list.last as Map)['display_name'], 'Older');
        // Unlike the bounded `model.snapshot` projection, this one keeps the
        // full stored instance shape.
        expect((list.first as Map)['template_id'], 'openai');
        final credential = Map<String, dynamic>.from(
          (list.first as Map)['credential'] as Map,
        );
        expect(credential['configured'], isFalse);
        expect(credential['status'], 'missing');
      },
    );

    test('provider.configured_options maps to its result event', () async {
      final envelope = await h.configuredOptions(
        body: {'request_id': 'req-cfg'},
      );

      expect(
        envelope['event'],
        CanonicalEventTypes.providerConfiguredOptionsResult,
      );
      expect(h.payloadOf(envelope)['groups'], isNotEmpty);
    });

    test('provider.usage commands answer without a usage service', () async {
      final get = await h.usageGet({
        'request_id': 'req-usage',
        'provider_instance_id': 'instance-x',
      });
      final getPayload = h.payloadOf(get);
      expect(get['event'], CanonicalEventTypes.providerUsageResult);
      expect(getPayload['status'], 'unsupported');
      expect(getPayload['provider_instance_id'], 'instance-x');
      expect(getPayload['request_id'], 'req-usage');
      expect(getPayload.containsKey('message'), isFalse);

      final reset = await h.usageReset({
        'request_id': 'req-reset',
        'provider_instance_id': 'instance-x',
      });
      final resetPayload = h.payloadOf(reset);
      expect(reset['event'], CanonicalEventTypes.providerUsageResetResult);
      expect(resetPayload['status'], 'unsupported');
      expect(
        resetPayload['message'],
        'Usage resets are not supported for this account.',
      );

      final support = await h.usageSupport({
        'request_id': 'req-support',
        'provider_instance_ids': ['instance-x', 'instance-y'],
      });
      expect(support['event'], CanonicalEventTypes.providerUsageSupportResult);
      // Without a usage service nothing claims support, even when asked.
      expect(h.payloadOf(support)['support'], isEmpty);
    });
  });

  group('readiness projection', () {
    test('no instance reports has_provider false and a reason', () async {
      final payload = h.payloadOf(await h.setupStatus());

      expect(payload['has_provider'], isFalse);
      expect(payload['runtime_ready'], isFalse);
      expect(payload['reason'], 'No provider instance is configured.');
      expect(payload.containsKey('active_provider'), isFalse);
    });

    test(
      'a draft default projects runtime_ready false with its status',
      () async {
        h.createInstance(makeDefault: true);

        final payload = h.payloadOf(await h.runtimeCheck());

        expect(payload['has_provider'], isTrue);
        expect(payload['runtime_ready'], isFalse);
        expect(payload['active_model'], 'gpt-4o');
        expect(payload['reason'], 'Instance status: draft');
      },
    );

    test('a ready instance without a stored credential passes setup and fails '
        'the runtime check', () async {
      final instance = h.createInstance(makeDefault: true);
      h.instances.markReady(instance.id);

      final setup = h.payloadOf(await h.setupStatus());
      final runtimePayload = h.payloadOf(await h.runtimeCheck());

      expect(setup['runtime_ready'], isTrue);
      expect(setup.containsKey('reason'), isFalse);
      expect(runtimePayload['runtime_ready'], isFalse);
      expect(
        runtimePayload['reason'],
        'API key is required but not configured.',
      );
    });

    test(
      'a ready instance with a stored credential is runtime ready',
      () async {
        final instance = h.createInstance(makeDefault: true);
        await h.credentials.applyApiKeyEdit(
          instance.id,
          action: CredentialAction.replace,
          newApiKey: harnessApiKey,
        );
        h.instances.markReady(instance.id);

        final payload = h.payloadOf(await h.runtimeCheck());

        expect(payload['has_provider'], isTrue);
        expect(payload['runtime_ready'], isTrue);
        expect(payload['active_provider'], instance.id);
        expect(payload['active_model'], 'gpt-4o');
        expect(payload.containsKey('reason'), isFalse);
      },
    );
  });

  group('instance lifecycle', () {
    test('create persists a draft, honours is_default, and invalidates the '
        'runtime cache', () async {
      final envelope = await h.instanceCreate({
        'request_id': 'req-create',
        'template_id': 'openai',
        'display_name': 'Work OpenAI',
        'auth_method': ProviderAuthMethod.apiKey,
        'is_default': true,
        'default_model': 'gpt-4o',
      });

      final instance = Map<String, dynamic>.from(
        h.payloadOf(envelope)['instance'] as Map,
      );
      expect(envelope['event'], CanonicalEventTypes.providerInstanceCreated);
      expect(instance['display_name'], 'Work OpenAI');
      expect(instance['status'], InstanceStatus.draft);
      // Creation sets the flag directly; unlike set_default it accepts drafts.
      expect(instance['is_default'], isTrue);
      expect(instance['requests_per_minute'], 0);
      expect(h.repo.findAll(), hasLength(1));
      expect(h.runtime.invalidations, 1);
    });

    test('create returns an error envelope for an unknown template and leaves '
        'runtime state untouched', () async {
      final envelope = await h.instanceCreate({
        'request_id': 'req-unknown',
        'template_id': 'does-not-exist',
        'display_name': 'Nope',
        'auth_method': ProviderAuthMethod.apiKey,
      });

      expect(envelope['event'], CanonicalEventTypes.providerInstanceCreated);
      expect(h.payloadOf(envelope)['error'], contains('Unknown provider'));
      expect(h.repo.findAll(), isEmpty);
      expect(h.runtime.invalidations, 0);
    });

    test(
      'create rejects duplicate and blank display names as error envelopes',
      () async {
        h.createInstance(displayName: 'Taken');

        final duplicate = await h.instanceCreate({
          'template_id': 'openai',
          'display_name': 'Taken',
          'auth_method': ProviderAuthMethod.apiKey,
        });
        expect(
          h.payloadOf(duplicate)['error'],
          contains('Display name "Taken" is already in use.'),
        );

        final blank = await h.instanceCreate({
          'template_id': 'openai',
          'display_name': '   ',
          'auth_method': ProviderAuthMethod.apiKey,
        });
        expect(
          h.payloadOf(blank)['error'],
          contains('Display name is required.'),
        );
        expect(h.repo.findAll(), hasLength(1));
      },
    );

    test('update of a missing instance throws instead of enveloping', () async {
      await expectLater(
        h.instanceUpdate({
          'provider_instance_id': 'missing-id',
          'display_name': 'Renamed',
        }),
        throwsA(isA<StateError>()),
      );
    });

    test('update ignores a blank name and demotes a ready instance when the '
        'base URL changes', () async {
      final instance = h.createInstance(displayName: 'Original');
      await h.credentials.applyApiKeyEdit(
        instance.id,
        action: CredentialAction.replace,
        newApiKey: harnessApiKey,
      );
      h.seedVerifiedCache(instance.id);
      expect(h.repo.findById(instance.id)!.status, InstanceStatus.ready);

      final blank = await h.instanceUpdate({
        'provider_instance_id': instance.id,
        'display_name': '   ',
      });
      expect(
        (h.payloadOf(blank)['instance'] as Map)['display_name'],
        'Original',
      );

      final changed = await h.instanceUpdate({
        'request_id': 'req-update',
        'provider_instance_id': instance.id,
        'display_name': 'Renamed',
        'base_url': 'https://gateway.example.invalid/v1/',
      });
      final updated = Map<String, dynamic>.from(
        h.payloadOf(changed)['instance'] as Map,
      );

      expect(changed['event'], CanonicalEventTypes.providerInstanceUpdated);
      expect(updated['display_name'], 'Renamed');
      expect(updated['base_url'], 'https://gateway.example.invalid/v1');
      expect(updated['config_revision'], instance.configRevision + 1);
      // The verified cache belongs to the previous revision, so the instance
      // leaves `ready` until discovery runs again.
      expect(updated['status'], InstanceStatus.draft);
    });

    test('rename rejects blank and duplicate names', () async {
      final instance = h.createInstance(displayName: 'First');
      h.createInstance(displayName: 'Second');

      await expectLater(
        h.instanceRename({
          'provider_instance_id': instance.id,
          'display_name': '',
        }),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        h.instanceRename({
          'provider_instance_id': instance.id,
          'display_name': 'Second',
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test(
      'rename succeeds without invalidating the runtime adapter cache',
      () async {
        final instance = h.createInstance(displayName: 'Before');

        final envelope = await h.instanceRename({
          'request_id': 'req-rename',
          'provider_instance_id': instance.id,
          'display_name': 'After',
        });

        expect(envelope['event'], CanonicalEventTypes.providerInstanceRenamed);
        expect(
          (h.payloadOf(envelope)['instance'] as Map)['display_name'],
          'After',
        );
        expect(h.runtime.invalidations, 0);
      },
    );

    test('remove drops the secret and the row before replying', () async {
      final instance = h.createInstance();
      await h.credentials.applyApiKeyEdit(
        instance.id,
        action: CredentialAction.replace,
        newApiKey: harnessApiKey,
      );
      expect(h.secrets.listIds(), [instance.id]);

      final envelope = await h.instanceRemove({
        'request_id': 'req-remove',
        'provider_instance_id': instance.id,
      });
      final payload = h.payloadOf(envelope);

      expect(envelope['event'], CanonicalEventTypes.providerInstanceRemoved);
      expect(payload['provider_instance_id'], instance.id);
      expect(payload['removed'], isTrue);
      expect(h.repo.findById(instance.id), isNull);
      expect(h.secrets.listIds(), isEmpty);
      expect(h.runtime.invalidations, 1);
    });

    test(
      'set_default rejects a non-ready instance and promotes a ready one',
      () async {
        final instance = h.createInstance();
        await expectLater(
          h.instanceSetDefault({'provider_instance_id': instance.id}),
          throwsA(isA<StateError>()),
        );

        await h.credentials.applyApiKeyEdit(
          instance.id,
          action: CredentialAction.replace,
          newApiKey: harnessApiKey,
        );
        h.seedVerifiedCache(instance.id);
        final envelope = await h.instanceSetDefault({
          'request_id': 'req-default',
          'provider_instance_id': instance.id,
        });

        expect(
          envelope['event'],
          CanonicalEventTypes.providerInstanceDefaultChanged,
        );
        expect(h.payloadOf(envelope)['is_default'], isTrue);
        expect(h.repo.findDefault()!.id, instance.id);
        expect(h.runtime.invalidations, 1);
      },
    );

    test(
      'instance test reports an unknown instance as a contained failure',
      () async {
        final envelope = await h.instanceTest({
          'request_id': 'req-test',
          'provider_instance_id': 'missing-id',
        });
        final payload = h.payloadOf(envelope);

        expect(
          envelope['event'],
          CanonicalEventTypes.providerInstanceTestResult,
        );
        expect(payload['success'], isFalse);
        expect(payload['error'], contains('Instance not found'));
        expect(payload.containsKey('models_count'), isFalse);
      },
    );
  });

  group('credentials and auth', () {
    test('credential replace stores a masked summary and invalidates the '
        'runtime', () async {
      final instance = h.createInstance();

      final envelope = await h.credentialUpdate({
        'request_id': 'req-cred',
        'provider_instance_id': instance.id,
        'action': CredentialAction.replace,
        'api_key': harnessApiKey,
      });
      final credential = Map<String, dynamic>.from(
        h.payloadOf(envelope)['credential'] as Map,
      );

      expect(envelope['event'], CanonicalEventTypes.providerCredentialUpdated);
      expect(credential['configured'], isTrue);
      expect(credential['masked_key_hint'], maskApiKey(harnessApiKey));
      expect(envelope.toString(), isNot(contains(harnessApiKey)));
      expect(h.repo.findById(instance.id)!.status, InstanceStatus.draft);
      expect(h.runtime.invalidations, 1);
    });

    test('credential replace without a key and an unknown action are error '
        'envelopes', () async {
      final instance = h.createInstance();

      final missingKey = await h.credentialUpdate({
        'provider_instance_id': instance.id,
        'action': CredentialAction.replace,
      });
      expect(
        h.payloadOf(missingKey)['error'],
        contains('replace requires a non-empty API key.'),
      );

      final unknown = await h.credentialUpdate({
        'provider_instance_id': instance.id,
        'action': 'sabotage',
      });
      expect(
        h.payloadOf(unknown)['error'],
        contains('Unknown credential action: sabotage'),
      );
      expect(h.runtime.invalidations, 0);
    });

    test(
      'auth.start requires an instance id and rejects api-key instances',
      () async {
        final noInstance = await h.authStart({
          'request_id': 'req-auth-start',
          'provider_id': 'openai-codex',
          'template_id': 'openai-codex',
        });
        expect(noInstance['event'], CanonicalEventTypes.providerAuthStarted);
        expect(
          h.payloadOf(noInstance)['error'],
          contains('provider_instance_id is required for provider.auth.start.'),
        );

        final instance = h.createInstance();
        final apiKey = await h.authStart({
          'provider_instance_id': instance.id,
          'template_id': 'openai',
          'auth_method': ProviderAuthMethod.apiKey,
        });
        expect(h.payloadOf(apiKey)['error'], contains('has no OAuth flow'));
      },
    );

    test(
      'auth.poll and auth.submit report unknown sessions as errors',
      () async {
        final polled = await h.authPoll({
          'request_id': 'req-poll',
          'session_id': 'unknown-session',
        });
        final pollPayload = h.payloadOf(polled);
        expect(polled['event'], CanonicalEventTypes.providerAuthPolled);
        expect(pollPayload['session_id'], 'unknown-session');
        expect(pollPayload['status'], 'error');
        expect(pollPayload['error'], 'Session not found or already completed.');

        final submitted = await h.authSubmit({
          'session_id': 'unknown-session',
          'code': 'ABCD-1234',
        });
        final submitPayload = h.payloadOf(submitted);
        expect(submitted['event'], CanonicalEventTypes.providerAuthPolled);
        expect(submitPayload['status'], 'error');
        expect(
          submitPayload['error'],
          'Manual code submission is not supported for this flow.',
        );
      },
    );

    test('auth.cancel acknowledges even an unknown session', () async {
      final envelope = await h.authCancel({
        'request_id': 'req-cancel',
        'session_id': 'unknown-session',
      });
      final payload = h.payloadOf(envelope);

      expect(envelope['event'], CanonicalEventTypes.providerAuthCancelled);
      expect(payload['session_id'], 'unknown-session');
      expect(payload['cancelled'], isTrue);
    });

    test(
      'auth.status prefers the instance key and omits it when absent',
      () async {
        h.createInstance();
        final instance = h.createInstance(displayName: 'Second');
        await h.credentials.applyApiKeyEdit(
          instance.id,
          action: CredentialAction.replace,
          newApiKey: harnessApiKey,
        );

        final instanceScoped = await h.authStatus({
          'request_id': 'req-status',
          'provider_id': 'openai',
          'provider_instance_id': instance.id,
        });
        final instancePayload = h.payloadOf(instanceScoped);
        expect(
          instanceScoped['event'],
          CanonicalEventTypes.providerAuthStatusResult,
        );
        expect(instancePayload['provider_instance_id'], instance.id);
        expect(instancePayload['status'], 'authenticated');

        final providerScoped = await h.authStatus({'provider_id': 'openai'});
        final providerPayload = h.payloadOf(providerScoped);
        expect(providerPayload.containsKey('provider_instance_id'), isFalse);
        expect(providerPayload['status'], 'missing');
      },
    );

    test('auth.reconnect throws for a missing instance and envelops an api-key '
        'instance', () async {
      await expectLater(
        h.authReconnect({'provider_instance_id': 'missing-id'}),
        throwsA(isA<StateError>()),
      );

      final instance = h.createInstance();
      final envelope = await h.authReconnect({
        'request_id': 'req-reconnect',
        'provider_instance_id': instance.id,
      });
      expect(envelope['event'], CanonicalEventTypes.providerAuthStarted);
      expect(h.payloadOf(envelope)['error'], contains('has no OAuth flow'));
    });

    test(
      'auth.disconnect drops the stored secret and marks needs_auth',
      () async {
        final instance = h.createInstance(
          templateId: 'openai-codex',
          displayName: 'ChatGPT',
        );
        await h.secrets.write(
          instance.id,
          SecretRecord(
            instanceId: instance.id,
            accessToken: 'fake-access-token',
            authMethod: ProviderAuthMethod.deviceCode,
          ),
        );
        expect(h.secrets.listIds(), [instance.id]);

        final envelope = await h.authDisconnect({
          'request_id': 'req-disconnect',
          'provider_instance_id': instance.id,
        });

        expect(envelope['event'], CanonicalEventTypes.providerInstanceUpdated);
        expect(h.payloadOf(envelope)['disconnected'], isTrue);
        expect(h.secrets.listIds(), isEmpty);
        expect(h.repo.findById(instance.id)!.status, InstanceStatus.needsAuth);
        expect(h.runtime.invalidations, 1);
      },
    );
  });
}
