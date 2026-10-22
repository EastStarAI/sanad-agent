import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/di/modules/client_cli_module.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_approval_coordinator.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_host.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_ownership.dart';
import 'package:sanad_client/features/client_cli/domain/client_cli_platform.dart';
import 'package:sanad_client/features/client_cli/presentation/bloc/client_cli_cubit.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:sanad_client/utils/app_platform.dart';

/// Behavioral Web startup guard.
///
/// v1.0.18 shipped Web builds that aborted in `configureDependencies()` before
/// `runApp` because shared composition eagerly resolved the Client CLI Home from
/// native process state (`Unsupported operation: Platform._environment`). A
/// source-string check cannot catch that class of regression, so this suite
/// executes the real dependency composition inside Chrome.
///
/// Run it explicitly; the default `flutter test` run has no browser target:
/// `fvm flutter test --platform chrome test/web/web_startup_platform_guard_test.dart`
void main() {
  const browserOnly =
      'Requires a real browser target: '
      'fvm flutter test --platform chrome '
      'test/web/web_startup_platform_guard_test.dart';

  final skipReason = AppPlatform.isWeb ? null : browserOnly;

  setUp(() async {
    await getIt.reset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    await getIt.reset();
  });

  test('Web shared composition starts without native platform state', () async {
    expect(AppPlatform.isWeb, isTrue);
    expect(ClientCliPlatform.isSupported, isFalse);

    // The regression: any eager native read (Home resolution, ownership record,
    // process environment) throws here instead of completing.
    await configureDependencies();

    expect(getIt.isRegistered<ClientCliHost>(), isFalse);
    expect(getIt.isRegistered<ClientCliCubit>(), isFalse);
    expect(getIt.isRegistered<ClientCliOwnership>(), isFalse);
  }, skip: skipReason, timeout: const Timeout(Duration(minutes: 2)));

  test('remote-only startup keeps the cloud transport and neutral seams', () async {
    await configureDependencies();

    // Web stays remote-only: the resolved default socket is the cloud service.
    final defaultSocket = getIt<SanadSocketService>();
    final cloudSocket = getIt<SanadSocketService>(
      instanceName: 'cloudSocketService',
    );
    expect(identical(defaultSocket, cloudSocket), isTrue);

    // The approval coordinator is platform-neutral and remains available so the
    // desktop approval overlay has one owner on every platform.
    expect(getIt<ClientCliApprovalCoordinator>(), isA<ClientCliApprovalCoordinator>());
  }, skip: skipReason, timeout: const Timeout(Duration(minutes: 2)));

  test('native Client CLI registration fails closed off desktop', () async {
    expect(ClientCliPlatform.isSupported, isFalse);
    expect(
      () => const ClientCliModule().register(getIt),
      throwsA(isA<StateError>()),
    );
  }, skip: skipReason);
}
