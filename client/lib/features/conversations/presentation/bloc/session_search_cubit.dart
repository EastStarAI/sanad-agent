import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../devices/domain/models/device_config.dart';
import '../../domain/repositories/conversation_repository.dart';
import 'session_search_state.dart';

class SessionSearchCubit extends Cubit<SessionSearchState> {
  static const Duration debounceDuration = Duration(milliseconds: 300);

  final ConversationRepository _repository;
  Timer? _debounce;
  int _generation = 0;
  DeviceConfig? _device;

  SessionSearchCubit({required ConversationRepository repository})
    : _repository = repository,
      super(const SessionSearchState());

  void queryChanged(DeviceConfig device, String value) {
    _device = device;
    _debounce?.cancel();
    final generation = ++_generation;
    final query = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (query.isEmpty) {
      emit(SessionSearchState(deviceId: device.id));
      return;
    }
    emit(
      SessionSearchState(
        query: query,
        deviceId: device.id,
        status: SessionSearchStatus.loading,
      ),
    );
    _debounce = Timer(debounceDuration, () {
      unawaited(_searchFirstPage(device, query, generation));
    });
  }

  Future<void> retry() async {
    final device = _device;
    if (device == null || state.query.isEmpty) return;
    if (state.hits.isNotEmpty && state.nextCursor != null) {
      await loadMore();
      return;
    }
    _debounce?.cancel();
    final generation = ++_generation;
    emit(
      state.copyWith(
        status: SessionSearchStatus.loading,
        hits: const [],
        clearCursor: true,
        hasMore: false,
        clearError: true,
      ),
    );
    await _searchFirstPage(device, state.query, generation);
  }

  Future<void> loadMore() async {
    final device = _device;
    final cursor = state.nextCursor;
    if (device == null || cursor == null || !state.hasMore || state.status == SessionSearchStatus.loadingMore) {
      return;
    }
    final generation = _generation;
    final query = state.query;
    emit(state.copyWith(status: SessionSearchStatus.loadingMore, clearError: true));
    try {
      final page = await _repository.searchSessions(
        device,
        query: query,
        cursor: cursor,
      );
      if (!_isCurrent(generation, device.id, query)) return;
      emit(
        state.copyWith(
          status: SessionSearchStatus.ready,
          hits: [...state.hits, ...page.hits],
          nextCursor: page.nextCursor,
          clearCursor: page.nextCursor == null,
          hasMore: page.hasMore,
        ),
      );
    } catch (_) {
      if (!_isCurrent(generation, device.id, query)) return;
      emit(
        state.copyWith(
          status: SessionSearchStatus.failure,
          errorMessage: 'Could not load more results.',
        ),
      );
    }
  }

  Future<void> _searchFirstPage(
    DeviceConfig device,
    String query,
    int generation,
  ) async {
    try {
      final page = await _repository.searchSessions(device, query: query);
      if (!_isCurrent(generation, device.id, query)) return;
      emit(
        SessionSearchState(
          query: query,
          deviceId: device.id,
          status: page.hits.isEmpty ? SessionSearchStatus.empty : SessionSearchStatus.ready,
          hits: page.hits,
          nextCursor: page.nextCursor,
          hasMore: page.hasMore,
        ),
      );
    } catch (_) {
      if (!_isCurrent(generation, device.id, query)) return;
      emit(
        SessionSearchState(
          query: query,
          deviceId: device.id,
          status: SessionSearchStatus.failure,
          errorMessage: 'Conversation search failed. Try again.',
        ),
      );
    }
  }

  bool _isCurrent(int generation, String deviceId, String query) {
    return generation == _generation && state.deviceId == deviceId && state.query == query;
  }

  void reset() {
    _debounce?.cancel();
    _device = null;
    _generation++;
    emit(const SessionSearchState());
  }

  @override
  Future<void> close() {
    _debounce?.cancel();
    return super.close();
  }
}
