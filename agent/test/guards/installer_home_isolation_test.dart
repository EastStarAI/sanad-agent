/// The installer must never resolve a Sanad Home outside the one its caller
/// redirected.
///
/// A previous revision of this test family ran `scripts/install.sh` with
/// `SANAD_HOME` cleared so the installer decided the Home itself; when the
/// installer derived that Home from the operating-system account record instead
/// of the redirected `$HOME`, the artifact replaced the owner's real
/// `~/.sanad/bin/sanad` while the test still passed. This guard pins both halves
/// of the contract: the decided Home stays inside the test root, and the real
/// user Home is untouched.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/host_home_guard.dart';

void main() {
  group('installer Home isolation', () {
    late Directory root;
    late Directory home;
    late Directory mockBin;
    late File commandLog;
    late String artifactPath;
    late String manifestPath;
    RealSanadHomeWatch? realHomeWatch;

    const artifact = '''#!/bin/sh
printf '%s\\n' "\$*" >> "\$FAKE_COMMAND_LOG"
case "\${1:-} \${2:-}" in
  "service install")
    printf 'SANAD_HOME=%s\\n' "\${SANAD_HOME:-}" >> "\$FAKE_COMMAND_LOG"
    exit 0
    ;;
  "service status")
    echo 'Sanad Agent Service Status:'
    echo '  Installed:  No'
    echo '  Running:    No'
    exit 0
    ;;
  "login "*) exit 0 ;;
esac
exit 0
''';

    setUp(() async {
      root = await Directory.systemTemp.createTemp('sanad-install-home-');
      realHomeWatch = RealSanadHomeWatch.start();
      home = Directory(p.join(root.path, 'home'))..createSync(recursive: true);
      mockBin = Directory(p.join(root.path, 'mock-bin'))..createSync();
      commandLog = File(p.join(root.path, 'commands.log'));
      _writeExecutable(
        p.join(mockBin.path, 'uname'),
        '#!/bin/sh\n'
        'if [ "\${1:-}" = "-s" ]; then echo Darwin; else echo x86_64; fi\n',
      );
      _writeExecutable(p.join(mockBin.path, 'codesign'), '#!/bin/sh\nexit 0\n');

      final artifactFile = File(p.join(root.path, 'sanad-agent-artifact'));
      artifactFile.writeAsStringSync(artifact);
      artifactPath = artifactFile.path;
      final bytes = utf8.encode(artifact);
      final manifest = File(p.join(root.path, 'release-manifest.json'))
        ..writeAsStringSync(
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
                'url': Uri.file(artifactPath).toString(),
                'sha256': sha256.convert(bytes).toString(),
                'size': bytes.length,
              },
            ],
          }),
        );
      manifestPath = manifest.path;
    });

    tearDown(() async {
      realHomeWatch?.verifyUnchanged();
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('a cleared SANAD_HOME resolves inside the redirected HOME only',
        () async {
      final environment = <String, String>{
        ...Platform.environment,
        'HOME': home.path,
        // An unset Home is what makes the installer decide one itself.
        'SANAD_HOME': '',
        'SANAD_INSTALL_SYSTEM_HOME': p.join(root.path, 'system-home'),
        'SANAD_RELEASE_MANIFEST_URL': Uri.file(manifestPath).toString(),
        'SANAD_INSTALL_ALLOW_TEST_URL': '1',
        'FAKE_COMMAND_LOG': commandLog.path,
        'PATH': '${mockBin.path}:${Platform.environment['PATH']}',
      };
      HostHomeGuard.assertHomeEnvironmentRedirected(
        environment,
        allowedRoot: root.path,
      );

      final result = await Process.run(
        'sh',
        ['../scripts/install.sh', '--no-login'],
        environment: environment,
      );

      expect(result.exitCode, 0, reason: result.stderr.toString());
      final installed = File(p.join(home.path, '.sanad/bin/sanad'));
      expect(
        installed.existsSync(),
        isTrue,
        reason: 'the decided Home is the redirected HOME, never the real one',
      );
      expect(
        Directory(p.join(root.path, 'system-home')).existsSync(),
        isFalse,
        reason: 'no system Home is chosen for a normal user install',
      );
    });
  });
}

void _writeExecutable(String path, String content) {
  final file = File(path)..writeAsStringSync(content);
  Process.runSync('chmod', ['700', file.path]);
}
