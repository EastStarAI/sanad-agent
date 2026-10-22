import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('application startup guards native platform access on Web', () {
    final source = File('lib/app.dart').readAsStringSync();

    // Platform branches go through the Web-safe AppPlatform facade; startup
    // never imports dart:io or reads the native Platform class directly.
    expect(source, contains('AppPlatform.'));
    expect(source, isNot(contains("import 'dart:io';")));
    expect(source, isNot(contains(RegExp(r'(?<![A-Za-z])Platform\.is'))));
  });

  test('shared composition never resolves native Client CLI state eagerly', () {
    final injection = File('lib/core/di/injection.dart').readAsStringSync();
    final module = File(
      'lib/core/di/modules/client_cli_module.dart',
    ).readAsStringSync();

    // Registration is gated by the Client CLI platform owner, and shared
    // composition never resolves the native Home itself: v1.0.18 did, and Web
    // startup failed on `Platform.environment` before runApp.
    final gate = injection.indexOf('ClientCliPlatform.isSupported');
    final registration = injection.indexOf('ClientCliModule().register(getIt)');
    expect(gate, isNonNegative, reason: 'Client CLI gate is missing');
    expect(registration, greaterThan(gate));
    expect(injection, isNot(contains('resolveSanadHome')));
    expect(injection, isNot(contains('registerSingleton<ClientCliHost>')));
    expect(injection, isNot(contains('registerLazySingleton<ClientCliHost>')));

    // Home resolution lives inside the module's lazy host factory, so a desktop
    // Client that never starts the host never reads the environment.
    final factory = module.indexOf('registerLazySingleton<ClientCliHost>');
    expect(factory, isNonNegative);
    expect(module.indexOf('resolveSanadHome'), greaterThan(factory));
  });

  test('remote-only consumers gate Client CLI consumption', () {
    for (final path in [
      'lib/core/presentation/app/app_providers.dart',
      'lib/core/presentation/app/app_auth_listener.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(
        source,
        contains('ClientCliPlatform.isSupported'),
        reason: '$path must not read Client CLI state on remote-only platforms',
      );
    }
  });

  test('startup tracing stays behind the desktop platform boundary', () {
    final source = File(
      'lib/core/bootstrap/app_bootstrap.dart',
    ).readAsStringSync();

    // Tracing writes native files under the Sanad Home; the platform decision
    // belongs to AppPlatform, not an ad-hoc Web check.
    expect(source, contains('!AppPlatform.isDesktop'));
    expect(source, isNot(contains('kIsWeb')));
  });

  test('Web authentication bridge is external and loads before Flutter', () {
    final index = File('web/index.html').readAsStringSync();
    final bridge = File('web/auth_popup.js').readAsStringSync();

    expect(index, isNot(contains('<script>')));
    expect(index, contains('<script src="auth_popup.js"></script>'));
    expect(index, contains('<script src="splash.js"></script>'));
    expect(File('web/splash.js').existsSync(), isTrue);
    expect(
      index.indexOf('auth_popup.js'),
      lessThan(index.indexOf('flutter_bootstrap.js')),
    );
    expect(bridge, contains('window.AuthPopup'));
  });
}
