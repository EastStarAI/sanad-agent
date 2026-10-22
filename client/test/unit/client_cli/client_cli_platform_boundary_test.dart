import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sanad_client/core/config/app_config.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/di/modules/client_cli_module.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_home_resolver.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_host.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_ownership.dart';
import 'package:sanad_client/features/client_cli/domain/client_cli_platform.dart';
import 'package:sanad_client/features/client_cli/presentation/bloc/client_cli_cubit.dart';
import 'package:sanad_client/utils/app_platform.dart';

/// Native-side twin of `test/web/web_startup_platform_guard_test.dart`: the same
/// composition must keep registering the Client CLI cluster on desktop and must
/// skip it entirely on remote-only platforms.
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    AppPlatform.overrideIsDesktop = null;
    AppPlatform.overrideIsMobile = null;
    // Dispose stays off on purpose: the desktop case resolves the real host,
    // whose disposal would release an ownership record under the active Sanad
    // Home. Nothing else in this suite touches that Home. Home resolution is a
    // pure path computation over environment strings, `ClientCliHost` performs
    // no I/O before `start()`/`stop()`, and this test never calls either.
    await getIt.reset(dispose: false);
  });

  test('remote-only composition never registers native Client CLI state', () async {
    AppPlatform.overrideIsDesktop = false;
    AppPlatform.overrideIsMobile = false;

    expect(ClientCliPlatform.isSupported, isFalse);

    await configureDependencies();

    expect(getIt.isRegistered<ClientCliHost>(), isFalse);
    expect(getIt.isRegistered<ClientCliCubit>(), isFalse);
    expect(getIt.isRegistered<ClientCliOwnership>(), isFalse);
  });

  test('desktop composition keeps the Client CLI host, settings and Home', () async {
    AppPlatform.overrideIsDesktop = true;
    AppPlatform.overrideIsMobile = false;

    expect(ClientCliPlatform.isSupported, isTrue);

    await configureDependencies();

    expect(getIt.isRegistered<ClientCliHost>(), isTrue);
    expect(getIt.isRegistered<ClientCliCubit>(), isTrue);

    // Registration stays repeatable: the same guards protect a second run.
    expect(() => const ClientCliModule().register(getIt), returnsNormally);

    final host = getIt<ClientCliHost>();
    final expectedHome = const ClientCliHomeResolver().resolveSanadHome(
      explicitHome: AppConfig.sanadHome.isNotEmpty ? AppConfig.sanadHome : null,
    );
    // Resolving the host only computes the Home path; the relay stays unbound
    // and no ownership record is read or written.
    expect(host.sanadHome, expectedHome);
    expect(p.isAbsolute(host.sanadHome), isTrue);
    expect(host.isRunning, isFalse);
    expect(getIt<ClientCliCubit>(), isA<ClientCliCubit>());
  });
}
