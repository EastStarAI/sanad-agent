import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/session_search.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_search_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_search_state.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';

import '../../helpers/fake_conversation_repository.dart';

void main() {
  final device = DeviceConfig(id: 'device-1', name: 'Device', isOnline: true);

  SessionSearchHit hit(String id) => SessionSearchHit(
    session: Session(
      id: id,
      title: id,
      deviceId: device.id,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    ),
    matchKind: SessionSearchMatchKind.content,
    snippet: 'matching text',
    anchorEventId: 'history:$id:1:user_message:0',
  );

  test('debounces and ignores a stale first-page response', () async {
    final repository = FakeConversationRepository();
    final requests = <String, Completer<SessionSearchPage>>{};
    repository.searchSessionsHandler = (_, query, _) {
      return (requests[query] ??= Completer<SessionSearchPage>()).future;
    };
    final cubit = SessionSearchCubit(repository: repository);
    addTearDown(cubit.close);

    cubit.queryChanged(device, 'first');
    await Future<void>.delayed(SessionSearchCubit.debounceDuration + const Duration(milliseconds: 10));
    cubit.queryChanged(device, 'second');
    await Future<void>.delayed(SessionSearchCubit.debounceDuration + const Duration(milliseconds: 10));
    requests['first']!.complete(SessionSearchPage(hits: [hit('old')], hasMore: false));
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.query, 'second');
    expect(cubit.state.hits, isEmpty);

    requests['second']!.complete(SessionSearchPage(hits: [hit('new')], hasMore: false));
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.hits.single.session.id, 'new');
  });

  test('clearing query invalidates an in-flight response', () async {
    final repository = FakeConversationRepository();
    final request = Completer<SessionSearchPage>();
    repository.searchSessionsHandler = (_, _, _) => request.future;
    final cubit = SessionSearchCubit(repository: repository);
    addTearDown(cubit.close);

    cubit.queryChanged(device, 'needle');
    await Future<void>.delayed(SessionSearchCubit.debounceDuration + const Duration(milliseconds: 10));
    cubit.queryChanged(device, '');
    request.complete(SessionSearchPage(hits: [hit('stale')], hasMore: false));
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state.status, SessionSearchStatus.idle);
    expect(cubit.state.hits, isEmpty);
  });

  test('paginates and retries a failed first page', () async {
    final repository = FakeConversationRepository();
    var firstAttempts = 0;
    repository.searchSessionsHandler = (_, _, cursor) async {
      if (cursor == null && firstAttempts++ == 0) throw StateError('offline');
      if (cursor == null) {
        return SessionSearchPage(hits: [hit('one')], nextCursor: 'next', hasMore: true);
      }
      return SessionSearchPage(hits: [hit('two')], hasMore: false);
    };
    final cubit = SessionSearchCubit(repository: repository);
    addTearDown(cubit.close);

    cubit.queryChanged(device, 'needle');
    await Future<void>.delayed(SessionSearchCubit.debounceDuration + const Duration(milliseconds: 10));
    expect(cubit.state.status, SessionSearchStatus.failure);

    await cubit.retry();
    expect(cubit.state.hits.single.session.id, 'one');
    await cubit.loadMore();
    expect(cubit.state.hits.map((item) => item.session.id), ['one', 'two']);
    expect(cubit.state.hasMore, isFalse);
  });
}
