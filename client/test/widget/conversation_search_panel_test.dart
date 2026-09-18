import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/session_search.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_search_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/sidebar/conversation_search_panel.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';

import '../helpers/fake_conversation_repository.dart';

void main() {
  final device = DeviceConfig(id: 'device-1', name: 'Device', isOnline: true);
  final hit = SessionSearchHit(
    session: Session(
      id: 'session-1',
      title: 'Matched conversation',
      deviceId: 'device-1',
      workspaceName: 'Workspace',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    ),
    matchKind: SessionSearchMatchKind.content,
    snippet: 'A safe matching snippet',
    anchorEventId: 'history:session-1:1:user_message:0',
  );

  Future<void> pumpPanel(
    WidgetTester tester, {
    required FakeConversationRepository repository,
    required ValueChanged<SessionSearchHit> onSelected,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider(
            create: (_) => SessionSearchCubit(repository: repository),
            child: SizedBox(
              width: 600,
              height: 700,
              child: ConversationSearchPanel(
                device: device,
                onSelected: onSelected,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('button opens a dialog on wide layout', (tester) async {
    final repository = FakeConversationRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider(
            create: (_) => SessionSearchCubit(repository: repository),
            child: ConversationSearchButton(
              device: device,
              isDrawerMode: false,
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('conversation_search_button')));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byKey(const Key('conversation_search_field')), findsOneWidget);
  });

  testWidgets('button opens a bottom sheet in drawer mode', (tester) async {
    final repository = FakeConversationRepository();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider(
            create: (_) => SessionSearchCubit(repository: repository),
            child: ConversationSearchButton(
              device: device,
              isDrawerMode: true,
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('conversation_search_button')));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byKey(const Key('conversation_search_field')), findsOneWidget);
  });

  testWidgets('shows results and supports keyboard selection', (tester) async {
    final repository = FakeConversationRepository();
    repository.searchSessionsHandler = (_, _, _) async => SessionSearchPage(hits: [hit], hasMore: false);
    SessionSearchHit? selected;
    await pumpPanel(
      tester,
      repository: repository,
      onSelected: (value) => selected = value,
    );

    await tester.enterText(find.byKey(const Key('conversation_search_field')), 'needle');
    await tester.pump(SessionSearchCubit.debounceDuration);
    await tester.pump();

    expect(find.text('Matched conversation'), findsOneWidget);
    expect(find.textContaining('Workspace · Message match · 2026-01-01'), findsOneWidget);
    expect(find.text('A safe matching snippet'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(selected?.session.id, 'session-1');
  });

  testWidgets('does not select while IME composition is active', (tester) async {
    final repository = FakeConversationRepository();
    repository.searchSessionsHandler = (_, _, _) async => SessionSearchPage(hits: [hit], hasMore: false);
    SessionSearchHit? selected;
    await pumpPanel(
      tester,
      repository: repository,
      onSelected: (value) => selected = value,
    );

    final field = find.byKey(const Key('conversation_search_field'));
    await tester.tap(field);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: 'needle', composing: TextRange(start: 0, end: 6)),
    );
    await tester.pump(SessionSearchCubit.debounceDuration);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(selected, isNull);
  });

  testWidgets('shows empty and retryable error states', (tester) async {
    final repository = FakeConversationRepository();
    repository.searchSessionsHandler = (_, query, _) async {
      if (query == 'fail') throw StateError('offline');
      return const SessionSearchPage(hits: [], hasMore: false);
    };
    await pumpPanel(tester, repository: repository, onSelected: (_) {});
    final field = find.byKey(const Key('conversation_search_field'));

    await tester.enterText(field, 'none');
    await tester.pump(SessionSearchCubit.debounceDuration);
    await tester.pump();
    expect(find.text('No conversations found.'), findsOneWidget);

    await tester.enterText(field, 'fail');
    await tester.pump(SessionSearchCubit.debounceDuration);
    await tester.pump();
    expect(find.text('Conversation search failed. Try again.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
