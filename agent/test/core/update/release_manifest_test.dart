import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/update/agent_update_service.dart';
import 'package:sanad_release_contract/release_contract.dart';
import 'package:test/test.dart';

void main() {
  group('ReleaseManifest', () {
    test('resolves immutable RC artifact filenames from marketing names', () {
      expect(
        releaseArtifactFilename(
          'sanad-agent-1.0.0-windows-x64.exe',
          marketingVersion: '1.0.0',
          releaseVersion: ReleaseVersion.parse('1.0.0-rc.2'),
        ),
        'sanad-agent-1.0.0-rc.2-windows-x64.exe',
      );
    });

    test('accepts a canonical stable manifest', () {
      final manifest = ReleaseManifest.fromJson(
        _manifestJson(bytes: [1, 2, 3]),
      );

      expect(manifest.tag, 'v1.1.0');
      expect(
        manifest.findArtifact(
          component: 'agent',
          platform: 'linux',
          architecture: 'x64',
        ),
        isNotNull,
      );
    });

    test('accepts a canonical RC manifest and orders it before stable', () {
      final json = _manifestJson(bytes: [1, 2, 3]);
      json['version'] = '1.1.0-rc.2';
      json['tag'] = 'v1.1.0-rc.2';
      json['channel'] = 'rc';
      final artifacts = json['artifacts']! as List<dynamic>;
      (artifacts.single as Map<String, dynamic>)['url'] =
          'https://github.com/EastStarAI/sanad-agent/releases/download/v1.1.0-rc.2/sanad-agent-1.1.0-linux-x64';

      final manifest = ReleaseManifest.fromJson(json);

      expect(manifest.channel, ReleaseChannel.rc);
      expect(
        manifest.version.compareTo(ReleaseVersion.parse('1.1.0')),
        lessThan(0),
      );
      expect(
        ReleaseVersion.parse(
          '1.1.0-rc.2',
        ).compareTo(ReleaseVersion.parse('1.1.0-rc.1')),
        greaterThan(0),
      );
    });

    test('rejects RC version on the stable channel', () {
      final json = _manifestJson(bytes: [1, 2, 3]);
      json['version'] = '1.1.0-rc.1';
      json['tag'] = 'v1.1.0-rc.1';
      final artifacts = json['artifacts']! as List<dynamic>;
      (artifacts.single as Map<String, dynamic>)['url'] =
          'https://github.com/EastStarAI/sanad-agent/releases/download/v1.1.0-rc.1/sanad-agent-1.1.0-linux-x64';

      expect(
        () => ReleaseManifest.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a tag that differs from the marketing version', () {
      final json = _manifestJson(bytes: [1, 2, 3]);
      json['tag'] = 'v2.0.0';

      expect(
        () => ReleaseManifest.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a non-canonical artifact URL', () {
      final json = _manifestJson(bytes: [1, 2, 3]);
      final artifacts = json['artifacts']! as List<dynamic>;
      (artifacts.single as Map<String, dynamic>)['url'] =
          'https://example.com/sanad-agent-1.1.0-linux-x64';

      expect(
        () => ReleaseManifest.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects empty and unknown signature metadata', () {
      for (final signature in ['', 'authenticode']) {
        final json = _manifestJson(bytes: [1, 2, 3]);
        final artifact =
            (json['artifacts']! as List).single as Map<String, dynamic>;
        artifact['signature_type'] = signature;
        expect(
          () => ReleaseManifest.fromJson(json),
          throwsA(isA<FormatException>()),
        );
      }
    });

    test('accepts only the declared unsigned Windows agent policy', () async {
      final json = _manifestJson(bytes: [1, 2, 3]);
      final artifactJson =
          (json['artifacts']! as List).single as Map<String, dynamic>;
      artifactJson
        ..['platform'] = 'windows'
        ..['filename'] = 'sanad-agent-1.1.0-windows-x64.exe'
        ..['url'] =
            'https://github.com/EastStarAI/sanad-agent/releases/download/v1.1.0/sanad-agent-1.1.0-windows-x64.exe'
        ..['signature_type'] = 'unsigned+github-attestation';
      final artifact = ReleaseManifest.fromJson(json).artifacts.single;
      final file = File('${Directory.systemTemp.path}/sanad-trust-test.exe');
      addTearDown(() async {
        if (file.existsSync()) await file.delete();
      });
      await file.writeAsBytes([1, 2, 3]);

      expect(
        await verifyReleaseArtifactTrust(file, artifact: artifact),
        isTrue,
      );

      artifactJson['signature_type'] = 'authenticode';
      expect(
        () => ReleaseManifest.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('generates deterministic platform-specific Appcast entries', () {
      final json = _manifestJson(bytes: [1, 2, 3]);
      json['artifacts'] = [
        _clientArtifact(
          platform: 'macos',
          architecture: 'universal',
          extension: 'dmg',
          signatureType: 'developer-id+notarization+sparkle-ed25519',
          updateSignature: 'mac-signature',
        ),
        _clientArtifact(
          platform: 'windows',
          architecture: 'x64',
          extension: 'exe',
          signatureType: 'unsigned+winsparkle-dsa',
          updateSignature: 'windows-signature',
        ),
      ];
      final xml = generateAppcastXml(
        ReleaseManifest.fromJson(json),
        DateTime.utc(2026, 7, 27),
      );

      expect('<item>'.allMatches(xml), hasLength(2));
      expect('<enclosure '.allMatches(xml), hasLength(2));
      expect(xml, contains('sparkle:edSignature="mac-signature"'));
      expect(xml, contains('sparkle:dsaSignature="windows-signature"'));
    });
  });

  group('AgentUpdateService', () {
    late Directory temporaryDirectory;

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'sanad-update-test-',
      );
    });

    tearDown(() async {
      if (temporaryDirectory.existsSync()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });

    test(
      'source-managed mode reports status without changing the checkout',
      () async {
        final executable = File('${temporaryDirectory.path}/sanad')
          ..writeAsStringSync('old');
        final manifest = jsonEncode(_manifestJson(bytes: [1, 2, 3]));
        final service = AgentUpdateService(
          currentVersion: '1.0.0',
          executablePath: executable.path,
          isSourceManaged: true,
          operatingSystem: 'linux',
          architecture: 'x64',
          client: MockClient((_) async => http.Response(manifest, 200)),
        );

        final result = await service.update();

        expect(result.status, AgentUpdateStatus.sourceManaged);
        expect(executable.readAsStringSync(), 'old');
      },
    );

    test('installs an exact verified target', () async {
      final executable = File('${temporaryDirectory.path}/sanad')
        ..writeAsStringSync('old');
      final bytes = utf8.encode('new-agent');
      final artifactFile = File('${temporaryDirectory.path}/artifact')
        ..writeAsBytesSync(bytes);
      final manifestJson = _manifestJson(bytes: bytes);
      final artifact =
          (manifestJson['artifacts']! as List).single as Map<String, dynamic>;
      artifact
        ..['size'] = bytes.length
        ..['sha256'] = await sha256OfFile(artifactFile);
      Uri? requestedArtifact;
      final service = AgentUpdateService(
        currentVersion: '1.0.0',
        executablePath: executable.path,
        isSourceManaged: false,
        operatingSystem: 'linux',
        architecture: 'x64',
        artifactMirrorUri: Uri.parse('http://127.0.0.1/artifacts/'),
        client: MockClient((request) async {
          if (request.url.path.endsWith('release-manifest.json')) {
            return http.Response(jsonEncode(manifestJson), 200);
          }
          requestedArtifact = request.url;
          return http.Response.bytes(bytes, 200);
        }),
      );

      final result = await service.update(targetVersion: '1.1.0');

      expect(result.status, AgentUpdateStatus.restartRequired);
      expect(executable.readAsBytesSync(), bytes);
      expect(
        requestedArtifact?.toString(),
        'http://127.0.0.1/artifacts/sanad-agent-1.1.0-linux-x64',
      );
    });

    test('rejects latest when it differs from the exact target', () async {
      final executable = File('${temporaryDirectory.path}/sanad')
        ..writeAsStringSync('old');
      var artifactRequested = false;
      final service = AgentUpdateService(
        currentVersion: '1.0.0',
        executablePath: executable.path,
        isSourceManaged: false,
        operatingSystem: 'linux',
        architecture: 'x64',
        client: MockClient((request) async {
          if (!request.url.path.endsWith('release-manifest.json')) {
            artifactRequested = true;
          }
          return http.Response(
            jsonEncode(_manifestJson(bytes: [1, 2, 3])),
            200,
          );
        }),
      );

      final result = await service.update(targetVersion: '1.2.0');

      expect(result.status, AgentUpdateStatus.targetMismatch);
      expect(artifactRequested, isFalse);
      expect(executable.readAsStringSync(), 'old');
    });

    test('rejects automatic downgrade without fetching a manifest', () async {
      var requestCount = 0;
      final service = AgentUpdateService(
        currentVersion: '1.2.0',
        executablePath: '${temporaryDirectory.path}/sanad',
        isSourceManaged: false,
        operatingSystem: 'linux',
        architecture: 'x64',
        client: MockClient((_) async {
          requestCount++;
          return http.Response('', 500);
        }),
      );

      final result = await service.update(targetVersion: '1.1.0');

      expect(result.status, AgentUpdateStatus.downgradeRejected);
      expect(requestCount, 0);
    });

    test('coalesces concurrent update requests for one executable', () async {
      final executable = File('${temporaryDirectory.path}/sanad')
        ..writeAsStringSync('old');
      var requestCount = 0;
      final service = AgentUpdateService(
        currentVersion: '1.0.0',
        executablePath: executable.path,
        isSourceManaged: false,
        operatingSystem: 'linux',
        architecture: 'x64',
        client: MockClient((request) async {
          requestCount++;
          if (request.url.path.endsWith('release-manifest.json')) {
            return http.Response(
              jsonEncode(_manifestJson(bytes: [1, 2, 3])),
              200,
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return http.Response.bytes([9, 9, 9], 200);
        }),
      );

      final results = await Future.wait([
        service.update(targetVersion: '1.1.0'),
        service.update(targetVersion: '1.1.0'),
      ]);

      expect(
        results.map((result) => result.status),
        everyElement(AgentUpdateStatus.checksumFailed),
      );
      expect(requestCount, 2);
      expect(executable.readAsStringSync(), 'old');
    });

    test(
      'classifies an unavailable manifest endpoint as a network failure',
      () async {
        final executable = File('${temporaryDirectory.path}/sanad')
          ..writeAsStringSync('old');
        final service = AgentUpdateService(
          currentVersion: '1.0.0',
          executablePath: executable.path,
          isSourceManaged: false,
          operatingSystem: 'windows',
          architecture: 'x64',
          client: MockClient((request) async {
            throw http.ClientException('Connection refused.', request.url);
          }),
        );

        final result = await service.update(targetVersion: '1.1.0');

        expect(result.status, AgentUpdateStatus.networkFailed);
        expect(executable.readAsStringSync(), 'old');
      },
    );

    test('rejects an artifact whose checksum differs', () async {
      final executable = File('${temporaryDirectory.path}/sanad')
        ..writeAsStringSync('old');
      final expectedBytes = [1, 2, 3];
      final manifest = jsonEncode(_manifestJson(bytes: expectedBytes));
      final service = AgentUpdateService(
        currentVersion: '1.0.0',
        executablePath: executable.path,
        isSourceManaged: false,
        operatingSystem: 'linux',
        architecture: 'x64',
        client: MockClient((request) async {
          if (request.url.path.endsWith('release-manifest.json')) {
            return http.Response(manifest, 200);
          }
          return http.Response.bytes([9, 9, 9], 200);
        }),
      );

      final result = await service.update();

      expect(result.status, AgentUpdateStatus.checksumFailed);
      expect(executable.readAsStringSync(), 'old');
    });

    test(
      'reports Windows scheduling failure without replacing the running file',
      () async {
        final executable = File('${temporaryDirectory.path}/sanad.exe')
          ..writeAsStringSync('running');
        final staged = File('${temporaryDirectory.path}/sanad.staged')
          ..writeAsStringSync('candidate');
        final service = AgentUpdateService(
          currentVersion: '1.0.0',
          executablePath: executable.path,
          isSourceManaged: false,
          operatingSystem: 'windows',
          architecture: 'x64',
          replacementScheduler: (_) async => false,
        );
        final result = AgentUpdateResult(
          status: AgentUpdateStatus.restartRequired,
          currentVersion: '1.0.0',
          availableVersion: '1.1.0',
          stagedPath: staged.path,
        );

        expect(await service.scheduleWindowsReplacement(result), isFalse);
        expect(executable.readAsStringSync(), 'running');
        expect(staged.existsSync(), isFalse);
      },
    );

    test(
      'schedules a Windows replacement and accepts the staged script',
      () async {
        final executable = File('${temporaryDirectory.path}/sanad.exe')
          ..writeAsStringSync('running');
        final staged = File('${temporaryDirectory.path}/sanad.staged')
          ..writeAsStringSync('candidate');
        var receivedScript = '';
        final service = AgentUpdateService(
          currentVersion: '1.0.0',
          executablePath: executable.path,
          isSourceManaged: false,
          operatingSystem: 'windows',
          architecture: 'x64',
          replacementScheduler: (script) async {
            receivedScript = script;
            return true;
          },
        );
        final result = AgentUpdateResult(
          status: AgentUpdateStatus.restartRequired,
          currentVersion: '1.0.0',
          availableVersion: '1.1.0',
          stagedPath: staged.path,
        );

        expect(await service.scheduleWindowsReplacement(result), isTrue);
        expect(receivedScript, contains("\$target = '${executable.path}'"));
        expect(receivedScript, contains("\$staged = '${staged.path}'"));
        expect(
          receivedScript,
          contains(r'Move-Item -LiteralPath $staged -Destination $target'),
        );
        expect(receivedScript, contains(r'& $target service start'));
        expect(staged.existsSync(), isTrue);
      },
    );

    test(
      'runs the native detached PowerShell replacement handshake on Windows',
      () async {
        final target = File('${temporaryDirectory.path}/sanad-test.cmd')
          ..writeAsStringSync('@exit /b 0\r\n');
        final staged = File('${target.path}.1.1.0.staged')
          ..writeAsStringSync('@exit /b 0\r\n');
        final service = AgentUpdateService(
          currentVersion: '1.0.0',
          executablePath: target.path,
          isSourceManaged: false,
          operatingSystem: 'windows',
          architecture: 'x64',
        );
        final result = AgentUpdateResult(
          status: AgentUpdateStatus.restartRequired,
          currentVersion: '1.0.0',
          availableVersion: '1.1.0',
          stagedPath: staged.path,
        );

        expect(await service.scheduleWindowsReplacement(result), isTrue);
        final resultFile = File('${target.path}.update-result.json');
        for (
          var attempt = 0;
          attempt < 40 && !resultFile.existsSync();
          attempt++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(resultFile.existsSync(), isTrue);
        expect(jsonDecode(resultFile.readAsStringSync())['status'], 'started');
        expect(File('${staged.path}.replace.ps1').existsSync(), isFalse);
      },
      skip: Platform.isWindows ? false : 'Windows native PowerShell gate.',
    );

    test(
      'does not schedule a Windows replacement on a non-Windows service',
      () async {
        final service = AgentUpdateService(
          currentVersion: '1.0.0',
          executablePath: '/tmp/sanad',
          isSourceManaged: false,
          operatingSystem: 'macos',
          architecture: 'arm64',
          replacementScheduler: (_) async => true,
        );
        final result = AgentUpdateResult(
          status: AgentUpdateStatus.restartRequired,
          currentVersion: '1.0.0',
          availableVersion: '1.1.0',
          stagedPath: '/tmp/sanad.staged',
        );

        expect(await service.scheduleWindowsReplacement(result), isFalse);
      },
    );

    test(
      'buildWindowsReplacementScript restores and starts the backup path',
      () {
        final script = AgentUpdateService.buildWindowsReplacementScript(
          target: "C:\\path\\sanad.exe",
          staged: "C:\\path\\sanad.1.1.0.staged",
        );
        expect(script, contains(r'$backup = "$target.rollback"'));
        expect(script, contains(r'Set-Content -LiteralPath $readyMarker'));
        expect(script, contains("Write-UpdateResult 'started'"));
        expect(script, contains("Write-UpdateResult 'rollback_completed'"));
        expect(script, contains(r'Remove-Item -LiteralPath $staged -Force'));
        expect(script, contains(r'& $target service start'));
        expect(r'& $target service start'.allMatches(script).length, 2);
        expect(script, contains(r'Remove-Item -LiteralPath $staged -Force'));
      },
    );
  });
}

Map<String, dynamic> _manifestJson({required List<int> bytes}) => {
  'schema_version': 1,
  'version': '1.1.0',
  'build_number': 2,
  'tag': 'v1.1.0',
  'commit': '1234567890abcdef',
  'channel': 'stable',
  'repository': 'EastStarAI/sanad-agent',
  'artifacts': [
    {
      'component': 'agent',
      'platform': 'linux',
      'architecture': 'x64',
      'format': 'executable',
      'filename': 'sanad-agent-1.1.0-linux-x64',
      'url':
          'https://github.com/EastStarAI/sanad-agent/releases/download/v1.1.0/sanad-agent-1.1.0-linux-x64',
      'sha256': _sha256ForTest(bytes),
      'size': bytes.length,
      'public': true,
      'signature_type': 'github-attestation',
    },
  ],
};

String _sha256ForTest(List<int> bytes) {
  const values = '0123456789abcdef';
  var seed = bytes.fold<int>(0, (value, byte) => (value + byte) & 0xff);
  final output = StringBuffer();
  for (var index = 0; index < 64; index++) {
    output.write(values[(seed + index) & 0xf]);
    seed = (seed * 33 + index) & 0xff;
  }
  return output.toString();
}

Map<String, dynamic> _clientArtifact({
  required String platform,
  required String architecture,
  required String extension,
  required String signatureType,
  required String updateSignature,
}) => {
  'component': 'client',
  'platform': platform,
  'architecture': architecture,
  'format': extension,
  'filename': 'sanad-client-1.1.0-$platform-$architecture.$extension',
  'url':
      'https://github.com/EastStarAI/sanad-agent/releases/download/v1.1.0/sanad-client-1.1.0-$platform-$architecture.$extension',
  'sha256': List.filled(64, 'a').join(),
  'size': 42,
  'public': true,
  'signature_type': signatureType,
  'update_signature': updateSignature,
};
