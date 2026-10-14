import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/composer_slash_commands_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';

void main() {
  group('ComposerSlashCommandsCubit', () {
    late _FakeSlashCommandsSearcher searcher;
    late ComposerSlashCommandsCubit cubit;

    setUp(() {
      searcher = _FakeSlashCommandsSearcher();
      cubit = ComposerSlashCommandsCubit(searcher: searcher.call, debounceDuration: Duration.zero);
    });

    tearDown(() async {
      await cubit.close();
    });

    test('loadForWorkspace updates state without making network requests', () async {
      await cubit.loadForWorkspace('workspace-1');
      await cubit.loadForWorkspace('workspace-1');

      expect(cubit.state.availableEntries, isEmpty);
      expect(searcher.requests, isEmpty);
    });

    test('queries the runtime for visible entries based on the active slash query', () async {
      searcher.entriesByWorkspace['workspace-1'] = [
        _entry(name: 'flutter_driver', description: 'Drive a Flutter workflow'),
        _entry(name: 'test-sanad-plugin', description: 'Prompts the model to test a plugin'),
        _entry(name: 'testrig', description: 'Another testing helper'),
      ];
      searcher.queryResults['tes'] = [
        _entry(name: 'test-sanad-plugin', description: 'Prompts the model to test a plugin'),
        _entry(name: 'testrig', description: 'Another testing helper'),
      ];

      await cubit.loadForWorkspace('workspace-1');
      cubit.onComposerChanged(const TextEditingValue(text: '/tes', selection: TextSelection.collapsed(offset: 4)));
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.activeQuery?.query, 'tes');
      expect(cubit.state.visibleEntries.map((entry) => entry.command).toList(growable: false), [
        'test-sanad-plugin',
        'testrig',
      ]);
      expect(cubit.state.highlightedIndex, 0);
      expect(searcher.requests, [
        {'query': 'tes', 'workspace_id': 'workspace-1'},
      ]);
    });

    test('uses runtime-provided matches even when the user omits spaces in the query', () async {
      searcher.entriesByWorkspace['workspace-1'] = [
        _entry(name: 'test sanad plugin'),
      ];
      searcher.queryResults['testsanad'] = [
        _entry(name: 'test sanad plugin'),
      ];

      await cubit.loadForWorkspace('workspace-1');
      cubit.onComposerChanged(
        const TextEditingValue(text: '/testsanad', selection: TextSelection.collapsed(offset: 10)),
      );
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.visibleEntries.map((entry) => entry.command), ['test sanad plugin']);
    });

    test('filters leading-only runtime actions from a mid-message slash', () async {
      searcher.queryResults['co'] = [
        _entry(name: 'compact', type: SlashCommandType.runtimeAction),
        _entry(name: 'code-review'),
      ];

      cubit.onComposerChanged(
        const TextEditingValue(
          text: 'please /co',
          selection: TextSelection.collapsed(offset: 10),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        cubit.state.visibleEntries.map((entry) => entry.command),
        ['code-review'],
      );
    });

    test('keeps runtime actions visible for a leading slash', () async {
      searcher.queryResults['co'] = [
        _entry(name: 'compact', type: SlashCommandType.runtimeAction),
        _entry(name: 'code-review'),
      ];

      cubit.onComposerChanged(
        const TextEditingValue(
          text: '/co',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        cubit.state.visibleEntries.map((entry) => entry.command),
        ['compact', 'code-review'],
      );
    });

    test('applySelection clears the active suggestion session after the input is updated', () async {
      searcher.entriesByWorkspace['workspace-1'] = [_entry(name: 'test-sanad-plugin')];

      await cubit.loadForWorkspace('workspace-1');
      const originalValue = TextEditingValue(text: 'please /tes now', selection: TextSelection.collapsed(offset: 11));
      cubit.onComposerChanged(originalValue);
      await Future<void>.delayed(Duration.zero);

      final updated = cubit.applySelection(originalValue);

      expect(updated.text, originalValue.text);
      expect(cubit.state.activeQuery, isNull);
      expect(cubit.state.visibleEntries, isEmpty);
    });

    test('clear resets visible entries, active query, and highlighted index', () async {
      searcher.queryResults['tes'] = [_entry(name: 'test-sanad-plugin')];
      await cubit.loadForWorkspace('workspace-1');
      cubit.onComposerChanged(const TextEditingValue(text: '/tes', selection: TextSelection.collapsed(offset: 4)));
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.visibleEntries, isNotEmpty);
      expect(cubit.state.activeQuery, isNotNull);

      cubit.clear();

      expect(cubit.state.visibleEntries, isEmpty);
      expect(cubit.state.activeQuery, isNull);
      expect(cubit.state.highlightedIndex, 0);
    });

    test('clear rejects a stale search response that completes afterward', () async {
      final delayedSearch = Completer<List<SlashCommandEntry>>();
      searcher.delayedResults['compact'] = delayedSearch;

      cubit.onComposerChanged(
        const TextEditingValue(
          text: '/compact',
          selection: TextSelection.collapsed(offset: 8),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(searcher.requests, isNotEmpty);

      cubit.clear();
      delayedSearch.complete([
        _entry(name: 'compact', type: SlashCommandType.runtimeAction),
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state.activeQuery, isNull);
      expect(cubit.state.visibleEntries, isEmpty);
    });

    test('moves the highlighted selection with keyboard navigation', () async {
      searcher.entriesByWorkspace['workspace-1'] = [
        _entry(name: 'alpha'),
        _entry(name: 'beta'),
        _entry(name: 'gamma'),
      ];
      searcher.queryResults[''] = [
        _entry(name: 'alpha'),
        _entry(name: 'beta'),
        _entry(name: 'gamma'),
      ];

      await cubit.loadForWorkspace('workspace-1');
      cubit.onComposerChanged(const TextEditingValue(text: '/', selection: TextSelection.collapsed(offset: 1)));
      await Future<void>.delayed(Duration.zero);

      cubit.moveHighlight(1);
      expect(cubit.state.highlightedIndex, 1);

      cubit.moveHighlight(-1);
      expect(cubit.state.highlightedIndex, 0);
    });

    test('rewriteMessageForDispatch keeps the user message unchanged', () async {
      searcher.entriesByWorkspace['workspace-1'] = [_entry(name: 'test-sanad-plugin')];

      await cubit.loadForWorkspace('workspace-1');

      final rewritten = cubit.rewriteMessageForDispatch('test-sanad-plugin please help me');

      expect(rewritten, 'test-sanad-plugin please help me');
    });

    test('rewriteMessageForDispatch does not transform selected slash tokens into prefixed invocations', () async {
      searcher.entriesByWorkspace['workspace-1'] = [_entry(name: 'Sanad Agentic Developer')];

      await cubit.loadForWorkspace('workspace-1');

      final rewritten = cubit.rewriteMessageForDispatch(
        'tell me about Sanad Agentic Developer',
        selectedTokens: const [
          SlashCommandDispatchToken(
            entry: SlashCommandEntry(
              sourceId: 'test',
              command: 'Sanad Agentic Developer',
              insertText: 'Sanad Agentic Developer',
            ),
            start: 14,
            end: 36,
          ),
        ],
      );

      expect(rewritten, 'tell me about Sanad Agentic Developer');
    });
  });
}

class _FakeSlashCommandsSearcher {
  final Map<String?, List<SlashCommandEntry>> entriesByWorkspace = {};
  final Map<String, List<SlashCommandEntry>> queryResults = {};
  final Map<String, Completer<List<SlashCommandEntry>>> delayedResults = {};
  final List<Map<String, String?>> requests = [];

  Future<List<SlashCommandEntry>> call({
    String? query,
    String? workspaceId,
  }) async {
    requests.add({
      'query': query,
      'workspace_id': workspaceId,
    });
    if (query != null) {
      final delayedResult = delayedResults[query];
      if (delayedResult != null) return delayedResult.future;
      return queryResults[query] ?? const [];
    }
    return entriesByWorkspace[workspaceId] ?? const [];
  }
}

SlashCommandEntry _entry({
  required String name,
  String? description,
  SlashCommandType type = SlashCommandType.skill,
}) {
  return SlashCommandEntry(
    sourceId: 'test',
    command: name,
    insertText: name,
    description: description,
    type: type,
  );
}
