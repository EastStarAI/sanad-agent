import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/isolated_sanad_test_home.dart';

/// Regression for the G0 incident: `sanad … --home <TestHome>` migrated the
/// default Home because Home preparation and the vault ran before `--home`.
///
/// The real CLI entry runs as a subprocess with `HOME=<tmpB>`, no
/// `SANAD_HOME`/`SANAD_STATE_HOME`, and `--home <tmpA>`. The default Home
/// `<tmpB>/.sanad` holds dummy legacy secret files and must stay byte-for-byte
/// untouched. `SANAD_E2E_TEST_MODE=true` is the existing subprocess test seam;
/// it also selects the owner-only file secret store, so the subprocess never
/// reaches the OS credential vault.
void main() {
  useIsolatedSanadTestHome();

  late Directory root;
  late Directory selectedHome;
  late Directory userHome;
  late Directory defaultHome;

  setUp(() {
    root = Directory(
      Directory.systemTemp
          .createTempSync('sanad-g0-home-selection-')
          .resolveSymbolicLinksSync(),
    );
    selectedHome = Directory(p.join(root.path, 'selected-home'))..createSync();
    userHome = Directory(p.join(root.path, 'user-home'))..createSync();
    defaultHome = Directory(p.join(userHome.path, '.sanad'))..createSync();
    File(
      p.join(defaultHome.path, 'provider_secrets.json'),
    ).writeAsStringSync('{"dummy-provider":{"api_key":"g0-dummy-not-secret"}}');
    File(
      p.join(defaultHome.path, 'mcp_secrets.json'),
    ).writeAsStringSync('{"mcp-secret://dummy":"g0-dummy-not-secret"}');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Map<String, String> isolatedEnvironment() {
    final parentHome =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    return {
      if (Platform.environment['PATH'] != null)
        'PATH': Platform.environment['PATH']!,
      // `dart run` resolves packages through the developer's pub cache, which
      // `HOME` would otherwise relocate.
      'PUB_CACHE':
          Platform.environment['PUB_CACHE'] ??
          p.join(parentHome ?? userHome.path, '.pub-cache'),
      'HOME': userHome.path,
      if (Platform.isWindows) 'USERPROFILE': userHome.path,
      'SANAD_E2E_TEST_MODE': 'true',
    };
  }

  Future<ProcessResult> runCli(List<String> arguments) {
    return Process.run(
      Platform.resolvedExecutable,
      ['run', 'bin/sanad_agent.dart', ...arguments],
      workingDirectory: Directory.current.path,
      environment: isolatedEnvironment(),
      includeParentEnvironment: false,
    ).timeout(const Duration(seconds: 120));
  }

  Map<String, String> snapshot(Directory directory) {
    final entries = <String, String>{};
    for (final entity in directory.listSync(recursive: true)) {
      final relative = p.relative(entity.path, from: directory.path);
      entries[relative] = entity is File
          ? base64Encode(entity.readAsBytesSync())
          : '<dir>';
    }
    return entries;
  }

  for (final form in const ['command option', 'global option', 'equals form']) {
    test('--home ($form) never touches the default Home', () async {
      final before = snapshot(defaultHome);
      final arguments = switch (form) {
        'command option' => ['models', '--home', selectedHome.path],
        'global option' => ['--home', selectedHome.path, 'models'],
        _ => ['models', '--home=${selectedHome.path}'],
      };

      final result = await runCli(arguments);

      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(snapshot(defaultHome), before);
      expect(File(p.join(defaultHome.path, 'state.db')).existsSync(), isFalse);
      // The command ran against the selected Home instead.
      expect(File(p.join(selectedHome.path, '.env')).existsSync(), isTrue);
    }, timeout: const Timeout(Duration(minutes: 3)));
  }

  test('an unparseable command line with --home touches no Home', () async {
    final before = snapshot(defaultHome);

    final result = await runCli([
      'models',
      '--no-such-option',
      '--home',
      selectedHome.path,
    ]);

    expect(result.exitCode, 64, reason: result.stderr.toString());
    expect(snapshot(defaultHome), before);
    expect(selectedHome.listSync(), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
