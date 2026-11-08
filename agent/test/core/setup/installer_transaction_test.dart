import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/setup/service_account_policy.dart';
import 'package:test/test.dart';

import '../../support/host_home_guard.dart';

void main() {
  group('installer transaction', () {
    late Directory root;
  late Directory home;
  late Directory mockBin;
  late File commandLog;
  late HttpServer server;
  late String artifact;
  RealSanadHomeWatch? realHomeWatch;
  var manifestRequests = 0;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sanad-installer-test-');
    // A leak into the owner's real Home must fail this test, never replace the
    // installed binary.
    realHomeWatch = RealSanadHomeWatch.start();
    home = Directory(p.join(root.path, 'home'))..createSync(recursive: true);
    mockBin = Directory(p.join(root.path, 'mock-bin'))..createSync();
    commandLog = File(p.join(root.path, 'commands.log'));
    _writeExecutable(p.join(mockBin.path, 'uname'), '''#!/bin/sh
if [ "\${1:-}" = "-s" ]; then echo Darwin; else echo x86_64; fi
''');
    _writeExecutable(p.join(mockBin.path, 'codesign'), '#!/bin/sh\nexit 0\n');
    _writeExecutable(
      p.join(mockBin.path, 'id'),
      '''#!/bin/sh
case "\${1:-}" in
  -u) echo "\${FAKE_UID:-0}" ;;
  -un) echo "\${FAKE_USERNAME:-root}" ;;
  -gn) echo "\${FAKE_ACCOUNT:-sanad-agent}" ;;
  *) echo '' ;;
esac
''',
    );
    _writeExecutable(
      p.join(mockBin.path, 'getent'),
      '''#!/bin/sh
[ "\${1:-}" = "passwd" ] || exit 2
case "\${2:-}" in
  root) echo "root:x:0:0::\${FAKE_ROOT_HOME:-/root}:/bin/sh" ;;
  "\${FAKE_ACCOUNT:-ubuntu}")
    echo "\${2}:x:1000:1000::\${FAKE_USER_HOME:-/home/\${2}}:/bin/bash"
    ;;
  *) exit 2 ;;
esac
''',
    );
    _writeExecutable(
      p.join(mockBin.path, 'chown'),
      '''#!/bin/sh
echo "chown \$*" >> "\$FAKE_COMMAND_LOG"
''',
    );
    for (final command in ['systemctl', 'rc-service', 'rc-update']) {
      _writeExecutable(p.join(mockBin.path, command), '#!/bin/sh\nexit 0\n');
    }
    artifact = '''#!/bin/sh
printf '%s\\n' "\$*" >> "\$FAKE_COMMAND_LOG"
case "\${1:-} \${2:-}" in
  "login --token-stdin")
    IFS= read -r token || true
    [ "\${FAKE_AUTH_FAIL:-0}" = "1" ] && exit 12
    exit 0
    ;;
  "login --cancel-pairing") exit 0 ;;
  "login --portal") [ "\${FAKE_AUTH_FAIL:-0}" = "1" ] && exit 12 || exit 0 ;;
  "service install")
    printf 'SANAD_HOME=%s\\n' "\${SANAD_HOME:-}" >> "\$FAKE_COMMAND_LOG"
    [ "\${FAKE_SERVICE_FAIL:-0}" = "1" ] && exit 13 || exit 0
    ;;
  "service status")
    echo 'Sanad Agent Service Status:'
    echo '  Installed:  No'
    echo '  Running:    No'
    exit 0
    ;;
  "service "*) exit 0 ;;
esac
exit 0
''';
    manifestRequests = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path.startsWith('/manifest')) manifestRequests++;
      if (request.uri.path == '/missing') {
        request.response.statusCode = HttpStatus.notFound;
      } else if (request.uri.path == '/artifact') {
        request.response.write(artifact);
      } else if (request.uri.path == '/artifact-arm64') {
        request.response.write(_arm64Artifact(artifact));
      } else if (request.uri.path == '/manifest' ||
          request.uri.path == '/manifest-missing-artifact' ||
          request.uri.path == '/manifest-both-architectures') {
        final bytes = utf8.encode(artifact);
        final artifactPath = request.uri.path == '/manifest'
            ? '/artifact'
            : '/missing';
        final arm64Bytes = utf8.encode(_arm64Artifact(artifact));
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'repository': 'EastStarAI/sanad-agent',
            'version': '1.2.3',
            'artifacts': [
              {
                'component': 'agent',
                'platform': 'macos',
                'architecture': 'x64',
                'public': true,
                'signature_type': 'developer-id',
                'filename': 'sanad-agent-1.2.3-macos-x64',
                'url': 'http://127.0.0.1:${server.port}$artifactPath',
                'sha256': sha256.convert(bytes).toString(),
                'size': bytes.length,
              },
              {
                'component': 'agent',
                'platform': 'linux',
                'architecture': 'x64',
                'public': true,
                'signature_type': 'sha256',
                'filename': 'sanad-agent-1.2.3-linux-x64',
                'url': 'http://127.0.0.1:${server.port}$artifactPath',
                'sha256': sha256.convert(bytes).toString(),
                'size': bytes.length,
              },
              if (request.uri.path == '/manifest-both-architectures')
                {
                  'component': 'agent',
                  'platform': 'linux',
                  'architecture': 'arm64',
                  'public': true,
                  'signature_type': 'sha256',
                  'filename': 'sanad-agent-1.2.3-linux-arm64',
                  'url': 'http://127.0.0.1:${server.port}/artifact-arm64',
                  'sha256': sha256.convert(arm64Bytes).toString(),
                  'size': arm64Bytes.length,
                },
            ],
          }),
        );
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    realHomeWatch?.verifyUnchanged();
    await root.delete(recursive: true);
  });

  test(
    'manifest 404 exits non-zero without creating an installation',
    () async {
      final result = await _runInstaller(
        home: home,
        mockBin: mockBin,
        commandLog: commandLog,
        manifestUrl: 'http://127.0.0.1:${server.port}/missing',
      );

      expect(result.exitCode, isNot(0));
      expect(File(p.join(home.path, '.sanad/bin/sanad')).existsSync(), isFalse);
    },
  );

  test(
    'artifact download failure leaves the previous install untouched',
    () async {
      final target = _installOldBinary(home, commandLog);
      final before = target.readAsStringSync();

      final result = await _runInstaller(
        home: home,
        mockBin: mockBin,
        commandLog: commandLog,
        manifestUrl:
            'http://127.0.0.1:${server.port}/manifest-missing-artifact',
      );

      expect(result.exitCode, isNot(0));
      expect(target.readAsStringSync(), before);
      expect(commandLog.readAsStringSync(), contains('service status'));
      expect(commandLog.readAsStringSync(), isNot(contains('service stop')));
    },
  );

  test(
    'authenticated upgrade requires cloud health and reports restored connection',
    () async {
      _installOldBinary(home, commandLog);

      final result = await _runInstaller(
        home: home,
        mockBin: mockBin,
        commandLog: commandLog,
        manifestUrl: 'http://127.0.0.1:${server.port}/manifest',
      );

      expect(result.exitCode, 0, reason: result.stderr.toString());
      final log = commandLog.readAsStringSync();
      expect(log, contains('login --status'));
      expect(
        log,
        contains(
          'service install --expected-version 1.2.3 --require-cloud --health-timeout 90',
        ),
      );
      expect(
        result.stdout.toString(),
        contains(
          'Existing account connection restored. Sanad Agent is online.',
        ),
      );
      expect(result.stdout.toString(), isNot(contains('local-only mode')));
    },
  );

  test(
    'auth failure restores the previous binary without logging token',
    () async {
      final target = _installOldBinary(home, commandLog);
      final result = await _runInstaller(
        home: home,
        mockBin: mockBin,
        commandLog: commandLog,
        manifestUrl: 'http://127.0.0.1:${server.port}/manifest',
        pairingToken: 'one-time-secret-token',
        extraEnvironment: const {'FAKE_AUTH_FAIL': '1'},
      );

      expect(result.exitCode, isNot(0));
      expect(target.readAsStringSync(), contains('old-agent'));
      expect(
        commandLog.readAsStringSync(),
        isNot(contains('one-time-secret-token')),
      );
      expect(File('${target.path}.rollback').existsSync(), isFalse);
    },
  );

  test(
    'service health failure cancels pairing and restores running install',
    () async {
      final target = _installOldBinary(home, commandLog);
      final result = await _runInstaller(
        home: home,
        mockBin: mockBin,
        commandLog: commandLog,
        manifestUrl: 'http://127.0.0.1:${server.port}/manifest',
        pairingToken: 'second-one-time-token',
        extraEnvironment: const {'FAKE_SERVICE_FAIL': '1'},
      );

      expect(result.exitCode, isNot(0));
      expect(target.readAsStringSync(), contains('old-agent'));
      final log = commandLog.readAsStringSync();
      expect(log, contains('login --cancel-pairing'));
      expect(log, contains('service start'));
      expect(log, isNot(contains('second-one-time-token')));
      // The completed authorization is discarded with the binary, so the
      // operator has to know the retry cannot reuse it.
      expect(
        result.stderr.toString(),
        contains('a retry needs a fresh pairing code or a new Portal approval'),
      );
    },
  );

  test(
    'root Linux install uses the dedicated account Home by default',
    () async {
      _useLinuxHost(mockBin);
      final systemHome = p.join(root.path, 'var-lib-sanad-agent');
      final rootHome = p.join(root.path, 'root-home');

      final result = await _runInstaller(
        home: home,
        mockBin: mockBin,
        commandLog: commandLog,
        manifestUrl: 'http://127.0.0.1:${server.port}/manifest',
        explicitHome: false,
        extraEnvironment: {
          'FAKE_UID': '0',
          'FAKE_ROOT_HOME': rootHome,
          'SANAD_INSTALL_SYSTEM_HOME': systemHome,
        },
      );

      expect(result.exitCode, 0, reason: result.stderr.toString());
      // The artifact, the Sanad Home the Agent resolves, and the unit's
      // SANAD_HOME are one Home the dedicated account owns, so systemd can
      // execute it and the health check reads the daemon's own credential.
      expect(File(p.join(systemHome, 'bin/sanad')).existsSync(), isTrue);
      expect(File(p.join(home.path, '.sanad/bin/sanad')).existsSync(), isFalse);
      expect(
        result.stdout.toString(),
        contains('Root install: using $systemHome'),
      );
      expect(commandLog.readAsStringSync(), contains('SANAD_HOME=$systemHome'));
    },
  );

  test(
    'root Linux install keeps an existing root Home instead of migrating it',
    () async {
      _useLinuxHost(mockBin);
      final target = _installOldBinary(home, commandLog);
      final systemHome = p.join(root.path, 'var-lib-sanad-agent');

      final result = await _runInstaller(
        home: home,
        mockBin: mockBin,
        commandLog: commandLog,
        manifestUrl: 'http://127.0.0.1:${server.port}/manifest',
        explicitHome: false,
        extraEnvironment: {
          'FAKE_UID': '0',
          // Root's own Home, not the process `HOME`: plain sudo can leave that
          // pointing at the invoking account.
          'FAKE_ROOT_HOME': home.path,
          'SANAD_INSTALL_SYSTEM_HOME': systemHome,
        },
      );

      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(target.readAsStringSync(), isNot(contains('old-agent')));
      expect(Directory(systemHome).existsSync(), isFalse);
    },
  );

  test('non-root Linux install keeps the invoking account Home', () async {
    _useLinuxHost(mockBin);
    final systemHome = p.join(root.path, 'var-lib-sanad-agent');

    final result = await _runInstaller(
      home: home,
      mockBin: mockBin,
      commandLog: commandLog,
      manifestUrl: 'http://127.0.0.1:${server.port}/manifest',
      explicitHome: false,
      extraEnvironment: {
        'FAKE_UID': '1000',
        'FAKE_USERNAME': 'developer',
        'SANAD_INSTALL_SYSTEM_HOME': systemHome,
      },
    );

    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(File(p.join(home.path, '.sanad/bin/sanad')).existsSync(), isTrue);
    expect(Directory(systemHome).existsSync(), isFalse);
  });

  test('root Linux install keeps the dedicated Home under sudo', () async {
    _useLinuxHost(mockBin);
    final systemHome = p.join(root.path, 'var-lib-sanad-agent');

    final result = await _runInstaller(
      home: home,
      mockBin: mockBin,
      commandLog: commandLog,
      manifestUrl: 'http://127.0.0.1:${server.port}/manifest',
      explicitHome: false,
      extraEnvironment: {
        'FAKE_UID': '0',
        'FAKE_USERNAME': 'root',
        'FAKE_ROOT_HOME': p.join(root.path, 'root-home'),
        'SUDO_USER': 'ubuntu',
        'SUDO_UID': '1000',
        'SANAD_INSTALL_SYSTEM_HOME': systemHome,
      },
    );

    expect(result.exitCode, 0, reason: result.stderr.toString());
    // A root install entered through sudo must behave exactly like a direct
    // root install: same account, same Home, no SUDO_USER participation.
    expect(
      result.stdout.toString(),
      contains('Root install: using $systemHome'),
    );
    expect(File(p.join(systemHome, 'bin/sanad')).existsSync(), isTrue);
    expect(commandLog.readAsStringSync(), contains('SANAD_HOME=$systemHome'));
  });

  test('run-as-user gives the named account its own Home and ownership', () async {
    _useLinuxHost(mockBin);
    final accountHome = p.join(root.path, 'home', 'ubuntu');

    final result = await _runInstaller(
      home: home,
      mockBin: mockBin,
      commandLog: commandLog,
      manifestUrl: 'http://127.0.0.1:${server.port}/manifest',
      explicitHome: false,
      runAsUser: 'ubuntu',
      extraEnvironment: {
        'FAKE_UID': '0',
        'FAKE_ROOT_HOME': p.join(root.path, 'root-home'),
        'FAKE_ACCOUNT': 'ubuntu',
        'FAKE_USER_HOME': accountHome,
      },
    );

    expect(result.exitCode, 0, reason: result.stderr.toString());
    final serviceHome = p.join(accountHome, '.sanad');
    expect(File(p.join(serviceHome, 'bin/sanad')).existsSync(), isTrue);
    expect(
      result.stdout.toString(),
      contains('The Sanad Agent service will run as ubuntu with $serviceHome'),
    );
    final log = commandLog.readAsStringSync();
    expect(log, contains('chown -R ubuntu $serviceHome'));
    expect(log, contains('--run-as-user ubuntu'));
  });

  test('run-as-user root is explicit and warns loudly', () async {
    _useLinuxHost(mockBin);
    final rootHome = p.join(root.path, 'root-home');

    final result = await _runInstaller(
      home: home,
      mockBin: mockBin,
      commandLog: commandLog,
      manifestUrl: 'http://127.0.0.1:${server.port}/manifest',
      explicitHome: false,
      runAsUser: 'root',
      extraEnvironment: {'FAKE_UID': '0', 'FAKE_ROOT_HOME': rootHome},
    );

    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(
      result.stderr.toString(),
      contains('Warning: the Agent daemon will run as root'),
    );
    expect(File(p.join(rootHome, '.sanad/bin/sanad')).existsSync(), isTrue);
    expect(commandLog.readAsStringSync(), contains('--run-as-user root'));
  });

  test('run-as-user refuses an account that does not exist', () async {
    _useLinuxHost(mockBin);

    final result = await _runInstaller(
      home: home,
      mockBin: mockBin,
      commandLog: commandLog,
      manifestUrl: 'http://127.0.0.1:${server.port}/manifest',
      explicitHome: false,
      runAsUser: 'nobody-here',
      extraEnvironment: {'FAKE_UID': '0', 'FAKE_ACCOUNT': 'ubuntu'},
    );

    expect(result.exitCode, 64);
    expect(result.stderr.toString(), contains('does not exist'));
    // Nothing was downloaded or paired for an account that cannot run it.
    expect(manifestRequests, 0);
  });

  test('refuses before download when a definition names another Home', () async {
    _useLinuxHost(mockBin);
    final configRoot = p.join(root.path, 'config-root');
    final definition = File(
      p.join(configRoot, 'etc/systemd/system/sanad-agent.service'),
    )..createSync(recursive: true);
    definition.writeAsStringSync('''[Service]
User=ubuntu
Environment="SANAD_HOME=/home/ubuntu/.sanad"
''');

    final result = await _runInstaller(
      home: home,
      mockBin: mockBin,
      commandLog: commandLog,
      manifestUrl: 'http://127.0.0.1:${server.port}/manifest',
      explicitHome: false,
      extraEnvironment: {
        'FAKE_UID': '0',
        'FAKE_ROOT_HOME': p.join(root.path, 'root-home'),
        'SANAD_INSTALL_SYSTEM_HOME': p.join(root.path, 'var-lib-sanad-agent'),
        'SANAD_INSTALL_CONFIG_ROOT': configRoot,
      },
    );

    expect(result.exitCode, 71);
    expect(
      result.stderr.toString(),
      contains('registered for another Sanad Home'),
    );
    expect(result.stderr.toString(), contains('/home/ubuntu/.sanad'));
    expect(
      result.stderr.toString(),
      contains('systemctl disable --now sanad-agent.service'),
    );
    // No download, no device authorization spent on a doomed install.
    expect(manifestRequests, 0);
    expect(definition.existsSync(), isTrue);
  });

  test('installer and Agent share one account and Home rule', () {
    final script = File('../scripts/install.sh').readAsStringSync();
    expect(
      script,
      contains(
        'SYSTEM_SANAD_HOME="\${SANAD_INSTALL_SYSTEM_HOME:-'
        '${SystemServiceAccount.dedicatedHome}}"',
      ),
    );
    // The live sudo failure: the installer keys the Home on `id -u`, so it must
    // never consult SUDO_USER, and the Agent's policy must agree.
    final code = script
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('#'))
        .join('\n');
    expect(code, isNot(contains('SUDO_USER')));
    expect(
      SystemServiceAccount.usesDedicatedAccount(
        isRoot: true,
        runAsUser: null,
      ),
      isTrue,
    );
  });

  test(
    'verified pairing install commits only after cloud health options pass',
    () async {
      final result = await _runInstaller(
        home: home,
        mockBin: mockBin,
        commandLog: commandLog,
        manifestUrl: 'http://127.0.0.1:${server.port}/manifest',
        pairingToken: 'success-one-time-token',
      );

      expect(result.exitCode, 0, reason: result.stderr.toString());
      final target = File(p.join(home.path, '.sanad/bin/sanad'));
      expect(target.existsSync(), isTrue);
      expect(File('${target.path}.rollback').existsSync(), isFalse);
      final log = commandLog.readAsStringSync();
      expect(
        log,
        contains(
          'service install --expected-version 1.2.3 --require-cloud --health-timeout 90',
        ),
      );
      expect(log, isNot(contains('success-one-time-token')));
      expect(result.stdout.toString(), contains('pairing completed'));
    },
  );

  test('selects the Linux arm64 asset on an aarch64 host', () async {
    _useLinuxHost(mockBin, architecture: 'aarch64');

    final result = await _runInstaller(
      home: home,
      mockBin: mockBin,
      commandLog: commandLog,
      manifestUrl:
          'http://127.0.0.1:${server.port}/manifest-both-architectures',
    );

    expect(result.exitCode, 0, reason: result.stderr.toString());
    // The installed binary is the arm64 asset, never the x64 one that shares
    // the same manifest.
    final target = File(p.join(home.path, '.sanad/bin/sanad'));
    expect(target.readAsStringSync(), contains('linux-arm64'));
    expect(
      commandLog.readAsStringSync(),
      contains('service install --expected-version 1.2.3'),
    );
  });

  test('names the missing architecture instead of stopping silently', () async {
    _useLinuxHost(mockBin, architecture: 'aarch64');

    // This manifest publishes Linux x64 only, so an arm64 host has no asset.
    final result = await _runInstaller(
      home: home,
      mockBin: mockBin,
      commandLog: commandLog,
      manifestUrl: 'http://127.0.0.1:${server.port}/manifest',
    );

    expect(result.exitCode, 69);
    final error = result.stderr.toString();
    expect(error, contains('linux/arm64'));
    expect(error, contains('1.2.3'));
    expect(error, contains('Published Agent targets'));
    expect(error, contains('linux/x64'));
    // Nothing was installed, paired, or serviced for an unavailable target.
    expect(File(p.join(home.path, '.sanad/bin/sanad')).existsSync(), isFalse);
    expect(commandLog.existsSync(), isFalse);
  });
  }, skip: Platform.isWindows ? 'POSIX-only install.sh test' : false);
}

Future<ProcessResult> _runInstaller({
  required Directory home,
  required Directory mockBin,
  required File commandLog,
  required String manifestUrl,
  String? pairingToken,
  String? runAsUser,
  Map<String, String> extraEnvironment = const {},
  bool explicitHome = true,
}) {
  final environment = <String, String>{
    ...Platform.environment,
    'HOME': home.path,
    'SANAD_RELEASE_MANIFEST_URL': manifestUrl,
    'SANAD_INSTALL_ALLOW_TEST_URL': '1',
    'FAKE_COMMAND_LOG': commandLog.path,
    'PATH': '${mockBin.path}:${Platform.environment['PATH']}',
    ...extraEnvironment,
  };
  // An unset Home is what makes the installer decide one, and a blank value is
  // how a child process clears a variable it would otherwise inherit.
  environment['SANAD_HOME'] = explicitHome
      ? p.join(home.path, '.sanad')
      : '';
  // A root install derives its Home from the system account record; redirect
  // that lookup into this test's temp tree unless the case chose its own path.
  environment.putIfAbsent(
    'SANAD_INSTALL_SYSTEM_HOME',
    () => p.join(home.parent.path, 'system-home'),
  );
  final installerArguments = <String>[
    if (pairingToken == null) '--no-login' else '--pairing-token-stdin',
    if (runAsUser != null) ...['--run-as-user', runAsUser],
  ];
  // The installer must never resolve a Home outside this test's temp tree: a
  // value that escapes it would install into the owner's real Sanad Home.
  HostHomeGuard.assertHomeEnvironmentRedirected(
    environment,
    allowedRoot: home.parent.path,
  );
  if (pairingToken == null) {
    return Process.run('sh', [
      '../scripts/install.sh',
      ...installerArguments,
    ], environment: environment);
  }
  // The shell builtin writes pairing authority to stdin; it is never an Agent
  // process argument or a value recorded by the fake executable.
  final quoted = pairingToken.replaceAll("'", "'\\''");
  return Process.run('sh', [
    '-c',
    "printf '%s\\n' '$quoted' | sh ../scripts/install.sh "
        '${installerArguments.join(' ')}',
  ], environment: environment);
}

File _installOldBinary(Directory home, File commandLog) {
  final target = File(p.join(home.path, '.sanad/bin/sanad'));
  target.parent.createSync(recursive: true);
  _writeExecutable(target.path, '''#!/bin/sh
# old-agent
printf '%s\\n' "\$*" >> "${commandLog.path}"
case "\${1:-} \${2:-}" in
  "service status")
    echo 'Sanad Agent Service Status:'
    echo '  Installed:  Yes'
    echo '  Running:    Yes'
    ;;
  "login --status")
    echo 'Status: Authenticated (Device Token)'
    ;;
esac
exit 0
''');
  return target;
}

void _writeExecutable(String path, String content) {
  final file = File(path)..writeAsStringSync(content);
  Process.runSync('chmod', ['700', file.path]);
}

/// The fake Linux arm64 artifact: the same executable plus a marker the test
/// can read back from the installed binary.
String _arm64Artifact(String artifact) => '$artifact\n# linux-arm64\n';

/// Reports Linux so the installer takes its Linux path under a faked account.
void _useLinuxHost(Directory mockBin, {String architecture = 'x86_64'}) {
  _writeExecutable(
    p.join(mockBin.path, 'uname'),
    '''#!/bin/sh
if [ "\${1:-}" = "-s" ]; then echo Linux; else echo $architecture; fi
''',
  );
}
