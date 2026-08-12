import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/settings/data/account_lifecycle_repository.dart';
import 'package:sanad_client/features/settings/domain/account_lifecycle.dart';

class AccountLifecycleState {
  const AccountLifecycleState({
    this.snapshot,
    this.loading = false,
    this.error,
    this.inFlightIds = const {},
    this.generation = 0,
  });

  final AccountLifecycleSnapshot? snapshot;
  final bool loading;
  final String? error;
  final Set<String> inFlightIds;
  final int generation;

  AccountLifecycleState copyWith({
    AccountLifecycleSnapshot? snapshot,
    bool? loading,
    String? error,
    bool clearError = false,
    Set<String>? inFlightIds,
    int? generation,
  }) => AccountLifecycleState(
    snapshot: snapshot ?? this.snapshot,
    loading: loading ?? this.loading,
    error: clearError ? null : error ?? this.error,
    inFlightIds: inFlightIds ?? this.inFlightIds,
    generation: generation ?? this.generation,
  );
}

class AccountLifecycleCubit extends Cubit<AccountLifecycleState> {
  AccountLifecycleCubit(this._repository) : super(const AccountLifecycleState());

  final AccountLifecycleRepository _repository;

  Future<void> load() async {
    final generation = state.generation + 1;
    emit(state.copyWith(loading: true, clearError: true, generation: generation));
    try {
      final snapshot = await _repository.fetch();
      if (isClosed || state.generation != generation) return;
      emit(state.copyWith(snapshot: snapshot, loading: false, clearError: true));
    } on AccountLifecycleException catch (error) {
      if (isClosed || state.generation != generation) return;
      emit(state.copyWith(loading: false, error: error.message));
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
}
