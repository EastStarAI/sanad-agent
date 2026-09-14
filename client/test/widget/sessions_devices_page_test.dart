import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/settings/data/account_lifecycle_repository.dart';
import 'package:sanad_client/features/settings/domain/account_lifecycle.dart';
import 'package:sanad_client/features/settings/presentation/bloc/account_lifecycle_cubit.dart';
import 'package:sanad_client/features/settings/presentation/widgets/sessions_devices_page.dart';

class _FakeAccountRepository implements AccountLifecycleRepository {
  _FakeAccountRepository(this.result);

  final changesController = StreamController<void>.broadcast();
  final readinessController = StreamController<bool>.broadcast();
  AccountLifecycleSnapshot result;
  Object? error;
  int fetches = 0;
  bool ready = true;
  final revokedIds = <String>[];

  @override
  Stream<void> get changes => changesController.stream;

  @override
  Stream<bool> get readinessChanges => readinessController.stream;

  @override
  bool get isReady => ready;

  @override
  Future<AccountLifecycleSnapshot> fetch() async {
    fetches += 1;
    if (error case final failure?) throw failure;
    return result;
  }

  @override
  Future<AccountRevokeResult> revoke(AccountPrincipal principal) async {
    revokedIds.add(principal.id);
    return const AccountRevokeResult(
      requestId: 'request-1',
      currentSessionRevoked: false,
    );
  }

  @override
  Future<void> dispose() async {
    await changesController.close();
    await readinessController.close();
  }
}

AccountPrincipal _principal({
  required AccountPrincipalKind kind,
  required String id,
  required AccountPresenceStatus status,
  bool current = false,
}) => AccountPrincipal(
  kind: kind,
  id: id,
  status: status,
  isCurrent: current,
  metadata: const {'platform_family': 'macos', 'app_version': '1.2.3'},
  lastActiveAt: DateTime.utc(2026, 8, 12, 10, 30),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AccountLifecycleCubit> pumpPage(
    WidgetTester tester,
    _FakeAccountRepository repository, {
    Size size = const Size(1200, 800),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final cubit = AccountLifecycleCubit(repository);
    addTearDown(() async => cubit.close());
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider.value(
          value: cubit,
          child: SessionsDevicesPage(
            devices: [
              DeviceConfig(id: 'agent-1', name: 'Office Agent', isOnline: true),
            ],
            onOpenDevice: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return cubit;
  }

  testWidgets('renders current session and authoritative presence states on wide layout', (tester) async {
    final repository = _FakeAccountRepository(
      AccountLifecycleSnapshot(
        presenceAvailable: false,
        items: [
          _principal(
            kind: AccountPrincipalKind.clientSession,
            id: 'session-current',
            status: AccountPresenceStatus.online,
            current: true,
          ),
          _principal(
            kind: AccountPrincipalKind.clientSession,
            id: 'session-remote',
            status: AccountPresenceStatus.offline,
          ),
          _principal(
            kind: AccountPrincipalKind.agentDevice,
            id: 'agent-1',
            status: AccountPresenceStatus.unavailable,
          ),
        ],
      ),
    );

    await pumpPage(tester, repository);

    expect(find.text('Sessions & Devices'), findsOneWidget);
    expect(find.textContaining('Current'), findsOneWidget);
    expect(find.text('Online'), findsOneWidget);
    expect(find.text('Offline'), findsOneWidget);
    expect(find.text('Status unavailable'), findsOneWidget);
    expect(find.textContaining('Last active'), findsNWidgets(3));
    expect(repository.fetches, 1);
  });

  testWidgets('keeps stale snapshot visible when compact refresh fails', (tester) async {
    final repository = _FakeAccountRepository(
      AccountLifecycleSnapshot(
        presenceAvailable: true,
        items: [
          _principal(
            kind: AccountPrincipalKind.clientSession,
            id: 'session-current',
            status: AccountPresenceStatus.online,
            current: true,
          ),
        ],
      ),
    );
    final cubit = await pumpPage(
      tester,
      repository,
      size: const Size(390, 780),
    );

    repository.error = const AccountLifecycleException(
      'Sessions and devices could not be refreshed.',
    );
    await cubit.load();
    await tester.pumpAndSettle();

    expect(cubit.state.snapshot?.clientSessions.single.isCurrent, isTrue);
    expect(find.text('Sessions & Devices'), findsOneWidget);
    expect(find.text('Sessions and devices could not be refreshed.'), findsWidgets);
  });

  testWidgets('shows an initial retry surface without reporting offline', (tester) async {
    final repository = _FakeAccountRepository(
      const AccountLifecycleSnapshot(items: [], presenceAvailable: false),
    )..error = const AccountLifecycleException('Sessions and devices could not be refreshed.');

    await pumpPage(tester, repository);

    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Offline'), findsNothing);
  });

  testWidgets('cancel keeps the current Client session authorized', (tester) async {
    final repository = _FakeAccountRepository(
      AccountLifecycleSnapshot(
        presenceAvailable: true,
        items: [
          _principal(
            kind: AccountPrincipalKind.clientSession,
            id: 'session-current',
            status: AccountPresenceStatus.online,
            current: true,
          ),
        ],
      ),
    );
    await pumpPage(tester, repository);

    await tester.tap(find.byKey(const Key('revoke_session_btn_session-current')));
    await tester.pumpAndSettle();
    expect(find.text('Sign out this Client?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('confirm_revoke_cancel_btn')));
    await tester.pumpAndSettle();

    expect(repository.revokedIds, isEmpty);
    expect(find.text('Sign out this Client?'), findsNothing);
  });

  testWidgets('confirmed remote Client revoke targets exactly that row', (tester) async {
    final repository = _FakeAccountRepository(
      AccountLifecycleSnapshot(
        presenceAvailable: true,
        items: [
          _principal(
            kind: AccountPrincipalKind.clientSession,
            id: 'session-remote',
            status: AccountPresenceStatus.offline,
          ),
        ],
      ),
    );
    await pumpPage(tester, repository);

    await tester.tap(find.byKey(const Key('revoke_session_btn_session-remote')));
    await tester.pumpAndSettle();
    expect(find.text('Revoke access?'), findsOneWidget);

    await tester.tap(find.byKey(const Key('confirm_revoke_action_btn')));
    await tester.pumpAndSettle();

    expect(repository.revokedIds, ['session-remote']);
    expect(repository.fetches, 2);
  });

  testWidgets('active page refreshes on lifecycle change and reconnect only', (tester) async {
    final repository = _FakeAccountRepository(
      AccountLifecycleSnapshot(
        presenceAvailable: true,
        items: [
          _principal(
            kind: AccountPrincipalKind.clientSession,
            id: 'session-before',
            status: AccountPresenceStatus.online,
          ),
        ],
      ),
    );
    await pumpPage(tester, repository);
    expect(repository.fetches, 1);

    repository.result = AccountLifecycleSnapshot(
      presenceAvailable: true,
      items: [
        _principal(
          kind: AccountPrincipalKind.clientSession,
          id: 'session-after',
          status: AccountPresenceStatus.online,
        ),
      ],
    );
    repository.changesController.add(null);
    repository.changesController.add(null);
    await tester.pumpAndSettle();
    expect(repository.fetches, 2);
    expect(find.byKey(const Key('revoke_session_btn_session-after')), findsOneWidget);

    repository.ready = false;
    repository.readinessController.add(false);
    await tester.pumpAndSettle();
    expect(repository.fetches, 2);
    expect(find.textContaining('Showing the last synchronized snapshot'), findsOneWidget);

    repository.ready = true;
    repository.readinessController.add(true);
    await tester.pumpAndSettle();
    expect(repository.fetches, 3);
  });

  test('auth and reconnect do not fetch before the lifecycle page loads', () async {
    final repository = _FakeAccountRepository(
      const AccountLifecycleSnapshot(items: [], presenceAvailable: true),
    );
    final cubit = AccountLifecycleCubit(repository);

    repository.readinessController.add(false);
    repository.readinessController.add(true);
    repository.changesController.add(null);
    await Future<void>.delayed(Duration.zero);

    expect(repository.fetches, 0);
    await cubit.close();
    await repository.dispose();
  });
}
