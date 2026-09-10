import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_usage_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_state.dart';

/// Owns the per-instance account usage snapshots for the provider setup
/// surface (Task 55 Gate C).
///
/// Design laws enforced here (Task 55 §3.5, §3.6):
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
  int _scopeRevision = 0;

  String _seqKey(String deviceId, String instanceId) => '$deviceId\$$instanceId';

  int _nextSeq(String deviceId, String instanceId) {
    final key = _seqKey(deviceId, instanceId);
    final n = (_requestSequence[key] ?? 0) + 1;
    _requestSequence[key] = n;
    return n;
  }

  /// Called after instances are loaded. Refreshes the daemon's support map
  /// for [device], then fetches usage in parallel for the supported instances.
  ///
  /// Containers render immediately from [instances] regardless of this call;
  /// usage fetches are best-effort and never block the list.
  Future<void> onInstancesLoaded({
    required DeviceConfig? agent,
    required List<String> instanceIds,
  }) async {
    final deviceId = _deviceId(agent);
    final scopeRevision = ++_scopeRevision;
    _invalidateRequests();

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

    // Query support so unsupported instances never render a `Usage & limits`
    // disclosure. The 'hidden' phase records `unsupported` outcomes.
    ProviderUsageSupportDto? support;
    try {
      support = await _client.usageSupport(
        providerInstanceIds: instanceIds,
        agent: agent,
      );
    } catch (_) {
      // Capability failure must NOT block instance rendering; treat as
      // explicitly unsupported for every instance on this device.
      support = ProviderUsageSupportDto(support: const {});
    }
    if (isClosed || scopeRevision != _scopeRevision) return;

    final byDevice = Map<String, bool>.from(support.support);
    final supportByDevice = Map<String, Map<String, bool>>.from(pruned.support.byDevice);
    supportByDevice[deviceId] = byDevice;
    pruned = pruned.copyWith(
      support: ProviderUsageSupportState(byDevice: supportByDevice),
    );

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
    _scopeRevision++;
    _invalidateRequests(deviceId: deviceId);
    _resetIdempotencyKeys.removeWhere(
      (key, _) => key.startsWith('$deviceId\$'),
    );
    if (state.entries.containsKey(deviceId)) {
      emit(state.clearDevice(deviceId));
    }
  }

  /// Discards state for a single removed instance on [agent]'s device.
  void onInstanceRemoved({DeviceConfig? agent, required String instanceId}) {
    final deviceId = _deviceId(agent);
    _scopeRevision++;
    _nextSeq(deviceId, instanceId);
    _resetIdempotencyKeys.remove(_seqKey(deviceId, instanceId));
    emit(state.removeInstance(deviceId, instanceId));
  }

  Future<void> _fetch({
    required String instanceId,
    required DeviceConfig? agent,
    required bool force,
  }) async {
    final deviceId = _deviceId(agent);
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
    return super.close();
  }
}
