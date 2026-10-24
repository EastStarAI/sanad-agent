import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/schedules/data/schedules_client.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_error.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_preview.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_request.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_run.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_run_failure_notice.dart';

/// What the Schedules surfaces render (Task 139 C4).
enum SchedulesStatus {
  /// Nothing has been asked for yet; no request has been issued.
  initial,

  /// The first read of a device scope is in flight.
  loading,

  /// At least one schedule is known for the current device scope.
  loaded,

  /// The current device scope reported no schedule.
  empty,

  /// The last read failed; [SchedulesState.failure] carries the typed reason
  /// and the page offers Retry.
  error,

  /// The inspected device is offline, or it became unavailable while in use.
  /// The Agent was not asked and no list is shown.
  deviceUnavailable,
}

/// The actions one cubit admits, for single-flight admission and for a surface
/// that disables exactly the action in flight.
enum ScheduleActionKind { create, update, pause, resume, runNow, delete }

/// One admitted action, identified by its kind and the schedule it targets.
///
/// Two identical actions (same kind, same target) are single-flight: the second
/// is rejected as [ScheduleActionOutcome.busy] and sends nothing.
class ScheduleAction extends Equatable {
  const ScheduleAction({required this.kind, this.scheduleId});

  final ScheduleActionKind kind;
  final String? scheduleId;

  String get key => scheduleId == null ? kind.name : '${kind.name}:$scheduleId';

  @override
  List<Object?> get props => [kind, scheduleId];
}

/// A typed reason a schedule read or action failed.
class ScheduleFailure extends Equatable {
  const ScheduleFailure({required this.code, this.scheduleId});

  final ScheduleErrorCode code;

  /// The schedule the refusal is about, when one is known.
  final String? scheduleId;

  @override
  List<Object?> get props => [code, scheduleId];

  @override
  String toString() => 'ScheduleFailure(code: ${code.name}, schedule: ${scheduleId ?? 'none'})';
}

/// The open schedule's detail and its run history (Task 139 C2, S8).
///
/// [schedule] is the row from the current `schedule.list` snapshot, so the
/// detail never keeps a copy of its own. [runs] is a bounded page and
/// [nextCursor] is opaque: it is passed back to the Agent unchanged.
class SchedulesDetailState extends Equatable {
  const SchedulesDetailState({
    required this.scheduleId,
    this.schedule,
    this.runs = const <ScheduleRun>[],
    this.hasMoreRuns = false,
    this.nextCursor,
    this.loadingRuns = false,
    this.failure,
  });

  final String scheduleId;
  final Schedule? schedule;
  final List<ScheduleRun> runs;
  final bool hasMoreRuns;
  final String? nextCursor;
  final bool loadingRuns;
  final ScheduleFailure? failure;

  /// Whether a further run page can be requested.
  bool get canLoadMoreRuns => hasMoreRuns && nextCursor != null && !loadingRuns;

  SchedulesDetailState withSchedule(Schedule? schedule) => SchedulesDetailState(
    scheduleId: scheduleId,
    schedule: schedule,
    runs: runs,
    hasMoreRuns: hasMoreRuns,
    nextCursor: nextCursor,
    loadingRuns: loadingRuns,
    failure: failure,
  );

  SchedulesDetailState copyWith({
    List<ScheduleRun>? runs,
    bool? hasMoreRuns,
    String? nextCursor,
    bool? loadingRuns,
    ScheduleFailure? failure,
    bool clearFailure = false,
    bool clearCursor = false,
  }) => SchedulesDetailState(
    scheduleId: scheduleId,
    schedule: schedule,
    runs: runs ?? this.runs,
    hasMoreRuns: hasMoreRuns ?? this.hasMoreRuns,
    nextCursor: clearCursor ? null : nextCursor ?? this.nextCursor,
    loadingRuns: loadingRuns ?? this.loadingRuns,
    failure: clearFailure ? null : failure ?? this.failure,
  );

  @override
  List<Object?> get props => [scheduleId, schedule, runs, hasMoreRuns, nextCursor, loadingRuns, failure];
}

/// The single state of [SchedulesCubit].
///
/// Freshness invariants make a stale snapshot impossible to present as current:
///
/// - [schedules] is non-empty only for [SchedulesStatus.loaded], so an offline
///   or failed state can never render a previous list as the device's list
///   (S18).
/// - [failure] and [previewFailure] hold a [ScheduleErrorCode] instead of Agent
///   text, so no surface can show a raw protocol message.
/// - [detail] derives its row from [schedules], so the detail never owns a
///   second copy of a schedule.
class SchedulesState extends Equatable {
  const SchedulesState({
    this.status = SchedulesStatus.initial,
    this.schedules = const <Schedule>[],
    this.truncated = false,
    this.failure,
    this.refreshing = false,
    this.inFlightAction,
    this.detail,
    this.preview,
    this.previewInFlight = false,
    this.previewFailure,
    this.lastAcceptedRun,
  });

  final SchedulesStatus status;
  final List<Schedule> schedules;

  /// Whether the Agent stopped at its own list bound.
  final bool truncated;

  final ScheduleFailure? failure;

  /// A re-read over an already loaded list; the rows stay visible while the
  /// authoritative snapshot is fetched.
  final bool refreshing;

  /// The action in flight, when one is admitted.
  final ScheduleAction? inFlightAction;

  /// The open detail and its run history, or `null`.
  final SchedulesDetailState? detail;

  /// The most recent `schedule.preview` answer for the open form, or `null`.
  final SchedulePreview? preview;
  final bool previewInFlight;
  final ScheduleFailure? previewFailure;

  /// The most recent accepted Run now, or `null`.
  final ScheduleRunAcceptance? lastAcceptedRun;

  /// Whether [schedules] may be rendered as the device's current list.
  bool get showsList => status == SchedulesStatus.loaded;

  /// Whether the device reported no schedule.
  bool get isEmpty => status == SchedulesStatus.empty;

  /// Whether any admitted action, read, or preview is in flight.
  bool get isBusy => inFlightAction != null || refreshing || previewInFlight;

  /// The conversation ids that own at least one schedule, derived from the
  /// current `schedule.list` snapshot (Task 139 C1).
  ///
  /// The sidebar marker and the conversation-delete warning (S23) read this
  /// set; it costs no extra command, and it is empty whenever the list is not
  /// current.
  Set<String> get conversationIdsWithSchedules {
    final ids = <String>{};
    for (final schedule in schedules) {
      final ownerId = schedule.ownerSessionId;
      if (ownerId != null) ids.add(ownerId);
    }
    return ids;
  }

  /// The schedule with [id] from the current snapshot, or `null`.
  Schedule? scheduleById(String id) {
    for (final schedule in schedules) {
      if (schedule.id == id) return schedule;
    }
    return null;
  }

  /// Whether [kind] is in flight for [scheduleId].
  bool isActionInFlight(ScheduleActionKind kind, {String? scheduleId}) =>
      inFlightAction == ScheduleAction(kind: kind, scheduleId: scheduleId);

  SchedulesState copyWith({
    SchedulesStatus? status,
    List<Schedule>? schedules,
    bool? truncated,
    ScheduleFailure? failure,
    bool clearFailure = false,
    bool? refreshing,
    ScheduleAction? inFlightAction,
    bool clearInFlightAction = false,
    SchedulesDetailState? detail,
    bool clearDetail = false,
    SchedulePreview? preview,
    bool clearPreview = false,
    bool? previewInFlight,
    ScheduleFailure? previewFailure,
    bool clearPreviewFailure = false,
    ScheduleRunAcceptance? lastAcceptedRun,
    bool clearLastAcceptedRun = false,
  }) => SchedulesState(
    status: status ?? this.status,
    schedules: schedules ?? this.schedules,
    truncated: truncated ?? this.truncated,
    failure: clearFailure ? null : failure ?? this.failure,
    refreshing: refreshing ?? this.refreshing,
    inFlightAction: clearInFlightAction ? null : inFlightAction ?? this.inFlightAction,
    detail: clearDetail ? null : detail ?? this.detail,
    preview: clearPreview ? null : preview ?? this.preview,
    previewInFlight: previewInFlight ?? this.previewInFlight,
    previewFailure: clearPreviewFailure ? null : previewFailure ?? this.previewFailure,
    lastAcceptedRun: clearLastAcceptedRun ? null : lastAcceptedRun ?? this.lastAcceptedRun,
  );

  @override
  List<Object?> get props => [
    status,
    schedules,
    truncated,
    failure,
    refreshing,
    inFlightAction,
    detail,
    preview,
    previewInFlight,
    previewFailure,
    lastAcceptedRun,
  ];

  /// It never holds a submitted value; it is safe to format anywhere.
  @override
  String toString() =>
      'SchedulesState(status: ${status.name}, schedules: ${schedules.length}, '
      'truncated: $truncated, failure: ${failure ?? 'none'}, refreshing: $refreshing, '
      'action: ${inFlightAction?.key ?? 'none'}, detail: ${detail?.scheduleId ?? 'none'}, '
      'preview: ${preview == null ? 'none' : (preview!.valid ? 'valid' : 'invalid')})';
}

/// How an admitted schedule action ended, for the surface that started it.
enum ScheduleActionOutcome {
  /// The Agent confirmed the mutation; the list was re-read afterwards.
  success,

  /// An identical action is already in flight; nothing was sent.
  busy,

  /// The device is offline or the transport failed; nothing was sent or the
  /// outcome is unknown.
  deviceUnavailable,

  /// The Agent refused with a typed [ScheduleFailure].
  failed,
}

/// The one cubit behind the Schedules surfaces (Task 139 C4, C6).
///
/// Transport, local/cloud selection, and correlation stay inside
/// [SchedulesClient] → `DeviceCommandClient` → `DeviceConnectionCoordinator`;
/// this cubit never branches on connection scope, so a web, mobile, or
/// cloud-relayed Client behaves exactly like a loopback one.
///
/// Admission rules:
///
/// - Nothing is fetched on construction. A surface calls [load] from its own
///   lifecycle (never from `build`) and again on Retry.
/// - A `load` while one is in flight is coalesced: the caller joins the running
///   read and at most one follow-up read is queued, so a burst of
///   `schedule.changed` events cannot stack requests.
/// - A second identical action while the first is in flight is rejected with
///   [ScheduleActionOutcome.busy] and sends nothing.
/// - `DeviceConfig.isOnline == false` short-circuits before any request and
///   clears the snapshot.
/// - `schedule.changed` re-reads the list, and the open detail with it, without
///   projecting the event payload.
/// - `schedule.run_failed` is forwarded as a typed stream and is never stored as
///   data, but it *is* a freshness signal: a failed run broadcasts no
///   `schedule.changed`, so the notice triggers the same coalesced re-read (Task
///   139 F5). Without it the failure badge and `consecutive_failures` stayed one
///   failure behind until the user re-entered the page.
class SchedulesCubit extends Cubit<SchedulesState> {
  SchedulesCubit({
    required SchedulesClient client,
    required DeviceConfig? Function() device,
  }) : _client = client,
       _device = device,
       super(const SchedulesState()) {
    _runFailures = StreamController<ScheduleRunFailureNotice>.broadcast();
  }

  final SchedulesClient _client;

  /// The device scope the surfaces are inspecting, resolved at call time so a
  /// changed selection is picked up without the cubit owning device state.
  final DeviceConfig? Function() _device;

  late final StreamController<ScheduleRunFailureNotice> _runFailures;

  Future<void>? _loadInFlight;
  bool _loadQueued = false;

  Future<void>? _runsInFlight;
  bool _runsResetQueued = false;

  final Set<String> _inFlightActions = <String>{};

  /// Bumped whenever this cubit takes a newer authoritative decision (a
  /// settled mutation, or the device going offline). A read that started before
  /// the bump must not emit, because its answer is already known to be older.
  int _snapshotVersion = 0;
  int _runsVersion = 0;
  int _previewVersion = 0;

  StreamSubscription<void>? _changedSubscription;
  StreamSubscription<ScheduleRunFailureNotice>? _runFailureSubscription;
  String? _watchedDeviceId;

  /// Failed runs, as typed notices for the Client's own failure surface
  /// (Task 139 §6). They are never written to state, a log, or history.
  Stream<ScheduleRunFailureNotice> get runFailures => _runFailures.stream;

  // ── Reads ──────────────────────────────────────────────────────────────────

  /// Reads the authoritative list for the current device scope.
  ///
  /// The first read after a device scope change emits [SchedulesStatus.loading];
  /// a read over a loaded list keeps the rows visible and sets
  /// [SchedulesState.refreshing]. A failure or an offline device clears the rows
  /// and the open detail, because neither can prove the previous snapshot is
  /// still current.
  Future<void> load() {
    // A closed cubit issues no request: only a broadcast refresh can reach this
    // point without a user intent.
    if (isClosed) return Future<void>.value();
    final inFlight = _loadInFlight;
    if (inFlight != null) {
      _loadQueued = true;
      return inFlight;
    }
    late final Future<void> tracked;
    tracked = _runLoad().whenComplete(() {
      _loadInFlight = null;
      if (_loadQueued && !isClosed) {
        _loadQueued = false;
        unawaited(load());
      }
    });
    _loadInFlight = tracked;
    return tracked;
  }

  /// Opens (or switches) the detail for [scheduleId] and reads its first run
  /// page.
  Future<void> openDetail(String scheduleId) async {
    if (isClosed) return;
    if (state.detail?.scheduleId != scheduleId) _runsVersion++;
    emit(
      state.copyWith(
        detail: SchedulesDetailState(
          scheduleId: scheduleId,
          schedule: state.scheduleById(scheduleId),
        ),
      ),
    );
    await refreshRuns();
  }

  /// Closes the open detail; a later run page cannot land on it.
  void closeDetail() {
    if (isClosed) return;
    _runsVersion++;
    emit(state.copyWith(clearDetail: true));
  }

  /// Re-reads the open detail's first run page.
  Future<void> refreshRuns() => _loadRuns(reset: true);

  /// Appends the next run page using the opaque cursor the Agent minted.
  Future<void> loadMoreRuns() => _loadRuns(reset: false);

  // ── Actions ────────────────────────────────────────────────────────────────

  /// Creates a device-owned schedule and re-reads the list (S1, S2).
  Future<ScheduleActionOutcome> create(ScheduleDraft draft) {
    return _mutate(
      const ScheduleAction(kind: ScheduleActionKind.create),
      (device) => _client.create(device, draft),
    );
  }

  /// Applies an edit and re-reads the list (S6, S24).
  Future<ScheduleActionOutcome> update(ScheduleUpdate update) {
    return _mutate(
      ScheduleAction(kind: ScheduleActionKind.update, scheduleId: update.id),
      (device) => _client.update(device, update),
    );
  }

  /// Pauses a schedule (S13).
  Future<ScheduleActionOutcome> pause(String scheduleId) {
    return _mutate(
      ScheduleAction(kind: ScheduleActionKind.pause, scheduleId: scheduleId),
      (device) => _client.pause(device, scheduleId),
    );
  }

  /// Resumes a schedule; an expired `once` answers [ScheduleErrorCode.scheduleExpired]
  /// and an orphaned model row [ScheduleErrorCode.scheduleOrphaned] (D6, S23).
  Future<ScheduleActionOutcome> resume(String scheduleId) {
    return _mutate(
      ScheduleAction(kind: ScheduleActionKind.resume, scheduleId: scheduleId),
      (device) => _client.resume(device, scheduleId),
    );
  }

  /// Dispatches a run now, including on a paused schedule, without resuming it
  /// (S14, S21).
  Future<ScheduleActionOutcome> runNow(String scheduleId) async {
    ScheduleRunAcceptance? accepted;
    final outcome = await _mutate(
      ScheduleAction(kind: ScheduleActionKind.runNow, scheduleId: scheduleId),
      (device) async => accepted = await _client.runNow(device, scheduleId),
    );
    if (outcome == ScheduleActionOutcome.success && !isClosed && accepted != null) {
      emit(state.copyWith(lastAcceptedRun: accepted));
    }
    return outcome;
  }

  /// Deletes a schedule after the surface confirmed it (S10, D7).
  ///
  /// The confirmation dialog and the `confirm: true` protocol flag are separate
  /// concerns: the client always sends the flag, the surface owns the dialog.
  Future<ScheduleActionOutcome> delete(String scheduleId) async {
    final outcome = await _mutate(
      ScheduleAction(kind: ScheduleActionKind.delete, scheduleId: scheduleId),
      (device) => _client.delete(device, scheduleId),
    );
    if (outcome == ScheduleActionOutcome.success && !isClosed && state.detail?.scheduleId == scheduleId) {
      closeDetail();
    }
    return outcome;
  }

  /// Asks the Agent for the next run of a candidate definition (Task 139 D4).
  ///
  /// At most one preview is in flight and only the newest answer may emit, so a
  /// debounced form cannot show an older candidate's instant as the current one.
  Future<void> preview(ScheduleDefinitionInput definition) async {
    if (isClosed) return;
    final device = _device();
    if (device == null || !device.isOnline) {
      emit(_unavailableState(state));
      return;
    }
    final version = ++_previewVersion;
    emit(state.copyWith(previewInFlight: true, clearPreviewFailure: true));
    try {
      final result = await _client.preview(device, definition);
      if (isClosed || version != _previewVersion) return;
      emit(
        state.copyWith(
          preview: result,
          previewInFlight: false,
          clearPreviewFailure: true,
        ),
      );
    } on ScheduleException catch (error) {
      if (isClosed || version != _previewVersion) return;
      emit(
        state.copyWith(
          clearPreview: true,
          previewInFlight: false,
          previewFailure: ScheduleFailure(code: error.code),
        ),
      );
    } catch (_) {
      if (isClosed || version != _previewVersion) return;
      emit(
        state.copyWith(
          clearPreview: true,
          previewInFlight: false,
          previewFailure: const ScheduleFailure(code: ScheduleErrorCode.unknown),
        ),
      );
    }
  }

  /// Drops the visible preview answer; a request still in flight cannot land.
  void clearPreview() {
    if (isClosed) return;
    _previewVersion++;
    emit(state.copyWith(clearPreview: true, previewInFlight: false, clearPreviewFailure: true));
  }

  /// Drops the retained Run now acceptance once its surface consumed it.
  void clearLastAcceptedRun() {
    if (isClosed) return;
    emit(state.copyWith(clearLastAcceptedRun: true));
  }

  /// Drops the visible snapshot when the inspected device goes offline (S18).
  /// No request is issued and no stale row survives the transition.
  void markDeviceUnavailable() {
    if (isClosed) return;
    _snapshotVersion++;
    _runsVersion++;
    unawaited(_stopWatching());
    emit(_unavailableState(state));
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  Future<ScheduleActionOutcome> _mutate(
    ScheduleAction action,
    Future<Object?> Function(DeviceConfig device) run,
  ) async {
    final device = _device();
    if (device == null || !device.isOnline) {
      if (!isClosed) emit(_unavailableState(state));
      return ScheduleActionOutcome.deviceUnavailable;
    }
    if (_inFlightActions.contains(action.key)) return ScheduleActionOutcome.busy;

    _inFlightActions.add(action.key);
    if (!isClosed) {
      emit(state.copyWith(inFlightAction: action, clearFailure: true));
    }

    ScheduleFailure? failure;
    ScheduleActionOutcome outcome = ScheduleActionOutcome.failed;
    try {
      await run(device);
      _snapshotVersion++;
      outcome = ScheduleActionOutcome.success;
    } on ScheduleException catch (error) {
      _snapshotVersion++;
      failure = ScheduleFailure(code: error.code, scheduleId: error.scheduleId ?? action.scheduleId);
      outcome = error.code == ScheduleErrorCode.deviceUnavailable
          ? ScheduleActionOutcome.deviceUnavailable
          : ScheduleActionOutcome.failed;
    } catch (_) {
      _snapshotVersion++;
      failure = ScheduleFailure(code: ScheduleErrorCode.unknown, scheduleId: action.scheduleId);
      outcome = ScheduleActionOutcome.failed;
    } finally {
      _inFlightActions.remove(action.key);
    }

    if (isClosed) return outcome;

    if (failure == null) {
      emit(state.copyWith(clearInFlightAction: true, clearFailure: true));
      // The Agent is the authority on what a mutation produced: the response row
      // is not patched into the list, because the list is ordered by the next
      // instant the mutation may have moved.
      await load();
      if (!isClosed && state.detail != null) await refreshRuns();
      return outcome;
    }

    // A transport failure cannot prove the snapshot is still current; a typed
    // refusal (an invalid definition, an expired or orphaned row) leaves it
    // untouched and is reported to the surface that started the action.
    emit(
      failure.code == ScheduleErrorCode.deviceUnavailable
          ? _unavailableState(state).copyWith(failure: failure)
          : state.copyWith(clearInFlightAction: true, refreshing: false, failure: failure),
    );
    return outcome;
  }

  Future<void> _runLoad() async {
    final device = _device();
    if (device == null || !device.isOnline) {
      _snapshotVersion++;
      _runsVersion++;
      unawaited(_stopWatching());
      if (!isClosed) emit(_unavailableState(state));
      return;
    }

    _watch(device);
    final version = _snapshotVersion;
    final deviceId = device.id;
    if (!isClosed) {
      final hadList = state.status == SchedulesStatus.loaded || state.status == SchedulesStatus.empty;
      emit(
        state.copyWith(
          status: hadList ? state.status : SchedulesStatus.loading,
          refreshing: hadList,
          clearFailure: true,
        ),
      );
    }

    try {
      final snapshot = await _client.list(device);
      // A newer decision (a settled mutation, an offline device, or a changed
      // device scope) owns the next authoritative read; this answer must not
      // overwrite it.
      if (_isStale(version, deviceId)) return;
      emit(
        _withSyncedDetail(
          state.copyWith(
            status: snapshot.schedules.isEmpty ? SchedulesStatus.empty : SchedulesStatus.loaded,
            schedules: snapshot.schedules,
            truncated: snapshot.truncated,
            refreshing: false,
            clearFailure: true,
          ),
        ),
      );
    } on ScheduleException catch (error) {
      if (_isStale(version, deviceId)) return;
      emit(
        _emptyState(
          status: error.code == ScheduleErrorCode.deviceUnavailable
              ? SchedulesStatus.deviceUnavailable
              : SchedulesStatus.error,
          failure: ScheduleFailure(code: error.code),
        ),
      );
    } catch (_) {
      if (_isStale(version, deviceId)) return;
      emit(
        _emptyState(
          status: SchedulesStatus.error,
          failure: const ScheduleFailure(code: ScheduleErrorCode.unknown),
        ),
      );
    }
  }

  Future<void> _loadRuns({required bool reset}) {
    if (isClosed) return Future<void>.value();
    final detail = state.detail;
    if (detail == null) return Future<void>.value();
    if (!reset && !detail.canLoadMoreRuns) return Future<void>.value();

    final inFlight = _runsInFlight;
    if (inFlight != null) {
      // A reset carries new authority (a mutation or a broadcast); a page request
      // during an in-flight read is simply skipped.
      if (reset) _runsResetQueued = true;
      return inFlight;
    }

    late final Future<void> tracked;
    tracked = _runRuns(reset: reset).whenComplete(() {
      _runsInFlight = null;
      if (_runsResetQueued && !isClosed) {
        _runsResetQueued = false;
        unawaited(_loadRuns(reset: true));
      }
    });
    _runsInFlight = tracked;
    return tracked;
  }

  Future<void> _runRuns({required bool reset}) async {
    final detail = state.detail;
    if (detail == null) return;
    final device = _device();
    if (device == null || !device.isOnline) {
      emit(_unavailableState(state));
      return;
    }

    final version = _runsVersion;
    final scheduleId = detail.scheduleId;
    final cursor = reset ? null : detail.nextCursor;
    emit(
      state.copyWith(
        detail: detail.copyWith(loadingRuns: true, clearFailure: true),
      ),
    );

    try {
      final page = await _client.runs(device, scheduleId: scheduleId, cursor: cursor);
      if (isClosed || version != _runsVersion) return;
      final current = state.detail;
      if (current == null || current.scheduleId != scheduleId) return;
      final runs = reset ? page.runs : [...current.runs, ...page.runs];
      emit(
        state.copyWith(
          detail: current.copyWith(
            runs: List<ScheduleRun>.unmodifiable(runs),
            hasMoreRuns: page.hasMore,
            nextCursor: page.nextCursor,
            clearCursor: page.nextCursor == null,
            loadingRuns: false,
            clearFailure: true,
          ),
        ),
      );
    } on ScheduleException catch (error) {
      if (isClosed || version != _runsVersion) return;
      final current = state.detail;
      if (current == null || current.scheduleId != scheduleId) return;
      emit(
        state.copyWith(
          detail: current.copyWith(
            loadingRuns: false,
            failure: ScheduleFailure(code: error.code, scheduleId: scheduleId),
          ),
        ),
      );
    } catch (_) {
      if (isClosed || version != _runsVersion) return;
      final current = state.detail;
      if (current == null || current.scheduleId != scheduleId) return;
      emit(
        state.copyWith(
          detail: current.copyWith(
            loadingRuns: false,
            failure: ScheduleFailure(code: ScheduleErrorCode.unknown, scheduleId: scheduleId),
          ),
        ),
      );
    }
  }

  /// Whether a read that started at [version] for [deviceId] has been overtaken.
  bool _isStale(int version, String deviceId) => isClosed || version != _snapshotVersion || _device()?.id != deviceId;

  /// The device-unavailable state: no list, no detail rows, no preview, and no
  /// failure text, because none of the previous snapshot can be presented as
  /// current (S18).
  SchedulesState _unavailableState(SchedulesState from) {
    return SchedulesState(
      status: SchedulesStatus.deviceUnavailable,
      inFlightAction: null,
      previewInFlight: false,
      lastAcceptedRun: from.lastAcceptedRun,
    );
  }

  /// A freshly-read failure state: it keeps the open detail's identity so the
  /// surface can offer Retry, and keeps no row from the failed snapshot.
  SchedulesState _emptyState({required SchedulesStatus status, required ScheduleFailure failure}) {
    final detail = state.detail;
    return SchedulesState(
      status: status,
      failure: failure,
      detail: detail == null ? null : SchedulesDetailState(scheduleId: detail.scheduleId, failure: failure),
    );
  }

  /// Re-derives the open detail's row from a freshly-read list snapshot.
  SchedulesState _withSyncedDetail(SchedulesState next) {
    final detail = next.detail;
    if (detail == null) return next;
    return next.copyWith(detail: detail.withSchedule(next.scheduleById(detail.scheduleId)));
  }

  /// Follows the device's broadcasts. `schedule.changed` announces that the
  /// authoritative snapshot moved, so it triggers a re-read and its payload is
  /// never projected into state. `schedule.run_failed` is forwarded as a typed
  /// notice and, because a failed run broadcasts nothing else, it also triggers
  /// that same re-read (Task 139 F5).
  void _watch(DeviceConfig device) {
    if (_watchedDeviceId == device.id && _changedSubscription != null) return;
    unawaited(_stopWatching());
    _watchedDeviceId = device.id;
    late final StreamSubscription<void> changed;
    changed = _client
        .changes(device)
        .listen(
          (_) => unawaited(_refreshFromBroadcast()),
          onError: (Object _) => _dropWatch(changed),
          onDone: () => _dropWatch(changed),
        );
    _changedSubscription = changed;

    late final StreamSubscription<ScheduleRunFailureNotice> failures;
    failures = _client
        .runFailures(device)
        .listen(
          _forwardRunFailure,
          onError: (Object _) => _dropFailureWatch(failures),
          onDone: () => _dropFailureWatch(failures),
        );
    _runFailureSubscription = failures;
  }

  Future<void> _refreshFromBroadcast() async {
    await load();
    if (isClosed || state.detail == null) return;
    await refreshRuns();
  }

  void _forwardRunFailure(ScheduleRunFailureNotice notice) {
    if (_runFailures.isClosed) return;
    _runFailures.add(notice);
    unawaited(_refreshFromRunFailure(notice));
  }

  /// Re-reads what a failed run changed, using the notice only as a trigger.
  ///
  /// A failure writes the run's terminal row and the schedule's
  /// `consecutive_failures`, but broadcasts no `schedule.changed`, so the
  /// list snapshot (and the failure badge derived from it) went stale until the
  /// surface was reopened. The notice payload is never projected: this asks the
  /// Agent for the authoritative list, and for the open schedule's first run page
  /// when the failure belongs to the schedule on screen.
  Future<void> _refreshFromRunFailure(ScheduleRunFailureNotice notice) async {
    await load();
    if (isClosed) return;
    final detail = state.detail;
    if (detail == null || detail.scheduleId != notice.scheduleId) return;
    await refreshRuns();
  }

  void _dropWatch(StreamSubscription<void> subscription) {
    if (!identical(_changedSubscription, subscription)) return;
    _changedSubscription = null;
    unawaited(subscription.cancel());
  }

  void _dropFailureWatch(StreamSubscription<ScheduleRunFailureNotice> subscription) {
    if (!identical(_runFailureSubscription, subscription)) return;
    _runFailureSubscription = null;
    unawaited(subscription.cancel());
  }

  Future<void> _stopWatching() async {
    final changed = _changedSubscription;
    final failures = _runFailureSubscription;
    _changedSubscription = null;
    _runFailureSubscription = null;
    _watchedDeviceId = null;
    await changed?.cancel();
    await failures?.cancel();
  }

  @override
  Future<void> close() async {
    await _stopWatching();
    await _runFailures.close();
    return super.close();
  }
}
