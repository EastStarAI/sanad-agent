import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/settings/data/account_lifecycle_repository.dart';
import 'package:sanad_client/features/settings/domain/account_lifecycle.dart';

class AccountLifecycleState {
  const AccountLifecycleState({
    this.snapshot,
    this.loading = false,
    this.cloudUnavailable = false,
    this.error,
    this.inFlightIds = const {},
    this.generation = 0,
  });

  final AccountLifecycleSnapshot? snapshot;
  final bool loading;
  final bool cloudUnavailable;
  final String? error;
  final Set<String> inFlightIds;
  final int generation;

  AccountLifecycleState copyWith({
    AccountLifecycleSnapshot? snapshot,
    bool? loading,
    bool? cloudUnavailable,
    String? error,
    bool clearError = false,
    Set<String>? inFlightIds,
    int? generation,
  }) => AccountLifecycleState(
    snapshot: snapshot ?? this.snapshot,
    loading: loading ?? this.loading,
    cloudUnavailable: cloudUnavailable ?? this.cloudUnavailable,
    error: clearError ? null : error ?? this.error,
    inFlightIds: inFlightIds ?? this.inFlightIds,
    generation: generation ?? this.generation,
  );
}

class AccountLifecycleCubit extends Cubit<AccountLifecycleState> {
  AccountLifecycleCubit(this._repository) : super(const AccountLifecycleState()) {
    _changeSubscription = _repository.changes.listen((_) => _scheduleRefreshIfLoaded());
    _readinessSubscription = _repository.readinessChanges.listen(_handleReadiness);
  }

  final AccountLifecycleRepository _repository;
  late final StreamSubscription<void> _changeSubscription;
  late final StreamSubscription<bool> _readinessSubscription;
  bool _reloadPending = false;
  Timer? _refreshTimer;

  Future<void> load() async {
    if (state.loading) {
      _reloadPending = true;
      return;
    }
    final generation = state.generation + 1;
    emit(state.copyWith(loading: true, clearError: true, generation: generation));
    try {
      final snapshot = await _repository.fetch();
      if (isClosed || state.generation != generation) return;
      emit(
        state.copyWith(
          snapshot: snapshot,
          loading: false,
          cloudUnavailable: false,
          clearError: true,
        ),
      );
    } on AccountLifecycleException catch (error) {
      if (isClosed || state.generation != generation) return;
      emit(
        state.copyWith(
          loading: false,
          cloudUnavailable: !_repository.isReady,
          error: error.message,
        ),
      );
    } finally {
      if (_reloadPending && !isClosed) {
        _reloadPending = false;
        unawaited(load());
      }
    }
  }

  Future<bool> revoke(AccountPrincipal principal) async {
    if (state.inFlightIds.contains(principal.id)) return false;
    emit(
      state.copyWith(
        inFlightIds: {...state.inFlightIds, principal.id},
        clearError: true,
      ),
    );
    try {
      final result = await _repository.revoke(principal);
      if (result.currentSessionRevoked) return true;
      await load();
      return false;
    } on AccountLifecycleException catch (error) {
      if (!isClosed) emit(state.copyWith(error: error.message));
      if (error.outcomeUnknown) await load();
      return false;
    } finally {
      if (!isClosed) {
        emit(
          state.copyWith(
            inFlightIds: {...state.inFlightIds}..remove(principal.id),
          ),
        );
      }
    }
  }

  void _scheduleRefreshIfLoaded() {
    if (state.snapshot == null || _refreshTimer != null) return;
    _refreshTimer = Timer(Duration.zero, () {
      _refreshTimer = null;
      if (!isClosed && state.snapshot != null) unawaited(load());
    });
  }

  void _handleReadiness(bool ready) {
    if (state.snapshot == null) return;
    if (!ready) {
      emit(state.copyWith(cloudUnavailable: true));
      return;
    }
    if (state.cloudUnavailable) unawaited(load());
  }

  @override
  Future<void> close() async {
    _refreshTimer?.cancel();
    await _changeSubscription.cancel();
    await _readinessSubscription.cancel();
    return super.close();
  }
}
