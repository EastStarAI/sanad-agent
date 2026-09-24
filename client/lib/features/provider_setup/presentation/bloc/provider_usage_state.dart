import 'package:equatable/equatable.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_usage_dto.dart';

/// Per-instance usage snapshot entry owned by the [ProviderUsageCubit].
///
/// Identity is keyed by `device id + provider_instance_id` so usage from one
/// device/account never leaks into another (Task 55 §3.5).
class ProviderUsageEntry extends Equatable {
  /// Asynchronous lifecycle phase of the entry.
  final ProviderUsagePhase phase;

  /// The typed `provider.usage.get` result. Present once a fetch completed,
  /// regardless of status (available / unavailable / auth_required / failed).
  /// `null` only before the first fetch resolves.
  final ProviderUsageResultDto? result;

  /// UTC timestamp when [result] was last successfully populated by the
  /// daemon. Used by the freshness policy (Task 55 §3.5).
  final DateTime? fetchedAt;

  /// Typed failure from the latest refresh attempt. When a stale snapshot is
  /// still available, [result] remains the visible authoritative snapshot and
  /// this field supplies the inline Retry/auth message without discarding it.
  final ProviderUsageResultDto? attentionResult;

  /// Whether the displayed data is being refreshed in the background while
  /// the previous snapshot remains visible (stale-while-revalidate).
  final bool backgroundRefreshing;
  final bool resetInProgress;
  final ProviderUsageResetResultDto? resetResult;

  const ProviderUsageEntry({
    this.phase = ProviderUsagePhase.idle,
    this.result,
    this.fetchedAt,
    this.attentionResult,
    this.backgroundRefreshing = false,
    this.resetInProgress = false,
    this.resetResult,
  });

  /// Whether a snapshot is currently visible to the user.
  bool get hasVisibleSnapshot => result != null && result!.isAvailable && result!.snapshot != null;

  /// Whether the visible snapshot is older than the freshness window.
  bool isStale(Duration freshness, {DateTime? now}) {
    final at = fetchedAt;
    return at == null || (now ?? DateTime.now()).difference(at) > freshness;
  }

  ProviderUsageEntry copyWith({
    ProviderUsagePhase? phase,
    Object? result = _unset,
    Object? fetchedAt = _unset,
    Object? attentionResult = _unset,
    bool? backgroundRefreshing,
    bool? resetInProgress,
    Object? resetResult = _unset,
  }) {
    return ProviderUsageEntry(
      phase: phase ?? this.phase,
      result: result == _unset ? this.result : result as ProviderUsageResultDto?,
      fetchedAt: fetchedAt == _unset ? this.fetchedAt : fetchedAt as DateTime?,
      attentionResult: attentionResult == _unset ? this.attentionResult : attentionResult as ProviderUsageResultDto?,
      backgroundRefreshing: backgroundRefreshing ?? this.backgroundRefreshing,
      resetInProgress: resetInProgress ?? this.resetInProgress,
      resetResult: resetResult == _unset ? this.resetResult : resetResult as ProviderUsageResetResultDto?,
    );
  }

  @override
  List<Object?> get props => [
    phase,
    result,
    fetchedAt,
    attentionResult,
    backgroundRefreshing,
    resetInProgress,
    resetResult,
  ];
}

const _unset = Object();

/// Lifecycle phases for a per-instance usage entry.
enum ProviderUsagePhase {
  /// No fetch has been issued yet.
  idle,

  /// First fetch is in progress and no snapshot exists yet.
  loading,

  /// Snapshot is visible and fresh; not currently fetching.
  fresh,

  /// Snapshot is visible but stale; a background refresh is in progress.
  staleRefreshing,

  /// The last fetch completed but produced an actionable guest-facing status
  /// (`available` with a snapshot is never `needsAttention`; only auth / fail /
  /// unavailable go here so the section can show a Retry affordance).
  needsAttention,

  /// The daemon reports `unsupported`; the section must NOT be rendered.
  hidden,
}

/// Lightweight per-device support map returned by `provider.usage.support`.
class ProviderUsageSupportState extends Equatable {
  /// device id → per-instance support map.
  final Map<String, Map<String, bool>> byDevice;

  const ProviderUsageSupportState({this.byDevice = const {}});

  /// Whether [instanceId] has a usage adapter registered on the target daemon.
  bool supports(String deviceId, String instanceId) {
    final map = byDevice[deviceId];
    return map != null && (map[instanceId] ?? false);
  }

  ProviderUsageSupportState copyWith({
    Map<String, Map<String, bool>>? byDevice,
  }) {
    return ProviderUsageSupportState(byDevice: byDevice ?? this.byDevice);
  }

  @override
  List<Object?> get props => [byDevice];
}

/// Immutable state of the [ProviderUsageCubit].
class ProviderUsageState extends Equatable {
  /// Per-device, per-instance usage entries.
  /// Key structure: `{ deviceId: { instanceId: entry } }`.
  final Map<String, Map<String, ProviderUsageEntry>> entries;

  /// Per-device capability support map cached from `provider.usage.support`.
  final ProviderUsageSupportState support;

  /// Per-device provider display-name catalog resolved from
  /// `model.snapshot` (fallback `provider.instances.list`), owned by the
  /// cubit so rebuilds/remounts of consuming widgets never re-issue the
  /// request. Key structure: `{ deviceId: { instanceId: displayName } }`.
  final Map<String, Map<String, String>> providerDisplayNames;

  const ProviderUsageState({
    this.entries = const {},
    this.support = const ProviderUsageSupportState(),
    this.providerDisplayNames = const {},
  });

  /// Display names for [deviceId], or an empty map when not yet resolved.
  Map<String, String> displayNamesFor(String deviceId) => providerDisplayNames[deviceId] ?? const <String, String>{};

  /// Whether [instanceId] has a resolved support answer (either direction) on
  /// [deviceId], i.e. the daemon has answered for it at least once.
  bool hasSupportAnswer(String deviceId, String instanceId) {
    final map = support.byDevice[deviceId];
    return map != null && map.containsKey(instanceId);
  }

  /// The entry for [deviceId] + [instanceId], or `null` when none exists.
  ProviderUsageEntry? entry(String deviceId, String instanceId) {
    return entries[deviceId]?[instanceId];
  }

  ProviderUsageState copyWith({
    Map<String, Map<String, ProviderUsageEntry>>? entries,
    ProviderUsageSupportState? support,
    Map<String, Map<String, String>>? providerDisplayNames,
  }) {
    return ProviderUsageState(
      entries: entries ?? this.entries,
      support: support ?? this.support,
      providerDisplayNames: providerDisplayNames ?? this.providerDisplayNames,
    );
  }

  /// Returns a new state with [entry] inserted at [deviceId] + [instanceId]
  /// without mutating the surrounding maps.
  ProviderUsageState upsertEntry(
    String deviceId,
    String instanceId,
    ProviderUsageEntry entry,
  ) {
    final deviceMap = Map<String, ProviderUsageEntry>.from(
      entries[deviceId] ?? const {},
    );
    deviceMap[instanceId] = entry;
    final next = Map<String, Map<String, ProviderUsageEntry>>.from(entries);
    next[deviceId] = deviceMap;
    return copyWith(entries: next);
  }

  /// Returns a new state with all entries for [deviceId] removed.
  ProviderUsageState clearDevice(String deviceId) {
    if (!entries.containsKey(deviceId)) return this;
    final next = Map<String, Map<String, ProviderUsageEntry>>.from(entries);
    next.remove(deviceId);
    return copyWith(entries: next);
  }

  /// Returns a new state with the single [instanceId] removed for [deviceId].
  ProviderUsageState removeInstance(String deviceId, String instanceId) {
    final deviceMap = entries[deviceId];
    if (deviceMap == null || !deviceMap.containsKey(instanceId)) return this;
    final nextDevice = Map<String, ProviderUsageEntry>.from(deviceMap);
    nextDevice.remove(instanceId);
    final next = Map<String, Map<String, ProviderUsageEntry>>.from(entries);
    if (nextDevice.isEmpty) {
      next.remove(deviceId);
    } else {
      next[deviceId] = nextDevice;
    }
    return copyWith(entries: next);
  }

  @override
  List<Object?> get props => [entries, support, providerDisplayNames];
}
