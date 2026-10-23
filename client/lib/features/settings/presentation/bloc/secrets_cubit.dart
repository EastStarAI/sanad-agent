import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/settings/data/secrets_client.dart';

/// What the Settings → Privacy & Security → Secrets page renders (Task 140 C3).
enum SecretsStatus {
  /// Nothing has been asked for yet; no request has been issued.
  initial,

  /// The first read of a device scope is in flight.
  loading,

  /// At least one stored secret is known for the current device scope.
  loaded,

  /// The current device scope reported no stored secret.
  empty,

  /// The last read or mutation failed; [SecretsState.failure] carries the typed
  /// reason and the page offers Retry.
  error,

  /// The inspected device is offline, or it became unavailable while in use.
  /// The Agent was not asked and no list is shown.
  deviceUnavailable,
}

/// A typed, value-free reason a secret action failed.
class SecretsFailure {
  const SecretsFailure({required this.code, this.name});

  final SecretsErrorCode code;

  /// The secret name the refusal is about, when the Agent named one.
  final String? name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is SecretsFailure && other.code == code && other.name == name;

  @override
  int get hashCode => Object.hash(code, name);

  @override
  String toString() => 'SecretsFailure(code: ${code.name}, name: ${name ?? 'none'})';
}

/// The single state of [SecretsCubit].
///
/// Three invariants make the value direction and the freshness of the list
/// impossible to break from the outside:
///
/// - There is no field for a submitted value, a masked value, or a cache of one.
/// - [secrets] is non-empty only for [SecretsStatus.loaded], so an offline or
///   failed state can never render a stale row as current.
/// - [failure] holds a [SecretsErrorCode] instead of Agent text, so no surface
///   can show a raw protocol message.
class SecretsState {
  const SecretsState({
    this.status = SecretsStatus.initial,
    this.secrets = const <StoredSecret>[],
    this.truncated = false,
    this.failure,
    this.refreshing = false,
    this.mutationInFlight = false,
  });

  final SecretsStatus status;
  final List<StoredSecret> secrets;
  final bool truncated;
  final SecretsFailure? failure;

  /// A re-read over an already loaded list; the rows stay visible while the
  /// authoritative snapshot is fetched.
  final bool refreshing;

  /// A `set` or `delete` is in flight; the page disables its actions.
  final bool mutationInFlight;

  /// Whether [secrets] may be rendered as the current list.
  bool get showsList => status == SecretsStatus.loaded;

  bool get isEmpty => status == SecretsStatus.empty;

  bool get isBusy => refreshing || mutationInFlight;

  SecretsState copyWith({
    SecretsStatus? status,
    List<StoredSecret>? secrets,
    bool? truncated,
    SecretsFailure? failure,
    bool clearFailure = false,
    bool? refreshing,
    bool? mutationInFlight,
  }) => SecretsState(
    status: status ?? this.status,
    secrets: secrets ?? this.secrets,
    truncated: truncated ?? this.truncated,
    failure: clearFailure ? null : failure ?? this.failure,
    refreshing: refreshing ?? this.refreshing,
    mutationInFlight: mutationInFlight ?? this.mutationInFlight,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SecretsState &&
          other.status == status &&
          listEquals(other.secrets, secrets) &&
          other.truncated == truncated &&
          other.failure == failure &&
          other.refreshing == refreshing &&
          other.mutationInFlight == mutationInFlight;

  @override
  int get hashCode => Object.hash(
    status,
    Object.hashAll(secrets),
    truncated,
    failure,
    refreshing,
    mutationInFlight,
  );

  /// Safe to format anywhere: it never holds a submitted value.
  @override
  String toString() =>
      'SecretsState(status: ${status.name}, secrets: ${secrets.map((secret) => secret.toJson()).toList()}, '
      'truncated: $truncated, failure: ${failure ?? 'none'}, refreshing: $refreshing, '
      'mutationInFlight: $mutationInFlight)';
}

/// How a `set` or `delete` ended, for the dialog that started it.
enum SecretsActionOutcome {
  /// The Agent confirmed the mutation; the list was re-read afterwards.
  success,

  /// `secret.delete` reported `not_found`: there was nothing to delete.
  notFound,

  /// Another mutation is already in flight; nothing was sent.
  busy,

  /// The device is offline or the transport failed; nothing was sent or the
  /// outcome is unknown.
  deviceUnavailable,

  /// The Agent refused with a typed [SecretsErrorCode].
  failed,
}

/// The one cubit behind the Secrets page (Task 140 C3, C5).
///
/// Transport, local/cloud selection, and correlation stay inside
/// [SecretsClient] → `DeviceCommandClient` → `DeviceConnectionCoordinator`; this
/// cubit never branches on connection scope, so a web, mobile, or cloud-relayed
/// Client behaves exactly like a loopback one.
///
/// Admission rules:
///
/// - Nothing is fetched on construction. The page calls [load] once from its
///   own lifecycle (not from `build`), and again on a Retry tap.
/// - A `load` while one is in flight is coalesced: the caller joins the running
///   read and at most one follow-up read is queued, so a burst of
///   `secrets.changed` events cannot stack requests.
/// - `set`/`delete` while another mutation is in flight is rejected with
///   [SecretsActionOutcome.busy]; nothing is sent.
/// - `DeviceConfig.isOnline == false` short-circuits before any request and
///   clears the rows.
///
/// The submitted value is a method argument that is handed to [SecretsClient]
/// and dropped. It is never a field, never part of [SecretsState], and never
/// interpolated into a failure.
class SecretsCubit extends Cubit<SecretsState> {
  SecretsCubit({
    required SecretsClient client,
    required DeviceConfig? Function() device,
  }) : _client = client,
       _device = device,
       super(const SecretsState());

  final SecretsClient _client;

  /// The device scope the page is inspecting, resolved at call time so a
  /// changed selection is picked up without the cubit owning device state.
  final DeviceConfig? Function() _device;

  Future<void>? _loadInFlight;
  bool _loadQueued = false;
  bool _mutationInFlight = false;

  /// Bumped whenever this cubit takes a newer authoritative decision (a
  /// mutation settled, or the device went offline). A read that started before
  /// the bump must not emit, because its answer is already known to be older.
  int _snapshotVersion = 0;
  StreamSubscription<void>? _changeSubscription;
  String? _watchedDeviceId;

  /// Reads the authoritative list for the current device scope.
  ///
  /// The first read after a device scope change emits [SecretsStatus.loading];
  /// a read over a loaded list keeps the rows visible and sets
  /// [SecretsState.refreshing]. A failure or an offline device clears the rows,
  /// because neither can prove the previous list is still current.
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

  /// Adds or replaces a value for [name].
  ///
  /// [value] is passed straight through to [SecretsClient.set] and dropped. A
  /// successful save re-reads the list, so the row is the Agent's projection of
  /// what it stored rather than a locally patched copy.
  Future<SecretsActionOutcome> set({
    required String name,
    required String value,
    String? description,
  }) {
    return _mutate((device) async {
      await _client.set(
        device,
        name: name,
        value: value,
        description: description,
      );
      return SecretsActionOutcome.success;
    });
  }

  /// Deletes [name] after the page confirmed it (Task 140 C2).
  Future<SecretsActionOutcome> delete(String name) {
    return _mutate((device) async {
      final status = await _client.delete(device, name);
      return status == SecretDeletionStatus.deleted ? SecretsActionOutcome.success : SecretsActionOutcome.notFound;
    });
  }

  /// Drops the visible list when the inspected device goes offline (Task 140
  /// C3). No request is issued and no stale row survives the transition.
  void markDeviceUnavailable() {
    if (isClosed) return;
    _snapshotVersion++;
    unawaited(_stopWatching());
    emit(_unavailableState(state));
  }

  Future<SecretsActionOutcome> _mutate(
    Future<SecretsActionOutcome> Function(DeviceConfig device) action,
  ) async {
    final device = _device();
    if (device == null || !device.isOnline) {
      if (!isClosed) emit(_unavailableState(state));
      return SecretsActionOutcome.deviceUnavailable;
    }
    if (_mutationInFlight) return SecretsActionOutcome.busy;

    _mutationInFlight = true;
    if (!isClosed) {
      emit(state.copyWith(mutationInFlight: true, clearFailure: true));
    }

    SecretsFailure? failure;
    SecretsActionOutcome outcome = SecretsActionOutcome.failed;
    try {
      outcome = await action(device);
      _snapshotVersion++;
    } on SecretsException catch (error) {
      _snapshotVersion++;
      failure = SecretsFailure(code: error.code, name: error.name);
      outcome = error.code == SecretsErrorCode.deviceUnavailable
          ? SecretsActionOutcome.deviceUnavailable
          : SecretsActionOutcome.failed;
    } catch (_) {
      _snapshotVersion++;
      failure = const SecretsFailure(code: SecretsErrorCode.unknown);
      outcome = SecretsActionOutcome.failed;
    } finally {
      _mutationInFlight = false;
    }

    if (isClosed) return outcome;

    if (failure == null) {
      emit(state.copyWith(mutationInFlight: false, clearFailure: true));
      if (outcome == SecretsActionOutcome.success) await load();
      return outcome;
    }

    // A transport failure cannot prove the list is still current; a typed
    // refusal (an invalid name, a refused value) leaves the list untouched and
    // is reported to the dialog that started the action.
    emit(
      failure.code == SecretsErrorCode.deviceUnavailable
          ? _unavailableState(state).copyWith(failure: failure, mutationInFlight: false)
          : state.copyWith(
              mutationInFlight: false,
              refreshing: false,
              failure: failure,
            ),
    );
    return outcome;
  }

  Future<void> _runLoad() async {
    final device = _device();
    if (device == null || !device.isOnline) {
      _snapshotVersion++;
      unawaited(_stopWatching());
      if (!isClosed) emit(_unavailableState(state));
      return;
    }

    _watchChanges(device);
    final version = _snapshotVersion;
    final deviceId = device.id;
    if (!isClosed) {
      final hadList = state.status == SecretsStatus.loaded || state.status == SecretsStatus.empty;
      emit(
        state.copyWith(
          status: hadList ? state.status : SecretsStatus.loading,
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
        state.copyWith(
          status: snapshot.secrets.isEmpty ? SecretsStatus.empty : SecretsStatus.loaded,
          secrets: snapshot.secrets,
          truncated: snapshot.truncated,
          refreshing: false,
          clearFailure: true,
        ),
      );
    } on SecretsException catch (error) {
      if (_isStale(version, deviceId)) return;
      emit(
        SecretsState(
          status: error.code == SecretsErrorCode.deviceUnavailable
              ? SecretsStatus.deviceUnavailable
              : SecretsStatus.error,
          failure: SecretsFailure(code: error.code, name: error.name),
          mutationInFlight: state.mutationInFlight,
        ),
      );
    } catch (_) {
      if (_isStale(version, deviceId)) return;
      emit(
        SecretsState(
          status: SecretsStatus.error,
          failure: const SecretsFailure(code: SecretsErrorCode.unknown),
          mutationInFlight: state.mutationInFlight,
        ),
      );
    }
  }

  /// Whether a read that started at [version] for [deviceId] has been overtaken.
  bool _isStale(int version, String deviceId) => isClosed || version != _snapshotVersion || _device()?.id != deviceId;

  SecretsState _unavailableState(SecretsState from) => SecretsState(
    status: SecretsStatus.deviceUnavailable,
    secrets: const <StoredSecret>[],
    failure: null,
    refreshing: false,
    mutationInFlight: from.mutationInFlight,
  );

  /// Follows `secrets.changed` for [device]: the event announces that the
  /// authoritative list moved, so it triggers a re-read and its payload is
  /// never projected into state.
  void _watchChanges(DeviceConfig device) {
    if (_watchedDeviceId == device.id && _changeSubscription != null) return;
    unawaited(_stopWatching());
    _watchedDeviceId = device.id;
    // Late-bound so the terminal callbacks can identify their own subscription.
    late final StreamSubscription<void> subscription;
    subscription = _client
        .changes(device)
        .listen(
          (_) => unawaited(load()),
          onError: (Object _) => _dropWatch(subscription),
          onDone: () => _dropWatch(subscription),
        );
    _changeSubscription = subscription;
  }

  void _dropWatch(StreamSubscription<void> subscription) {
    if (!identical(_changeSubscription, subscription)) return;
    _changeSubscription = null;
    _watchedDeviceId = null;
    unawaited(subscription.cancel());
  }

  Future<void> _stopWatching() async {
    final subscription = _changeSubscription;
    _changeSubscription = null;
    _watchedDeviceId = null;
    await subscription?.cancel();
  }

  @override
  Future<void> close() async {
    await _stopWatching();
    return super.close();
  }
}
