import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/composer_slash_commands_state.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/conversations/presentation/utils/skill_composer_utils.dart';

typedef SlashCommandsSearcher =
    Future<List<SlashCommandEntry>> Function({
      String? query,
      String? workspaceId,
    });

class ComposerSlashCommandsCubit extends Cubit<ComposerSlashCommandsState> {
  final SlashCommandsSearcher _searcher;
  final Duration _debounceDuration;

  Timer? _debounceTimer;
  TextEditingValue _lastComposerValue = const TextEditingValue();
  String? _lastWorkspaceId;
  int _searchEpoch = 0;

  ComposerSlashCommandsCubit({
    required SlashCommandsSearcher searcher,
    Duration debounceDuration = const Duration(milliseconds: 80),
  }) : _searcher = searcher,
       _debounceDuration = debounceDuration,
       super(const ComposerSlashCommandsState());

  void onComposerChanged(TextEditingValue value) {
    _lastComposerValue = value;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDuration, _refreshSuggestions);
  }

  Future<void> loadForWorkspace(String? workspaceId) async {
    final normalizedWorkspaceId = workspaceId?.trim();
    if (_lastWorkspaceId == normalizedWorkspaceId) {
      return;
    }

    _lastWorkspaceId = normalizedWorkspaceId;
    _searchEpoch += 1;
    emit(state.copyWith(availableEntries: const []));
  }

  void clear() {
    _debounceTimer?.cancel();
    _searchEpoch += 1;
    emit(
      state.copyWith(
        visibleEntries: const [],
        highlightedIndex: 0,
        clearActiveQuery: true,
      ),
    );
  }

  TextEditingValue applySelection(TextEditingValue value) {
    _lastComposerValue = value;
    clear();
    return value;
  }

  String rewriteMessageForDispatch(
    String message, {
    List<SlashCommandDispatchToken> selectedTokens = const [],
  }) {
    return message;
  }

  void moveHighlight(int delta) {
    final entries = state.visibleEntries;
    if (entries.isEmpty) {
      return;
    }

    final rawIndex = state.highlightedIndex + delta;
    final wrappedIndex = ((rawIndex % entries.length) + entries.length) % entries.length;
    emit(state.copyWith(highlightedIndex: wrappedIndex));
  }

  void updateHighlightIndex(int index) {
    if (state.highlightedIndex == index) return;
    emit(state.copyWith(highlightedIndex: index));
  }

  Future<void> _refreshSuggestions() async {
    if (isClosed) {
      return;
    }

    final runtimeQuery = SkillComposerUtils.detectRuntimeSlashQuery(
      _lastComposerValue,
    );
    final query = runtimeQuery ?? SkillComposerUtils.detectSlashQuery(_lastComposerValue);
    if (query == null) {
      emit(
        state.copyWith(
          visibleEntries: const [],
          highlightedIndex: 0,
          clearActiveQuery: true,
        ),
      );
      return;
    }

    final epoch = ++_searchEpoch;
    final matches = await _searcher(
      query: query.query,
      workspaceId: _lastWorkspaceId,
    );
    if (isClosed || epoch != _searchEpoch) {
      return;
    }

    final eligibleMatches = matches
        .where(
          (entry) => runtimeQuery != null || entry.type.placement == SlashCommandPlacement.anywhere,
        )
        .toList(growable: false);

    emit(
      state.copyWith(
        availableEntries: eligibleMatches,
        activeQuery: query,
        visibleEntries: eligibleMatches.take(6).toList(growable: false),
        highlightedIndex: 0,
      ),
    );
  }

  @override
  Future<void> close() async {
    _debounceTimer?.cancel();
    return super.close();
  }
}
