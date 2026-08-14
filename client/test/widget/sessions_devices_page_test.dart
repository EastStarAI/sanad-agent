import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/auth/infrastructure/auth_service.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/settings/data/account_lifecycle_repository.dart';
import 'package:sanad_client/features/settings/domain/account_lifecycle.dart';
import 'package:sanad_client/features/settings/presentation/bloc/account_lifecycle_cubit.dart';
import 'package:sanad_client/features/settings/presentation/widgets/sessions_devices_page.dart';

class _FakeAccountRepository extends AccountLifecycleRepository {
  _FakeAccountRepository(this.result) : super(authService: AuthService());

  AccountLifecycleSnapshot result;
  Object? error;
  int fetches = 0;

  @override
  Future<AccountLifecycleSnapshot> fetch() async {
    fetches += 1;
    if (error case final failure?) throw failure;
    return result;
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
}
