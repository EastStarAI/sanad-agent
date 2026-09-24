import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_usage_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_state.dart';

const _localDeviceId = 'hardware-1';

/// Fake [ProviderSetupClient] that records calls and returns scripted usage
/// results. Used to exercise the freshness / staleness / disposal logic of
/// [ProviderUsageCubit] without touching the socket.
class _FakeUsageClient implements ProviderSetupClient {
  _FakeUsageClient();

  /// Per-instance scripted results keyed by provider_instance_id.
  /// Defaults to `available` if no entry exists.
  Map<String, ProviderUsageResultDto> usageResults = {};

  /// Per-instance scripted support answers (default: no entry =? we return a
  /// generic "all supported" map from [usageSupport] below).
  Map<String, bool> supportMap = {};

  /// Recorded call log: (command, instanceId).
  final List<(String, String)> calls = [];

  /// Toggleable latency for the `usageGet` call. Tests use this to surface
  /// pending responses.
  Future<void> Function()? usageGetLatency;
  Future<void> Function()? usageSupportLatency;
  Future<void> Function()? usageResetLatency;
  final List<(String, String, String?)> resetCalls = [];
  ProviderUsageResetResultDto? resetResult;

  /// `model.snapshot` call count and scripted instance list (97h catalog).
  int modelSnapshotCalls = 0;
  List<ModelCacheInstanceDto> scriptedInstances = const [
    ModelCacheInstanceDto(
      id: 'a',
      displayName: 'Provider A',
      status: 'ready',
      isDefault: true,
      cacheStatus: 'fetched',
      models: [],
    ),
  ];

  @override
  Future<ProviderUsageResultDto> usageGet({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async {
    calls.add(('get', providerInstanceId));
    await usageGetLatency?.call();
    return usageResults[providerInstanceId] ??
        ProviderUsageResultDto(
          status: 'available',
          providerInstanceId: providerInstanceId,
          snapshot: ProviderUsageSnapshotDto(
            providerInstanceId: providerInstanceId,
            providerTemplateId: 'openai-codex',
            source: 'test',
            fetchedAt: DateTime.now().toUtc(),
            windows: [
              ProviderUsageWindowDto(
                type: 'weekly',
                label: 'Weekly',
                usedPercent: 42.0,
              ),
            ],
            availableResets: 0,
          ),
        );
  }

  @override
  Future<ProviderUsageResetResultDto> usageReset({
    required String providerInstanceId,
    required String idempotencyKey,
    String? confirmationToken,
    DeviceConfig? agent,
  }) async {
    resetCalls.add((providerInstanceId, idempotencyKey, confirmationToken));
    await usageResetLatency?.call();
    return resetResult ??
        ProviderUsageResetResultDto(
          status: 'reset',
          providerInstanceId: providerInstanceId,
          message: 'Usage limits were reset successfully.',
        );
  }

  @override
  Future<ProviderUsageSupportDto> usageSupport({
    required List<String> providerInstanceIds,
    DeviceConfig? agent,
  }) async {
    calls.add(('support', providerInstanceIds.join(',')));
    await usageSupportLatency?.call();
    final map = <String, bool>{};
    for (final id in providerInstanceIds) {
      map[id] = supportMap[id] ?? true;
    }
    return ProviderUsageSupportDto(support: map);
  }

  @override
  Future<ModelCacheSnapshotDto> modelSnapshot({DeviceConfig? agent}) async {
    modelSnapshotCalls += 1;
    return ModelCacheSnapshotDto(
      instances: scriptedInstances,
      recent: const [],
    );
  }

  @override
  Future<List<ProviderInstanceDto>> listInstances({DeviceConfig? agent}) async => const [];

  // ── Unused commands for the usage contract ─────────────────────────────
  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _localAgent = null;
DeviceConfig? get _local => _localAgent;

void main() {
  test(
    'onInstancesLoaded hides unsupported instances and fetches supported ones',
    () async {
      final client = _FakeUsageClient()..supportMap = {'a': true, 'b': false};
      final cubit = ProviderUsageCubit(
        client: client,
        localDeviceId: _localDeviceId,
        freshness: const Duration(minutes: 1),
      );
      addTearDown(cubit.close);

      await cubit.onInstancesLoaded(
        agent: _local,
        instanceIds: const ['a', 'b'],
      );

      // 'a' is supported and got a snapshot; fresh phase with one window row.
      final a = cubit.state.entry(_localDeviceId, 'a');
      expect(a, isNotNull);
      expect(a!.phase, ProviderUsagePhase.fresh);
      expect(a.result!.status, 'available');
      expect(a.result!.snapshot!.windows, hasLength(1));

      // 'b' is unsupported → hidden, no fetch request was sent for it.
      final b = cubit.state.entry(_localDeviceId, 'b');
      expect(b, isNotNull);
      expect(b!.phase, ProviderUsagePhase.hidden);
      expect(b.result!.status, 'unsupported');

      final getCalls = client.calls.where((c) => c.$1 == 'get').toList();
      expect(
        getCalls.map((c) => c.$2).toList(),
        ['a'],
        reason: 'unsupported instance must not be fetched',
      );
    },
  );

  test(
    'freshness policy: returning within the window does not refetch',
    () async {
      final client = _FakeUsageClient();
      final cubit = ProviderUsageCubit(
        client: client,
        localDeviceId: _localDeviceId,
        freshness: const Duration(minutes: 1),
      );
      addTearDown(cubit.close);

      await cubit.onInstancesLoaded(agent: _local, instanceIds: const ['a']);
      final fetchCountAfterFirstLoad = client.calls.where((c) => c.$1 == 'get').length;

      // Re-issue with the same instance — within the minute it should NOT
      // re-fetch because the snapshot is still fresh.
      await cubit.onInstancesLoaded(agent: _local, instanceIds: const ['a']);
      final fetchCountAfterSecondLoad = client.calls.where((c) => c.$1 == 'get').length;

      expect(
        fetchCountAfterSecondLoad,
        fetchCountAfterFirstLoad,
        reason:
            'stale-while-revalidate must not issue a second fetch within '
            'the freshness window',
      );
    },
  );

  test('refresh forces a fetch even within the freshness window', () async {
    final client = _FakeUsageClient();
    final cubit = ProviderUsageCubit(
      client: client,
      localDeviceId: _localDeviceId,
      freshness: const Duration(minutes: 1),
    );
    addTearDown(cubit.close);

    await cubit.onInstancesLoaded(agent: _local, instanceIds: const ['a']);
    final countBefore = client.calls.where((c) => c.$1 == 'get').length;

    await cubit.refresh(instanceId: 'a', agent: _local);
    final countAfter = client.calls.where((c) => c.$1 == 'get').length;
    expect(countAfter, countBefore + 1);
  });

  test(
    'double-submit: refresh while one is already in flight is a no-op',
    () async {
      final client = _FakeUsageClient();
      final completer = Completer<void>();
      client.usageGetLatency = () => completer.future;

      final cubit = ProviderUsageCubit(
        client: client,
        localDeviceId: _localDeviceId,
        freshness: const Duration(minutes: 1),
      );
      addTearDown(cubit.close);

      // Start an initial call but hold it; subsequent refreshes on instance 'a'
      // must not produce a second `usageGet` on the wire.
      final first = cubit.onInstancesLoaded(agent: _local, instanceIds: const ['a']);
      // Allow the event loop to start the request and set the loading phase.
      await Future<void>.delayed(Duration.zero);

      await cubit.refresh(instanceId: 'a', agent: _local);
      final inflightCount = client.calls.where((c) => c.$1 == 'get' && c.$2 == 'a').length;
      expect(inflightCount, 1, reason: 'only one in-flight fetch per instance');

      completer.complete();
      await first;
    },
  );

  test(
    'failed fetch records needsAttention without throwing; section can Retry',
    () async {
      final client = _FakeUsageClient()
        ..usageResults = {
          'a': const ProviderUsageResultDto(
            status: 'unavailable',
            message: 'endpoint down',
            providerInstanceId: 'a',
          ),
        };
      final cubit = ProviderUsageCubit(
        client: client,
        localDeviceId: _localDeviceId,
        freshness: const Duration(minutes: 1),
      );
      addTearDown(cubit.close);

      await cubit.onInstancesLoaded(agent: _local, instanceIds: const ['a']);
      final a = cubit.state.entry(_localDeviceId, 'a')!;
      expect(a.phase, ProviderUsagePhase.needsAttention);
      expect(a.result!.status, 'unavailable');

      // Retry should re-issue and (once solved) transition back to fresh.
      client.usageResults = {
        'a': ProviderUsageResultDto(
          status: 'available',
          providerInstanceId: 'a',
          snapshot: ProviderUsageSnapshotDto(
            providerInstanceId: 'a',
            providerTemplateId: 'openai-codex',
            source: 'test',
            fetchedAt: DateTime.now().toUtc(),
            windows: const [
              ProviderUsageWindowDto(type: 'monthly', label: 'Monthly'),
            ],
          ),
        ),
      };
      await cubit.refresh(instanceId: 'a', agent: _local);
      final updated = cubit.state.entry(_localDeviceId, 'a')!;
      expect(updated.phase, ProviderUsagePhase.fresh);
    },
  );

  test(
    'device switch clears prior entries so a snapshot cannot leak across '
    'devices',
    () async {
      final client = _FakeUsageClient();
      final cubit = ProviderUsageCubit(
        client: client,
        localDeviceId: _localDeviceId,
        freshness: const Duration(minutes: 1),
      );
      addTearDown(cubit.close);

      const localDevice = _localDeviceId;
      final remoteAgent = DeviceConfig(
        id: 'remote-1',
        name: 'Remote',
        isOnline: true,
      );

      await cubit.onInstancesLoaded(
        agent: _local,
        instanceIds: const ['a'],
      );

      // Local snapshot must not survive a device switch that clears local state
      // before issuing new requests.
      cubit.clearDevice(_local);
      expect(
        cubit.state.entries[localDevice] == null || cubit.state.entries[localDevice]!['a'] == null,
        true,
        reason: 'local snapshot must be discarded on clearDevice',
      );

      // Loading on a different device must not produce a local entry nor
      // inherit the local snapshot.
      await cubit.onInstancesLoaded(
        agent: remoteAgent,
        instanceIds: const ['a'],
      );
      expect(
        cubit.state.entry(localDevice, 'a'),
        isNull,
        reason: 'entries must be keyed by deviceId',
      );
      final remote = cubit.state.entry('remote-1', 'a');
      expect(remote, isNotNull);
      expect(remote!.phase, ProviderUsagePhase.fresh);
    },
  );

  test(
    'two consumers of the same in-flight usage load share one request; later '
    'complete loads re-enter without re-fetching while fresh',
    () async {
      final client = _FakeUsageClient();
      final cubit = ProviderUsageCubit(
        client: client,
        localDeviceId: _localDeviceId,
        freshness: const Duration(minutes: 1),
      );
      addTearDown(cubit.close);

      // Hold the wire response open so a second consumer can join the first.
      final gate = Completer<void>();
      client.usageGetLatency = () => gate.future;
      client.usageResults = {
        'a': ProviderUsageResultDto(
          status: 'available',
          providerInstanceId: 'a',
          snapshot: ProviderUsageSnapshotDto(
            providerInstanceId: 'a',
            providerTemplateId: 'openai-codex',
            source: 'shared',
            fetchedAt: DateTime.now().toUtc(),
            windows: const [],
          ),
        ),
      };

      // Two independent consumers request the same (device, instance) at the
      // same time. 97h requires exactly one in-flight Agent request.
      final consumerA = cubit.ensureInstanceUsage(agent: _local, instanceId: 'a');
      final consumerB = cubit.ensureInstanceUsage(agent: _local, instanceId: 'a');
      await Future<void>.delayed(Duration.zero);

      final getCalls = client.calls.where((c) => c.$1 == 'get').toList();
      expect(getCalls, hasLength(1), reason: 'one shared usage.get for two consumers');

      gate.complete();
      await Future.wait([consumerA, consumerB]);
      expect(
        cubit.state.entry(_localDeviceId, 'a')!.result!.snapshot!.source,
        'shared',
      );

      // A later re-entry (e.g. a rebuild/remount of the consuming widget)
      // with the same logical resource must not issue another fetch while the
      // snapshot is still fresh.
      client.usageGetLatency = null;
      await cubit.ensureInstanceUsage(agent: _local, instanceId: 'a');
      final getCallsAfter = client.calls.where((c) => c.$1 == 'get').toList();
      expect(getCallsAfter, hasLength(1), reason: 'no re-fetch while fresh');
    },
  );

  test(
    'loads for different devices or queries run independently, never share '
    'or leak across scopes',
    () async {
      final client = _FakeUsageClient();
      final cubit = ProviderUsageCubit(
        client: client,
        localDeviceId: _localDeviceId,
        freshness: const Duration(minutes: 1),
      );
      addTearDown(cubit.close);

      final remoteAgent = DeviceConfig(
        id: 'remote-1',
        name: 'Remote',
        isOnline: true,
      );

      // The same instance id on two devices is two distinct logical queries:
      // both must resolve and stay isolated in their own device entries.
      await cubit.ensureInstanceUsage(agent: _local, instanceId: 'a');
      await cubit.ensureInstanceUsage(agent: remoteAgent, instanceId: 'a');

      final getCalls = client.calls.where((c) => c.$1 == 'get').toList();
      expect(getCalls, hasLength(2), reason: 'per-device usage.get, no sharing');
      expect(cubit.state.entry(_localDeviceId, 'a'), isNotNull);
      expect(cubit.state.entry('remote-1', 'a'), isNotNull);

      // A different query for the same device resolves separately too.
      await cubit.ensureInstanceUsage(agent: _local, instanceId: 'b');
      final getCallsAfterB = client.calls.where((c) => c.$1 == 'get').toList();
      expect(getCallsAfterB, hasLength(3));
      expect(cubit.state.entry(_localDeviceId, 'b'), isNotNull);

      // Device-switch invalidation drops the previous device's catalog so the
      // new scope never reuses or inherits the old display names.
      await cubit.ensureProviderDisplayNames(agent: _local);
      expect(cubit.state.displayNamesFor(_localDeviceId), isNotEmpty);
      cubit.clearDevice(_local);
      expect(cubit.state.displayNamesFor(_localDeviceId), isEmpty);
    },
  );

  test(
    'catalog model.snapshot load is shared and not re-issued per rebuild/remount',
    () async {
      final client = _FakeUsageClient();
      final cubit = ProviderUsageCubit(
        client: client,
        localDeviceId: _localDeviceId,
        freshness: const Duration(minutes: 1),
      );
      addTearDown(cubit.close);

      // Two consumers ask for the catalog concurrently: one request.
      final a = cubit.ensureProviderDisplayNames(agent: _local);
      final b = cubit.ensureProviderDisplayNames(agent: _local);
      await Future.wait([a, b]);
      expect(client.modelSnapshotCalls, 1, reason: 'one shared model.snapshot');

      // Twenty simulated rebuild/remount re-entries: zero additional calls.
      for (var i = 0; i < 20; i++) {
        await cubit.ensureProviderDisplayNames(agent: _local);
      }
      expect(
        client.modelSnapshotCalls,
        1,
        reason: 'no catalog re-fetch on rebuild/remount of same device',
      );
      expect(
        cubit.state.displayNamesFor(_localDeviceId),
        containsPair('a', 'Provider A'),
      );

      // A different device resolves its own catalog separately.
      final remoteAgent = DeviceConfig(id: 'remote-1', name: 'Remote', isOnline: true);
      await cubit.ensureProviderDisplayNames(agent: remoteAgent);
      expect(client.modelSnapshotCalls, 2, reason: 'per-device catalog request');
    },
  );

  test(
    'after one minute keeps the stale snapshot visible while revalidating',
    () async {
      var now = DateTime.utc(2026, 7, 19, 12);
      final client = _FakeUsageClient()
        ..usageResults = {
          'a': ProviderUsageResultDto(
            status: 'available',
            providerInstanceId: 'a',
            snapshot: ProviderUsageSnapshotDto(
              providerInstanceId: 'a',
              providerTemplateId: 'openai-codex',
              source: 'initial',
              fetchedAt: now,
              windows: const [
                ProviderUsageWindowDto(
                  type: 'weekly',
                  label: 'Weekly',
                  usedPercent: 40,
                ),
              ],
            ),
          ),
        };
      final cubit = ProviderUsageCubit(
        client: client,
        localDeviceId: _localDeviceId,
        freshness: const Duration(minutes: 1),
        now: () => now,
      );
      addTearDown(cubit.close);

      await cubit.onInstancesLoaded(agent: _local, instanceIds: const ['a']);
      expect(
        cubit.state.entry(_localDeviceId, 'a')!.fetchedAt,
        now,
        reason: 'freshness must use the daemon snapshot fetched_at',
      );

      now = now.add(const Duration(minutes: 1, seconds: 1));
      final pending = Completer<void>();
      client.usageGetLatency = () => pending.future;
      client.usageResults['a'] = ProviderUsageResultDto(
        status: 'available',
        providerInstanceId: 'a',
        snapshot: ProviderUsageSnapshotDto(
          providerInstanceId: 'a',
          providerTemplateId: 'openai-codex',
          source: 'refreshed',
          fetchedAt: now,
          windows: const [
            ProviderUsageWindowDto(
              type: 'weekly',
              label: 'Weekly',
              usedPercent: 10,
            ),
          ],
        ),
      );

      final refresh = cubit.onInstancesLoaded(
        agent: _local,
        instanceIds: const ['a'],
      );
      await Future<void>.delayed(Duration.zero);
      final whilePending = cubit.state.entry(_localDeviceId, 'a')!;
      expect(whilePending.phase, ProviderUsagePhase.staleRefreshing);
      expect(whilePending.result!.snapshot!.source, 'initial');
      expect(whilePending.backgroundRefreshing, isTrue);

      pending.complete();
      await refresh;
      final refreshed = cubit.state.entry(_localDeviceId, 'a')!;
      expect(refreshed.phase, ProviderUsagePhase.fresh);
      expect(refreshed.result!.snapshot!.source, 'refreshed');
    },
  );

  test('failed stale refresh preserves the prior snapshot with Retry state', () async {
    var now = DateTime.utc(2026, 7, 19, 12);
    final initial = ProviderUsageResultDto(
      status: 'available',
      providerInstanceId: 'a',
      snapshot: ProviderUsageSnapshotDto(
        providerInstanceId: 'a',
        providerTemplateId: 'openai-codex',
        source: 'initial',
        fetchedAt: now,
        windows: const [
          ProviderUsageWindowDto(type: 'weekly', label: 'Weekly'),
        ],
      ),
    );
    final client = _FakeUsageClient()..usageResults = {'a': initial};
    final cubit = ProviderUsageCubit(
      client: client,
      localDeviceId: _localDeviceId,
      freshness: const Duration(minutes: 1),
      now: () => now,
    );
    addTearDown(cubit.close);

    await cubit.onInstancesLoaded(agent: _local, instanceIds: const ['a']);
    now = now.add(const Duration(minutes: 2));
    client.usageResults['a'] = const ProviderUsageResultDto(
      status: 'unavailable',
      providerInstanceId: 'a',
      message: 'Temporarily unavailable.',
    );

    await cubit.onInstancesLoaded(agent: _local, instanceIds: const ['a']);
    final entry = cubit.state.entry(_localDeviceId, 'a')!;
    expect(entry.phase, ProviderUsagePhase.needsAttention);
    expect(entry.result!.snapshot!.source, 'initial');
    expect(entry.attentionResult!.status, 'unavailable');
  });

  test('late response cannot restore a removed instance', () async {
    final pending = Completer<void>();
    final client = _FakeUsageClient()..usageGetLatency = () => pending.future;
    final cubit = ProviderUsageCubit(client: client, localDeviceId: _localDeviceId);
    addTearDown(cubit.close);

    final load = cubit.onInstancesLoaded(
      agent: _local,
      instanceIds: const ['a'],
    );
    await Future<void>.delayed(Duration.zero);
    cubit.onInstanceRemoved(agent: _local, instanceId: 'a');
    pending.complete();
    await load;

    expect(cubit.state.entry(_localDeviceId, 'a'), isNull);
  });

  test('late support response is ignored after the device scope is cleared', () async {
    final pending = Completer<void>();
    final client = _FakeUsageClient()..usageSupportLatency = () => pending.future;
    final cubit = ProviderUsageCubit(client: client, localDeviceId: _localDeviceId);
    addTearDown(cubit.close);

    final load = cubit.onInstancesLoaded(
      agent: _local,
      instanceIds: const ['a'],
    );
    await Future<void>.delayed(Duration.zero);
    cubit.clearDevice(_local);
    pending.complete();
    await load;

    expect(cubit.state.entry(_localDeviceId, 'a'), isNull);
  });

  test('removed instance is dropped from state', () async {
    final client = _FakeUsageClient();
    final cubit = ProviderUsageCubit(
      client: client,
      localDeviceId: _localDeviceId,
      freshness: const Duration(minutes: 1),
    );
    addTearDown(cubit.close);

    await cubit.onInstancesLoaded(agent: _local, instanceIds: const ['a']);
    expect(
      cubit.state.entry(_localDeviceId, 'a'),
      isNotNull,
    );

    cubit.onInstanceRemoved(agent: _local, instanceId: 'a');
    expect(
      cubit.state.entry(_localDeviceId, 'a'),
      isNull,
      reason: 'removal must drop the corresponding entry',
    );
  });

  test('reset replaces usage only with the authoritative refreshed snapshot', () async {
    final refreshedAt = DateTime.utc(2026, 7, 19, 14);
    final client = _FakeUsageClient();
    final cubit = ProviderUsageCubit(client: client, localDeviceId: _localDeviceId);
    addTearDown(cubit.close);
    await cubit.onInstancesLoaded(agent: _local, instanceIds: const ['a']);
    client.resetResult = ProviderUsageResetResultDto(
      status: 'reset',
      providerInstanceId: 'a',
      message: 'Usage limits were reset successfully.',
      availableResets: 0,
      snapshot: ProviderUsageSnapshotDto(
        providerInstanceId: 'a',
        providerTemplateId: 'openai-codex',
        source: 'reset-refresh',
        fetchedAt: refreshedAt,
        windows: const [
          ProviderUsageWindowDto(
            type: 'weekly',
            label: 'Weekly',
            usedPercent: 0,
            remainingPercent: 100,
          ),
        ],
        availableResets: 0,
      ),
    );

    final result = await cubit.reset(instanceId: 'a', agent: _local);

    expect(result.status, 'reset');
    final entry = cubit.state.entry(_localDeviceId, 'a')!;
    expect(entry.result!.snapshot!.source, 'reset-refresh');
    expect(entry.result!.snapshot!.availableResets, 0);
    expect(entry.fetchedAt, refreshedAt);
    expect(entry.resetInProgress, isFalse);
  });

  test('reset double-submit sends one command and preserves confirmation token', () async {
    final pending = Completer<void>();
    final client = _FakeUsageClient();
    client.usageResetLatency = () => pending.future;
    client.resetResult = const ProviderUsageResetResultDto(
      status: 'confirmation_required',
      providerInstanceId: 'a',
      message: 'Resetting now may waste this credit.',
      confirmationToken: 'confirm-a',
    );
    final cubit = ProviderUsageCubit(client: client, localDeviceId: _localDeviceId);
    addTearDown(cubit.close);
    await cubit.onInstancesLoaded(agent: _local, instanceIds: const ['a']);

    final first = cubit.reset(instanceId: 'a', agent: _local);
    await Future<void>.delayed(Duration.zero);
    final duplicate = await cubit.reset(instanceId: 'a', agent: _local);
    expect(duplicate.status, 'failed');
    expect(client.resetCalls, hasLength(1));
    pending.complete();
    final confirmation = await first;
    expect(confirmation.confirmationToken, 'confirm-a');

    client.usageResetLatency = null;
    client.resetResult = const ProviderUsageResetResultDto(
      status: 'reset',
      providerInstanceId: 'a',
      message: 'Done.',
    );
    await cubit.reset(
      instanceId: 'a',
      agent: _local,
      confirmationToken: confirmation.confirmationToken,
    );
    expect(client.resetCalls.last.$1, 'a');
    expect(client.resetCalls.last.$2, client.resetCalls.first.$2);
    expect(client.resetCalls.last.$3, 'confirm-a');
  });
}
