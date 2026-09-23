import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_usage_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_state.dart';

/// Owns the per-instance account usage snapshots for the provider setup
/// surface (Task 55 Gate C) and — since 97h — the provider display-name
/// catalog (`model.snapshot`) used by composer widgets.
///
/// Design laws enforced here (Task 55 §3.5, §3.6 + Plan 97h §G1):
///   • Each snapshot is keyed by `device + provider_instance_id` so usage
///     never crosses accounts or devices.
///   • Usage fetch is non-blocking: opening Providers renders the instances
///     immediately, usage is loaded afterwards and in parallel.
///   • Freshness window is one minute; re-entering within the minute keeps
///     the snapshot without re-fetching.
///   • After the minute elapses, the visible snapshot is shown as stale and a
///     background refresh runs (stale-while-revalidate). No polling in v1.
///   • `Refresh` fetches a single instance and is disabled while its own
///     request is in flight, preventing double submit.
///   • Switching device or removing an instance discards notifications and
///     stale responses by id, device, and instance identity.
///   • `unsupported` instances hide the section; the cubit still records the
///     outcome so a later support re-query can flip it.
///   • (97h) Request ownership lives here, not in widgets: identical
///     (device, instance-set) loads share one in-flight Agent request and a
///     completed load is not re-issued for the same key, so rebuilds,
///     theme changes and responsive remounts produce zero extra requests.
///     Different devices or queries never share or cancel each other
///     (per-device revision). `Refresh` and `clearDevice`/`onInstanceRemoved`
///     remain the authoritative invalidation paths.
///   • (97h) The provider display-name catalog for a device is owned here and
///     shared across consumers; empty/failed catalogs are bounded by a
///     30-second retry cooldown instead of hot-looping on rebuilds.
class ProviderUsageCubit extends Cubit<ProviderUsageState> {
  ProviderUsageCubit({
    required ProviderSetupClient client,
    required this.localDeviceId,
    this.freshness = const Duration(hours: 1),
    DateTime Function()? now,
  }) : _client = client,
       _now = now ?? DateTime.now,
       super(const ProviderUsageState());

  final ProviderSetupClient _client;
  final String localDeviceId;
  final DateTime Function() _now;

  /// How long a snapshot is considered fresh before stale-while-revalidate.
  final Duration freshness;

  // Monotonic per-(device,instance) request sequence used to ignore stale
  // responses after a device switch or refresh re-entry.
  final Map<String, int> _requestSequence = {};
  final Map<String, String> _resetIdempotencyKeys = {};

  /// Per-device scope revision: bumped on device switch / instance removal so
  /// a late response from an older scope can never leak into the new one.
  final Map<String, int> _deviceRevisions = {};

  /// In-flight `onInstancesLoaded` runs keyed by `deviceId|sortedIds` so two
  /// consumers of the same logical request share one wire request.
  final Map<String, Future<void>> _instancesLoadsInFlight = {};

  /// In-flight `model.snapshot` catalog loads per deviceId.
  final Map<String, Future<void>> _catalogLoadsInFlight = {};

  /// In-flight per-(device,instance) `usage.get` fetches so overlapping
  /// queries for the same logical resource share a single wire request.
  final Map<String, Future<void>> _usageFetchesInFlight = {};

  /// Earliest allowed retry per deviceId after an empty/failed catalog
  /// (mirrors the 30s empty-display cooldown previously held in widgets).
  final Map<String, DateTime> _catalogRetryUntil = {};
  static const _catalogRetryCooldown = Duration(seconds: 30);

  String _seqKey(String deviceId, String instanceId) => '$deviceId\$$instanceId';

  String _loadKey(String deviceId, List<String> instanceIds) {
    final sorted = [...instanceIds]..sort();
    return '$deviceId|${sorted.join(',')}';
  }

  int _nextSeq(String deviceId, String instanceId) {
    final key = _seqKey(deviceId, instanceId);
    final n = (_requestSequence[key] ?? 0) + 1;
    _requestSequence[key] = n;
    return n;
  }

  int _currentRevision(String deviceId) => _deviceRevisions[deviceId] ?? 0;

  int _bumpRevision(String deviceId) {
    final n = (_deviceRevisions[deviceId] ?? 0) + 1;
    _deviceRevisions[deviceId] = n;
    return n;
  }

  /// Called after instances are loaded. Refreshes the daemon's support map
  /// for [device] (only for instance ids without a resolved answer yet), then
  /// fetches usage in parallel for the supported instances.
  ///
  /// Containers render immediately from [instances] regardless of this call;
  /// usage fetches are best-effort and never block the list.
  ///
  /// (97h) This is the shared request owner: a concurrent identical
  /// (device, instance-set) call joins the same in-flight run — one wire
  /// request — and after completion a re-entry with the same key re-uses the
  /// resolved support answers plus the freshness window instead of re-fetching.
  /// Different devices or queries stay isolated (per-device revision bails
  /// late responses from older scopes).
  Future<void> onInstancesLoaded({
    required DeviceConfig? agent,
    required List<String> instanceIds,
  }) {
    final deviceId = _deviceId(agent);
    final key = _loadKey(deviceId, instanceIds);
    final inFlight = _instancesLoadsInFlight[key];
    if (inFlight != null) return inFlight;

    final future = _runInstancesLoaded(
      agent: agent,
      deviceId: deviceId,
      instanceIds: instanceIds,
    );
    _instancesLoadsInFlight[key] = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_instancesLoadsInFlight[key], future)) {
          unawaited(_instancesLoadsInFlight.remove(key));
        }
      }),
    );
    return future;
  }

  Future<void> _runInstancesLoaded({
    required DeviceConfig? agent,
    required String deviceId,
    required List<String> instanceIds,
  }) async {
    final revision = _currentRevision(deviceId);

    // Prune any entries that no longer appear in [instanceIds] for this
    // device (deletion or device switch).
    var pruned = state;
    final keep = instanceIds.toSet();
    final existing = pruned.entries[deviceId] ?? const {};
    for (final id in existing.keys.toList()) {
      if (!keep.contains(id)) {
        pruned = pruned.removeInstance(deviceId, id);
      }
    }

    // Query support only for instance ids that have no resolved answer yet on
    // this device. Re-entering the same resource reuses the resolved answers,
    // so rebuilds/remounts add no extra `provider.usage.support` request.
    final unanswered = instanceIds.where((id) => !pruned.hasSupportAnswer(deviceId, id)).toList();
    ProviderUsageSupportDto? support;
    if (unanswered.isNotEmpty) {
      try {
        support = await _client.usageSupport(
          providerInstanceIds: unanswered,
          agent: agent,
        );
      } catch (_) {
        // Capability failure must NOT block instance rendering; treat as
        // explicitly unsupported for every unanswered instance on this device.
        support = ProviderUsageSupportDto(
          support: {for (final id in unanswered) id: false},
        );
      }
    }
    if (isClosed || revision != _currentRevision(deviceId)) return;

    if (support != null) {
      final byDevice = Map<String, Map<String, bool>>.from(
        pruned.support.byDevice,
      );
      final deviceMap = Map<String, bool>.from(byDevice[deviceId] ?? const {});
      deviceMap.addAll(support.support);
      byDevice[deviceId] = deviceMap;
      pruned = pruned.copyWith(
        support: ProviderUsageSupportState(byDevice: byDevice),
      );
    }

    // Pre-seed idle entries so the section can show its loading affordance.
    for (final id in instanceIds) {
      if (!pruned.support.supports(deviceId, id)) {
        pruned = pruned.upsertEntry(
          deviceId,
          id,
          const ProviderUsageEntry(
            phase: ProviderUsagePhase.hidden,
            result: ProviderUsageResultDto(status: 'unsupported'),
          ),
        );
      } else if (pruned.entry(deviceId, id) == null) {
        pruned = pruned.upsertEntry(
          deviceId,
          id,
          const ProviderUsageEntry(phase: ProviderUsagePhase.idle),
        );
      }
    }
    emit(pruned);

    // Parallel fetch for supported instances whose snapshot is missing or
    // stale. Non-blocking: each fetch resolves independently.
    await Future.wait(
      instanceIds
          .where((id) => pruned.support.supports(deviceId, id))
          .map((id) => _fetch(instanceId: id, agent: agent, force: false)),
    );
  }

  /// Owns the provider display-name catalog (`model.snapshot`, with a
  /// `provider.instances.list` fallback) for [agent]'s device so composer
  /// widgets no longer fetch it from their own lifecycle.
  ///
  /// (97h) The catalog is shared per device: concurrent consumers join the
  /// same in-flight request, and a resolved catalog is not re-fetched on
  /// rebuilds/remounts. An empty or failed catalog is bounded by a 30-second
  /// retry cooldown rather than hot-looping.
  Future<void> ensureProviderDisplayNames({required DeviceConfig? agent}) {
    final deviceId = _deviceId(agent);
    final known = state.providerDisplayNames[deviceId];
    if (known != null && known.isNotEmpty) return Future.value();

    final inFlight = _catalogLoadsInFlight[deviceId];
    if (inFlight != null) return inFlight;

    final retryAfter = _catalogRetryUntil[deviceId];
    if (retryAfter != null && _now().isBefore(retryAfter)) return Future.value();

    final future = _loadProviderDisplayNames(agent: agent, deviceId: deviceId);
    _catalogLoadsInFlight[deviceId] = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_catalogLoadsInFlight[deviceId], future)) {
          unawaited(_catalogLoadsInFlight.remove(deviceId));
        }
      }),
    );
    return future;
  }

  Future<void> _loadProviderDisplayNames({
    required DeviceConfig? agent,
    required String deviceId,
  }) async {
    final revision = _currentRevision(deviceId);
    final names = <String, String>{};
    try {
      final snapshot = await _client.modelSnapshot(agent: agent);
      for (final instance in snapshot.instances) {
        final id = instance.id.trim();
        final displayName = instance.displayName.trim();
        if (id.isNotEmpty && displayName.isNotEmpty) names[id] = displayName;
      }

      if (names.isEmpty) {
        final instances = await _client.listInstances(agent: agent);
        for (final instance in instances) {
          final id = instance.id.trim();
          final displayName = instance.displayName.trim();
          if (id.isNotEmpty && displayName.isNotEmpty) names[id] = displayName;
        }
      }
    } catch (_) {
      // Keep the chip functional; retry is cooldown-bounded below.
      names.clear();
    }
    if (isClosed || revision != _currentRevision(deviceId)) return;

    if (names.isEmpty) {
      _catalogRetryUntil[deviceId] = _now().add(_catalogRetryCooldown);
      return;
    }
    _catalogRetryUntil.remove(deviceId);

    final previous = state.providerDisplayNames[deviceId] ?? const <String, String>{};
    if (_sameDisplayNames(previous, names)) return;
    emit(
      state.copyWith(
        providerDisplayNames: {...state.providerDisplayNames, deviceId: names},
      ),
    );
  }

  bool _sameDisplayNames(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// User-initiated refresh for a single instance.
  ///
  /// Stays a no-op when a request is already in flight for [instanceId] on
  /// [agent]'s device (double-submit protection, Task 55 §3.5).
  Future<void> refresh({
    required String instanceId,
    DeviceConfig? agent,
  }) async {
    final deviceId = _deviceId(agent);
    final current = state.entry(deviceId, instanceId);
    if (current != null && (current.phase == ProviderUsagePhase.loading || current.backgroundRefreshing)) {
      return;
    }
    await _fetch(instanceId: instanceId, agent: agent, force: true);
  }

  Future<ProviderUsageResetResultDto> reset({
    required String instanceId,
    DeviceConfig? agent,
    String? confirmationToken,
  }) async {
    final deviceId = _deviceId(agent);
    final prior = state.entry(deviceId, instanceId);
    if (prior == null || prior.resetInProgress) {
      return ProviderUsageResetResultDto(
        status: 'failed',
        providerInstanceId: instanceId,
        message: 'A reset is already in progress.',
      );
    }
    final seq = _nextSeq(deviceId, instanceId);
    emit(
      state.upsertEntry(
        deviceId,
        instanceId,
        prior.copyWith(resetInProgress: true, resetResult: null),
      ),
    );
    final resetKey = _seqKey(deviceId, instanceId);
    final idempotencyKey = _resetIdempotencyKeys.putIfAbsent(
      resetKey,
      () => '$deviceId-$instanceId-${DateTime.now().microsecondsSinceEpoch}-$seq',
    );
    ProviderUsageResetResultDto result;
    try {
      result = await _client.usageReset(
        providerInstanceId: instanceId,
        idempotencyKey: idempotencyKey,
        confirmationToken: confirmationToken,
        agent: agent,
      );
    } catch (_) {
      result = ProviderUsageResetResultDto(
        status: 'failed',
        providerInstanceId: instanceId,
        message: 'Reset could not be completed. Please try again.',
      );
    }
    if (result.status != 'failed' && result.status != 'confirmation_required') {
      _resetIdempotencyKeys.remove(resetKey);
    }
    if (!_stillOwner(deviceId, instanceId, seq)) return result;
    final current = state.entry(deviceId, instanceId)!;
    final snapshot = result.snapshot;
    final usageResult = snapshot == null
        ? current.result
        : ProviderUsageResultDto(
            status: 'available',
            providerInstanceId: instanceId,
            snapshot: snapshot,
          );
    emit(
      state.upsertEntry(
        deviceId,
        instanceId,
        current.copyWith(
          phase: snapshot == null ? current.phase : ProviderUsagePhase.fresh,
          result: usageResult,
          fetchedAt: snapshot?.fetchedAt ?? current.fetchedAt,
          resetInProgress: false,
          resetResult: result,
        ),
      ),
    );
    return result;
  }

  /// Clears all entries for [agent]'s device. Call on device switch.
  void clearDevice(DeviceConfig? agent) {
    final deviceId = _deviceId(agent);
    _bumpRevision(deviceId);
    _invalidateRequests(deviceId: deviceId);
    _usageFetchesInFlight.removeWhere(
      (key, _) => key.startsWith('$deviceId\$'),
    );
    _resetIdempotencyKeys.removeWhere(
      (key, _) => key.startsWith('$deviceId\$'),
    );
    // A different device must resolve its own provider display-name catalog;
    // drop the cached one so the new owner re-fetches once, never sharing a
    // previous device's names (97h).
    _catalogRetryUntil.remove(deviceId);
    var base = state.clearDevice(deviceId);
    if (base.providerDisplayNames.containsKey(deviceId)) {
      final next = Map<String, Map<String, String>>.from(
        base.providerDisplayNames,
      );
      next.remove(deviceId);
      base = base.copyWith(providerDisplayNames: next);
    }
    emit(base);
  }

  /// Discards state for a single removed instance on [agent]'s device.
  void onInstanceRemoved({DeviceConfig? agent, required String instanceId}) {
    final deviceId = _deviceId(agent);
    _bumpRevision(deviceId);
    _nextSeq(deviceId, instanceId);
    unawaited(_usageFetchesInFlight.remove(_seqKey(deviceId, instanceId)));
    _resetIdempotencyKeys.remove(_seqKey(deviceId, instanceId));
    var base = state.removeInstance(deviceId, instanceId);
    final displayNames = base.providerDisplayNames[deviceId];
    if (displayNames != null && displayNames.containsKey(instanceId)) {
      final without = Map<String, String>.from(displayNames);
      without.remove(instanceId);
      final nextNames = Map<String, Map<String, String>>.from(
        base.providerDisplayNames,
      );
      nextNames[deviceId] = without;
      base = base.copyWith(providerDisplayNames: nextNames);
    }
    emit(base);
  }

  /// Composer-facing single-instance ensure (97h): resolves the daemon
  /// support answer for [instanceId] (if unanswered) and fetches usage when
  /// missing/stale — sharing any in-flight request for the same
  /// (device, instance). Unlike [onInstancesLoaded] it never prunes sibling
  /// instances: the composer consumes one active provider and must not
  /// invalidate the provider-setup surface's wider instance set.
  Future<void> ensureInstanceUsage({
    required DeviceConfig? agent,
    required String instanceId,
  }) {
    final deviceId = _deviceId(agent);
    if (state.hasSupportAnswer(deviceId, instanceId)) {
      if (!state.support.supports(deviceId, instanceId)) return Future.value();
      final entry = state.entry(deviceId, instanceId);
      if (entry != null && entry.hasVisibleSnapshot && !entry.isStale(freshness, now: _now())) {
        return Future.value();
      }
    }
    final key = _loadKey(deviceId, [instanceId]);
    final inFlight = _instancesLoadsInFlight[key];
    if (inFlight != null) return inFlight;
    final future = _runEnsureInstanceUsage(
      agent: agent,
      deviceId: deviceId,
      instanceId: instanceId,
    );
    _instancesLoadsInFlight[key] = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_instancesLoadsInFlight[key], future)) {
          unawaited(_instancesLoadsInFlight.remove(key));
        }
      }),
    );
    return future;
  }

  Future<void> _runEnsureInstanceUsage({
    required DeviceConfig? agent,
    required String deviceId,
    required String instanceId,
  }) async {
    final revision = _currentRevision(deviceId);

    if (!state.hasSupportAnswer(deviceId, instanceId)) {
      ProviderUsageSupportDto support;
      try {
        support = await _client.usageSupport(
          providerInstanceIds: [instanceId],
          agent: agent,
        );
      } catch (_) {
        support = ProviderUsageSupportDto(support: {instanceId: false});
      }
      if (isClosed || revision != _currentRevision(deviceId)) return;

      final byDevice = Map<String, Map<String, bool>>.from(
        state.support.byDevice,
      );
      final deviceMap = Map<String, bool>.from(byDevice[deviceId] ?? const {});
      deviceMap.addAll(support.support);
      byDevice[deviceId] = deviceMap;
      emit(
        state.copyWith(support: ProviderUsageSupportState(byDevice: byDevice)),
      );
    }
    if (isClosed || revision != _currentRevision(deviceId)) return;

    if (!state.support.supports(deviceId, instanceId)) {
      // Unsupported on the daemon: record hidden once, never re-fetch.
      if (state.entry(deviceId, instanceId) == null) {
        emit(
          state.upsertEntry(
            deviceId,
            instanceId,
            const ProviderUsageEntry(
              phase: ProviderUsagePhase.hidden,
              result: ProviderUsageResultDto(status: 'unsupported'),
            ),
          ),
        );
      }
      return;
    }
    await _fetch(instanceId: instanceId, agent: agent, force: false);
  }

  Future<void> _fetch({
    required String instanceId,
    required DeviceConfig? agent,
    required bool force,
  }) {
    final deviceId = _deviceId(agent);
    final key = _seqKey(deviceId, instanceId);
    if (!force) {
      final existing = _usageFetchesInFlight[key];
      if (existing != null) return existing;
    }
    final future = _runFetch(
      deviceId: deviceId,
      instanceId: instanceId,
      agent: agent,
      force: force,
    );
    if (!force) {
      _usageFetchesInFlight[key] = future;
      unawaited(
        future.whenComplete(() {
          if (identical(_usageFetchesInFlight[key], future)) {
            unawaited(_usageFetchesInFlight.remove(key));
          }
        }),
      );
    }
    return future;
  }

  Future<void> _runFetch({
    required String deviceId,
    required String instanceId,
    required DeviceConfig? agent,
    required bool force,
  }) async {
    final prior = state.entry(deviceId, instanceId);

    // Decide loading vs. stale-while-revalidate: keep the visible snapshot
    // while refreshing in the background when one already exists.
    final bool hasVisible = prior != null && prior.hasVisibleSnapshot;
    final ProviderUsagePhase newPhase;
    if (force) {
      newPhase = hasVisible ? ProviderUsagePhase.staleRefreshing : ProviderUsagePhase.loading;
    } else if (prior == null) {
      newPhase = ProviderUsagePhase.loading;
    } else if (hasVisible && prior.isStale(freshness, now: _now())) {
      newPhase = ProviderUsagePhase.staleRefreshing;
    } else if (hasVisible) {
      // Still fresh — no fetch needed.
      return;
    } else if (prior.phase == ProviderUsagePhase.hidden) {
      // Unsupported on the daemon — never re-fetch.
      return;
    } else {
      newPhase = ProviderUsagePhase.loading;
    }

    final seq = _nextSeq(deviceId, instanceId);
    final initialEntry = (prior ?? const ProviderUsageEntry()).copyWith(
      phase: newPhase,
      attentionResult: null,
      backgroundRefreshing: newPhase == ProviderUsagePhase.staleRefreshing,
    );
    emit(state.upsertEntry(deviceId, instanceId, initialEntry));

    try {
      final result = await _client.usageGet(
        providerInstanceId: instanceId,
        agent: agent,
      );

      // Ignore stale responses: device switched, instance removed, or a
      // newer refresh overtook this fetch.
      if (!_stillOwner(deviceId, instanceId, seq)) {
        return;
      }

      if (result.providerInstanceId != null && result.providerInstanceId != instanceId) {
        return;
      }
      final phase = _phaseForResult(result);
      final keepsPriorSnapshot = phase == ProviderUsagePhase.needsAttention && hasVisible;
      final nextEntry = ProviderUsageEntry(
        phase: phase,
        result: keepsPriorSnapshot ? prior.result : result,
        attentionResult: keepsPriorSnapshot ? result : null,
        fetchedAt: phase == ProviderUsagePhase.fresh ? result.snapshot!.fetchedAt : prior?.fetchedAt,
      );
      emit(state.upsertEntry(deviceId, instanceId, nextEntry));
    } catch (_) {
      if (!_stillOwner(deviceId, instanceId, seq)) return;
      const safeMessage = 'Usage information could not be loaded. Please try again.';
      final failed = ProviderUsageResultDto(
        status: 'failed',
        message: safeMessage,
        providerInstanceId: instanceId,
      );
      final nextEntry = ProviderUsageEntry(
        phase: ProviderUsagePhase.needsAttention,
        result: hasVisible ? prior.result : failed,
        attentionResult: hasVisible ? failed : null,
        fetchedAt: prior?.fetchedAt,
      );
      emit(state.upsertEntry(deviceId, instanceId, nextEntry));
    }
  }

  /// Returns true if [seq] is still the latest sequence for the entry, i.e.
  /// the entry has not been superseded by a later refresh or a device switch.
  bool _stillOwner(String deviceId, String instanceId, int seq) {
    if (isClosed) return false;
    final key = _seqKey(deviceId, instanceId);
    return (_requestSequence[key] ?? 0) == seq && state.entry(deviceId, instanceId) != null;
  }

  void _invalidateRequests({String? deviceId}) {
    for (final key in _requestSequence.keys.toList()) {
      if (deviceId == null || key.startsWith('$deviceId\$')) {
        _requestSequence[key] = _requestSequence[key]! + 1;
      }
    }
  }

  ProviderUsagePhase _phaseForResult(ProviderUsageResultDto result) {
    switch (result.status) {
      case 'available':
        return ProviderUsagePhase.fresh;
      case 'unsupported':
        return ProviderUsagePhase.hidden;
      case 'auth_required':
      case 'unavailable':
      case 'failed':
        return ProviderUsagePhase.needsAttention;
      default:
        return ProviderUsagePhase.needsAttention;
    }
  }

  String _deviceId(DeviceConfig? agent) => agent?.id ?? localDeviceId;

  @override
  Future<void> close() async {
    _requestSequence.clear();
    _resetIdempotencyKeys.clear();
    _deviceRevisions.clear();
    _instancesLoadsInFlight.clear();
    _catalogLoadsInFlight.clear();
    _catalogRetryUntil.clear();
    _usageFetchesInFlight.clear();
    return super.close();
  }
}
