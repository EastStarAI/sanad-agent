import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/settings/data/account_lifecycle_repository.dart';
import 'package:sanad_client/features/settings/domain/account_lifecycle.dart';

class _FakeLifecycleSocket implements AccountLifecycleSocket {
  final responsesController = StreamController<Map<String, dynamic>>.broadcast();
  final revokeController = StreamController<Map<String, dynamic>>.broadcast();
  final changesController = StreamController<void>.broadcast();
  final readinessController = StreamController<bool>.broadcast();
  final emitted = <(String, Map<String, dynamic>)>[];
  bool ready = true;

  @override
  Stream<Map<String, dynamic>> get responses => responsesController.stream;

  @override
  Stream<Map<String, dynamic>> get revokeResults => revokeController.stream;

  @override
  Stream<void> get changes => changesController.stream;

  @override
  Stream<bool> get readinessChanges => readinessController.stream;

  @override
  bool get isReady => ready;

  @override
  void emit(String event, Map<String, dynamic> payload) {
    emitted.add((event, payload));
  }

  Future<void> close() async {
    await responsesController.close();
    await revokeController.close();
    await changesController.close();
    await readinessController.close();
  }
}

AccountPrincipal _principal() => AccountPrincipal(
  kind: AccountPrincipalKind.clientSession,
  id: 'public-session',
  metadata: const {'platform_family': 'ios'},
  status: AccountPresenceStatus.online,
  isCurrent: false,
);

void main() {
  late _FakeLifecycleSocket socket;
  late AccountLifecycleSocketRepository repository;
  var requestCounter = 0;

  setUp(() {
    requestCounter = 0;
    socket = _FakeLifecycleSocket();
    repository = AccountLifecycleSocketRepository(
      socket: socket,
      requestIdFactory: () => 'request-${++requestCounter}',
      timeout: const Duration(milliseconds: 50),
    );
  });

  tearDown(() async {
    await repository.dispose();
    await socket.close();
  });

  test('fetch uses authenticated socket identity and correlates response', () async {
    final future = repository.fetch();
    await Future<void>.delayed(Duration.zero);

    final (event, payload) = socket.emitted.single;
    expect(event, 'get_account_lifecycle');
    expect(payload, {'version': 1, 'limit': 100, 'request_id': 'request-1'});
    expect(payload, isNot(contains('access_token')));
    expect(payload, isNot(contains('user_id')));
    expect(payload, isNot(contains('family_id')));

    socket.responsesController.add({
      'version': 1,
      'status': 'ok',
      'request_id': 'other-request',
      'items': const [],
    });
    socket.responsesController.add({
      'version': 1,
      'status': 'ok',
      'request_id': 'request-1',
      'presence_available': true,
      'items': [
        {
          'kind': 'client_session',
          'id': 'public-session',
          'metadata': {'platform_family': 'ios'},
          'status': 'online',
          'is_current': true,
        },
      ],
    });

    final snapshot = await future;
    expect(snapshot.presenceAvailable, isTrue);
    expect(snapshot.clientSessions.single.id, 'public-session');
    expect(snapshot.clientSessions.single.isCurrent, isTrue);
  });

  test('revoke is versioned, correlated, and contains no credential', () async {
    final future = repository.revoke(_principal());
    await Future<void>.delayed(Duration.zero);

    final (event, payload) = socket.emitted.single;
    expect(event, 'revoke_account_principal');
    expect(payload['target_id'], 'public-session');
    expect(payload['request_id'], 'request-1');
    expect(payload, isNot(contains('access_token')));

    socket.revokeController.add({
      'version': 1,
      'status': 'ok',
      'request_id': 'request-1',
      'result': 'revoked',
      'current_session_revoked': false,
    });

    final result = await future;
    expect(result.requestId, 'request-1');
    expect(result.currentSessionRevoked, isFalse);
  });

  test('disconnected fetch fails without emitting', () async {
    socket.ready = false;

    await expectLater(
      repository.fetch(),
      throwsA(
        isA<AccountLifecycleException>().having(
          (error) => error.message,
          'message',
          contains('Cloud'),
        ),
      ),
    );
    expect(socket.emitted, isEmpty);
  });

  test('change and readiness streams are forwarded lazily', () async {
    var changeCount = 0;
    final readiness = <bool>[];
    final changeSubscription = repository.changes.listen((_) => changeCount += 1);
    final readinessSubscription = repository.readinessChanges.listen(readiness.add);

    socket.changesController.add(null);
    socket.readinessController.add(false);
    await Future<void>.delayed(Duration.zero);

    expect(changeCount, 1);
    expect(readiness, [false]);
    await changeSubscription.cancel();
    await readinessSubscription.cancel();
  });
}
