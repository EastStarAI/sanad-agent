import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory home;
  late Directory mockBin;
  late File commandLog;
  late HttpServer server;
  late String artifact;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sanad-installer-test-');
    home = Directory(p.join(root.path, 'home'))..createSync(recursive: true);
    mockBin = Directory(p.join(root.path, 'mock-bin'))..createSync();
    commandLog = File(p.join(root.path, 'commands.log'));
    _writeExecutable(p.join(mockBin.path, 'uname'), '''#!/bin/sh
if [ "\${1:-}" = "-s" ]; then echo Darwin; else echo x86_64; fi
''');
    _writeExecutable(p.join(mockBin.path, 'codesign'), '#!/bin/sh\nexit 0\n');
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
  "service install") [ "\${FAKE_SERVICE_FAIL:-0}" = "1" ] && exit 13 || exit 0 ;;
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
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/missing') {
        request.response.statusCode = HttpStatus.notFound;
      } else if (request.uri.path == '/artifact') {
        request.response.write(artifact);
      } else if (request.uri.path == '/manifest' ||
          request.uri.path == '/manifest-missing-artifact') {
        final bytes = utf8.encode(artifact);
        final artifactPath = request.uri.path == '/manifest'
            ? '/artifact'
            : '/missing';
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
            ],
          }),
        );
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
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
    },
  );

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
}

Future<ProcessResult> _runInstaller({
  required Directory home,
  required Directory mockBin,
  required File commandLog,
  required String manifestUrl,
  String? pairingToken,
  Map<String, String> extraEnvironment = const {},
}) {
  final environment = {
    ...Platform.environment,
    'HOME': home.path,
    'SANAD_HOME': p.join(home.path, '.sanad'),
    'SANAD_RELEASE_MANIFEST_URL': manifestUrl,
    'SANAD_INSTALL_ALLOW_TEST_URL': '1',
    'FAKE_COMMAND_LOG': commandLog.path,
    'PATH': '${mockBin.path}:${Platform.environment['PATH']}',
    ...extraEnvironment,
  };
  if (pairingToken == null) {
    return Process.run('sh', [
      '../scripts/install.sh',
      '--no-login',
    ], environment: environment);
  }
  // The shell builtin writes pairing authority to stdin; it is never an Agent
  // process argument or a value recorded by the fake executable.
  final quoted = pairingToken.replaceAll("'", "'\\''");
  return Process.run('sh', [
    '-c',
    "printf '%s\\n' '$quoted' | sh ../scripts/install.sh --pairing-token-stdin",
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
