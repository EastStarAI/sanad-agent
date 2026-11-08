import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_client/features/devices/data/daemon/verified_agent_bootstrap_installer.dart';
import 'package:sanad_client/infrastructure/platform/auto_update_service.dart';
import 'package:sanad_release_contract/release_contract.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeNativeUpdater implements NativeUpdateAdapter {
  int feedCount = 0;
  int intervalCount = 0;
  int checkCount = 0;
  void Function()? quitForUpdate;

  @override
  Future<void> checkForUpdates() async => checkCount++;
  @override
  Future<void> setFeedUrl(String url) async => feedCount++;
  @override
  Future<void> setScheduledCheckInterval(int seconds) async => intervalCount++;
  @override
  void setQuitForUpdateHandler(void Function()? callback) {
    quitForUpdate = callback;
  }
}

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'sanad-bootstrap-test-',
    );
  });

  tearDown(() async {
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('reports bounded download progress that ends at completion', () async {
    final bytes = utf8.encode('verified-agent');
    final manifest = _manifest(
      size: bytes.length,
      digest: _sha256OfBytes(bytes),
    );
    final progress = <double>[];
    final installer = VerifiedAgentBootstrapInstaller(
      targetPath: '${temporaryDirectory.path}/bin/sanad',
      operatingSystem: 'linux',
      architecture: 'x64',
      client: MockClient(
        (request) async => request.url.path.endsWith('release-manifest.json')
            ? http.Response(jsonEncode(manifest), 200)
            : http.Response.bytes(bytes, 200),
      ),
    );

    await installer.install(targetVersion: '1.1.0', onProgress: progress.add);

    expect(progress, isNotEmpty);
    expect(progress.every((value) => value >= 0 && value <= 1), isTrue);
    expect(progress.last, 1.0);
  });

  group('packaged native runtime', () {
    // A Client-only install must carry dictation: the runtime is a second
    // artifact of the same manifest, verified by the same size/sha/trust rules,
    // and installed only after the executable itself is in place.
    Future<File> runtimeArchive(
      String tag,
      Map<String, String> members,
    ) async {
      final staging = Directory('${temporaryDirectory.path}/runtime-staging');
      final root = Directory('${staging.path}/native/$tag')
        ..createSync(recursive: true);
      members.forEach((name, contents) {
        final file = File('${root.path}/$name');
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(contents);
      });
      final archive = File('${temporaryDirectory.path}/runtime.tar.gz');
      final tar = await Process.run('tar', [
        '-czf',
        archive.path,
        '-C',
        staging.path,
        'native/$tag',
      ]);
      expect(tar.exitCode, 0, reason: '${tar.stderr}');
      return archive;
    }

    Map<String, dynamic> manifestWithRuntime({
      required List<int> agentBytes,
      required String agentDigest,
      required File runtime,
      required List<int> runtimeBytes,
      String tag = 'linux-x64',
      String? runtimeDigest,
    }) {
      final manifest = _manifest(
        size: agentBytes.length,
        digest: agentDigest,
      );
      return {
        ...manifest,
        'artifacts': [
          for (final artifact in manifest['artifacts'] as List) artifact,
          {
            'component': 'agent-runtime',
            'platform': 'linux',
            'architecture': 'x64',
            'format': 'tar.gz',
            'filename': 'sanad-agent-runtime-1.1.0-$tag.tar.gz',
            'url':
                'https://github.com/EastStarAI/sanad-agent/releases/download/v1.1.0/sanad-agent-runtime-1.1.0-$tag.tar.gz',
            'sha256': runtimeDigest ?? _sha256OfBytes(runtimeBytes),
            'size': runtimeBytes.length,
            'public': true,
            'signature_type': 'github-attestation',
          },
        ],
      };
    }

    VerifiedAgentBootstrapInstaller installerFor({
      required List<int> agentBytes,
      required Map<String, dynamic> manifest,
      required List<int> runtimeBytes,
      int runtimeStatus = 200,
    }) =>
        VerifiedAgentBootstrapInstaller(
          targetPath: '${temporaryDirectory.path}/bin/sanad',
          operatingSystem: 'linux',
          architecture: 'x64',
          client: MockClient((request) async {
            if (request.url.path.endsWith('release-manifest.json')) {
              return http.Response(jsonEncode(manifest), 200);
            }
            if (request.url.path.endsWith('.tar.gz')) {
              return http.Response.bytes(runtimeBytes, runtimeStatus);
            }
            return http.Response.bytes(agentBytes, 200);
          }),
        );

    test('the runtime is installed beside the verified executable', () async {
      final agentBytes = utf8.encode('verified-agent');
      final runtime = await runtimeArchive('linux-x64', {
        'libsanad_whisper.so': 'shim',
        'libggml.so.1': 'ggml',
      });
      final runtimeBytes = runtime.readAsBytesSync();
      final installer = installerFor(
        agentBytes: agentBytes,
        manifest: manifestWithRuntime(
          agentBytes: agentBytes,
          agentDigest: _sha256OfBytes(agentBytes),
          runtime: runtime,
          runtimeBytes: runtimeBytes,
        ),
        runtimeBytes: runtimeBytes,
      );

      final result = await installer.install(targetVersion: '1.1.0');

      expect(result.status, AgentBootstrapStatus.installed);
      expect(result.runtimeStatus, AgentRuntimeBundleStatus.installed);
      expect(result.isSuccess, isTrue);
      final installed = File(
        '${temporaryDirectory.path}/bin/native/linux-x64/libsanad_whisper.so',
      );
      expect(installed.readAsStringSync(), 'shim');
      expect(
        Directory('${temporaryDirectory.path}/bin/native/linux-x64.rollback')
            .existsSync(),
        isFalse,
      );
    });

    test('a manifest without a runtime keeps the previous install valid',
        () async {
      final agentBytes = utf8.encode('verified-agent');
      final installer = installerFor(
        agentBytes: agentBytes,
        manifest: _manifest(
          size: agentBytes.length,
          digest: _sha256OfBytes(agentBytes),
        ),
        runtimeBytes: const [],
      );

      final result = await installer.install(targetVersion: '1.1.0');

      expect(result.runtimeStatus, AgentRuntimeBundleStatus.notPublished);
      expect(result.isSuccess, isTrue);
      expect(
        Directory('${temporaryDirectory.path}/bin/native').existsSync(),
        isFalse,
      );
    });

    test('a runtime checksum mismatch fails the whole install', () async {
      final agentBytes = utf8.encode('verified-agent');
      final runtime = await runtimeArchive('linux-x64', {
        'libsanad_whisper.so': 'shim',
      });
      final runtimeBytes = runtime.readAsBytesSync();
      final installer = installerFor(
        agentBytes: agentBytes,
        manifest: manifestWithRuntime(
          agentBytes: agentBytes,
          agentDigest: _sha256OfBytes(agentBytes),
          runtime: runtime,
          runtimeBytes: runtimeBytes,
          runtimeDigest: 'c' * 64,
        ),
        runtimeBytes: runtimeBytes,
      );

      final result = await installer.install(targetVersion: '1.1.0');

      expect(result.runtimeStatus, AgentRuntimeBundleStatus.checksumFailed);
      expect(
        result.isSuccess,
        isFalse,
        reason: 'a published-but-uninstallable runtime is a failed install',
      );
      expect(
        Directory('${temporaryDirectory.path}/bin/native/linux-x64')
            .existsSync(),
        isFalse,
      );
    });

    test('an unexpected runtime member is refused before extraction',
        () async {
      final agentBytes = utf8.encode('verified-agent');
      final runtime = await runtimeArchive('linux-x64', {
        'libsanad_whisper.so': 'shim',
        'models/ggml-base.bin': 'model payload',
      });
      final runtimeBytes = runtime.readAsBytesSync();
      final installer = installerFor(
        agentBytes: agentBytes,
        manifest: manifestWithRuntime(
          agentBytes: agentBytes,
          agentDigest: _sha256OfBytes(agentBytes),
          runtime: runtime,
          runtimeBytes: runtimeBytes,
        ),
        runtimeBytes: runtimeBytes,
      );

      final result = await installer.install(targetVersion: '1.1.0');

      expect(result.runtimeStatus, AgentRuntimeBundleStatus.layoutRejected);
      expect(result.isSuccess, isFalse);
      expect(
        Directory('${temporaryDirectory.path}/bin/native/linux-x64')
            .existsSync(),
        isFalse,
      );
    });

    test('a runtime download failure fails the whole install', () async {
      final agentBytes = utf8.encode('verified-agent');
      final runtime = await runtimeArchive('linux-x64', {
        'libsanad_whisper.so': 'shim',
      });
      final runtimeBytes = runtime.readAsBytesSync();
      final installer = installerFor(
        agentBytes: agentBytes,
        manifest: manifestWithRuntime(
          agentBytes: agentBytes,
          agentDigest: _sha256OfBytes(agentBytes),
          runtime: runtime,
          runtimeBytes: runtimeBytes,
        ),
        runtimeBytes: runtimeBytes,
        runtimeStatus: 503,
      );

      final result = await installer.install(targetVersion: '1.1.0');

      expect(result.runtimeStatus, AgentRuntimeBundleStatus.downloadFailed);
      expect(result.isSuccess, isFalse);
    });
  });

  test('installs exactly the verified manifest artifact', () async {
    final bytes = utf8.encode('verified-agent');
    final artifactFile = File('${temporaryDirectory.path}/artifact')..writeAsBytesSync(bytes);
    final manifest = _manifest(
      size: bytes.length,
      digest: await sha256OfFile(artifactFile),
    );
    final target = '${temporaryDirectory.path}/bin/sanad';
    final installer = VerifiedAgentBootstrapInstaller(
      targetPath: target,
      operatingSystem: 'linux',
      architecture: 'x64',
      client: MockClient((request) async {
        if (request.url.path.endsWith('release-manifest.json')) {
          return http.Response(jsonEncode(manifest), 200);
        }
        return http.Response.bytes(bytes, 200);
      }),
    );

    expect((await installer.install(targetVersion: '1.1.0')).isSuccess, isTrue);
    expect(File(target).readAsBytesSync(), bytes);
  });

  test('isolated artifact mirror keeps canonical manifest trust metadata', () async {
    final bytes = utf8.encode('mirrored-agent');
    final artifactFile = File('${temporaryDirectory.path}/artifact')..writeAsBytesSync(bytes);
    final manifest = _manifest(
      size: bytes.length,
      digest: await sha256OfFile(artifactFile),
    );
    Uri? requestedArtifact;
    final installer = VerifiedAgentBootstrapInstaller(
      targetPath: '${temporaryDirectory.path}/bin/sanad',
      manifestUri: Uri.parse('http://127.0.0.1/release-manifest.json'),
      artifactMirrorUri: Uri.parse('http://127.0.0.1/artifacts/'),
      operatingSystem: 'linux',
      architecture: 'x64',
      client: MockClient((request) async {
        if (request.url.path.endsWith('release-manifest.json')) {
          return http.Response(jsonEncode(manifest), 200);
        }
        requestedArtifact = request.url;
        return http.Response.bytes(bytes, 200);
      }),
    );

    expect((await installer.install(targetVersion: '1.1.0')).isSuccess, isTrue);
    expect(
      requestedArtifact?.toString(),
      'http://127.0.0.1/artifacts/sanad-agent-1.1.0-linux-x64',
    );
  });

  test('rejects a manifest version mismatch before downloading', () async {
    var artifactRequested = false;
    final manifest = _manifest(size: 3, digest: List.filled(64, '0').join());
    final installer = VerifiedAgentBootstrapInstaller(
      targetPath: '${temporaryDirectory.path}/sanad',
      operatingSystem: 'linux',
      architecture: 'x64',
      client: MockClient((request) async {
        if (!request.url.path.endsWith('release-manifest.json')) {
          artifactRequested = true;
        }
        return http.Response(jsonEncode(manifest), 200);
      }),
    );

    final result = await installer.install(targetVersion: '1.2.0');

    expect(result.status, AgentBootstrapStatus.targetMismatch);
    expect(artifactRequested, isFalse);
  });

  test('Windows unsigned agent passes metadata, size, and checksum policy', () async {
    final bytes = utf8.encode('unsigned-windows-agent');
    final artifactFile = File('${temporaryDirectory.path}/candidate.exe')..writeAsBytesSync(bytes);
    final manifest = _manifest(
      size: bytes.length,
      digest: await sha256OfFile(artifactFile),
    );
    final artifact = (manifest['artifacts']! as List).single as Map<String, dynamic>;
    artifact
      ..['platform'] = 'windows'
      ..['filename'] = 'sanad-agent-1.1.0-windows-x64.exe'
      ..['url'] = 'https://github.com/EastStarAI/sanad-agent/releases/download/v1.1.0/sanad-agent-1.1.0-windows-x64.exe'
      ..['signature_type'] = 'unsigned+github-attestation';
    final target = '${temporaryDirectory.path}/sanad.exe';
    final installer = VerifiedAgentBootstrapInstaller(
      targetPath: target,
      operatingSystem: 'windows',
      architecture: 'x64',
      client: MockClient((request) async {
        if (request.url.path.endsWith('release-manifest.json')) {
          return http.Response(jsonEncode(manifest), 200);
        }
        return http.Response.bytes(bytes, 200);
      }),
    );

    final result = await installer.install(targetVersion: '1.1.0');

    expect(result.status, AgentBootstrapStatus.installed);
    expect(File(target).readAsBytesSync(), bytes);
  });

  test('macOS keeps the existing agent when publisher trust fails', () async {
    final bytes = utf8.encode('candidate');
    final artifactFile = File('${temporaryDirectory.path}/candidate')..writeAsBytesSync(bytes);
    final manifest = _manifest(
      size: bytes.length,
      digest: await sha256OfFile(artifactFile),
    );
    final artifact = (manifest['artifacts']! as List).single as Map<String, dynamic>;
    artifact
      ..['platform'] = 'macos'
      ..['architecture'] = 'arm64'
      ..['filename'] = 'sanad-agent-1.1.0-macos-arm64'
      ..['url'] = 'https://github.com/EastStarAI/sanad-agent/releases/download/v1.1.0/sanad-agent-1.1.0-macos-arm64'
      ..['signature_type'] = 'developer-id+notarization+github-attestation';
    final target = File('${temporaryDirectory.path}/sanad')..writeAsStringSync('existing');
    final installer = VerifiedAgentBootstrapInstaller(
      targetPath: target.path,
      operatingSystem: 'macos',
      architecture: 'arm64',
      platformVerifier: (_, _) async => false,
      client: MockClient((request) async {
        if (request.url.path.endsWith('release-manifest.json')) {
          return http.Response(jsonEncode(manifest), 200);
        }
        return http.Response.bytes(bytes, 200);
      }),
    );

    final result = await installer.install(targetVersion: '1.1.0');

    expect(result.status, AgentBootstrapStatus.trustFailed);
    expect(result.message, contains('stage=platform_verifier'));
    expect(target.readAsStringSync(), 'existing');
  });

  test('macOS reports the typed stage and sanitized detail of a detailed trust failure', () async {
    final bytes = utf8.encode('candidate');
    final artifactFile = File('${temporaryDirectory.path}/candidate')..writeAsBytesSync(bytes);
    final manifest = _manifest(
      size: bytes.length,
      digest: await sha256OfFile(artifactFile),
    );
    final artifact = (manifest['artifacts']! as List).single as Map<String, dynamic>;
    artifact
      ..['platform'] = 'macos'
      ..['architecture'] = 'arm64'
      ..['filename'] = 'sanad-agent-1.1.0-macos-arm64'
      ..['url'] = 'https://github.com/EastStarAI/sanad-agent/releases/download/v1.1.0/sanad-agent-1.1.0-macos-arm64'
      ..['signature_type'] = 'developer-id+notarization+github-attestation';
    final target = File('${temporaryDirectory.path}/sanad')..writeAsStringSync('existing');
    final installer = VerifiedAgentBootstrapInstaller(
      targetPath: target.path,
      operatingSystem: 'macos',
      architecture: 'arm64',
      detailedPlatformVerifier: (file, _) async => PlatformTrustResult.untrusted(
        stage: PlatformTrustStage.publisherRequirement,
        exitCode: 3,
        detail: sanitizePlatformVerifierOutput('${file.path}: untrusted publisher', filePath: file.path),
      ),
      client: MockClient((request) async {
        if (request.url.path.endsWith('release-manifest.json')) {
          return http.Response(jsonEncode(manifest), 200);
        }
        return http.Response.bytes(bytes, 200);
      }),
    );

    final result = await installer.install(targetVersion: '1.1.0');

    expect(result.status, AgentBootstrapStatus.trustFailed);
    expect(result.message, contains('stage=publisher_requirement: exit=3: <artifact>: untrusted publisher'));
    expect(result.message, isNot(contains(temporaryDirectory.path)));
    expect(target.readAsStringSync(), 'existing');
    expect(File('${target.path}.bootstrap-staged').existsSync(), isFalse);
  });

  test('keeps the existing executable when verification fails', () async {
    final target = File('${temporaryDirectory.path}/sanad')..writeAsStringSync('existing');
    final manifest = _manifest(size: 3, digest: List.filled(64, '0').join());
    final installer = VerifiedAgentBootstrapInstaller(
      targetPath: target.path,
      operatingSystem: 'linux',
      architecture: 'x64',
      client: MockClient((request) async {
        if (request.url.path.endsWith('release-manifest.json')) {
          return http.Response(jsonEncode(manifest), 200);
        }
        return http.Response.bytes([1, 2, 3], 200);
      }),
    );

    expect(
      (await installer.install(targetVersion: '1.1.0')).status,
      AgentBootstrapStatus.checksumFailed,
    );
    expect(target.readAsStringSync(), 'existing');
  });

  test('packaged macOS startup schedules without an interactive check', () async {
    final native = _FakeNativeUpdater();
    final service = AutoUpdateService.test(
      native: native,
      client: MockClient((_) async => http.Response('', 500)),
      platform: 'macos',
      sourceRun: false,
      currentVersion: () async => '1.0.0',
      launch: (_) async => true,
    );

    await service.initialize();
    await service.initialize();

    expect(native.feedCount, 1);
    expect(native.intervalCount, 1);
    expect(native.checkCount, 0);
  });

  test('packaged desktop manual check uses the interactive native API', () async {
    for (final platform in ['macos', 'windows']) {
      final native = _FakeNativeUpdater();
      final service = AutoUpdateService.test(
        native: native,
        client: MockClient((_) async => http.Response('', 500)),
        platform: platform,
        sourceRun: false,
        currentVersion: () async => '1.0.0',
        launch: (_) async => true,
      );

      await service.initialize();
      final result = await service.checkForUpdates();

      expect(result.status, ClientUpdateStatus.checkStarted);
      expect(native.checkCount, 1, reason: platform);
      service.dispose();
    }
  });

  test('packaged Windows updater flushes once before native installation quit', () async {
    final native = _FakeNativeUpdater();
    var flushCount = 0;
    final exitCodes = <int>[];
    final service = AutoUpdateService.test(
      native: native,
      client: MockClient((_) async => http.Response('', 500)),
      platform: 'windows',
      sourceRun: false,
      currentVersion: () async => '1.0.0',
      launch: (_) async => true,
      beforeQuitForUpdate: () async => flushCount++,
      quit: exitCodes.add,
    );

    await service.initialize();
    expect(native.quitForUpdate, isNotNull);
    native.quitForUpdate!();
    native.quitForUpdate?.call();
    await Future<void>.delayed(Duration.zero);

    expect(flushCount, 1);
    expect(exitCodes, [0]);
    expect(native.quitForUpdate, isNull);
  });

  test('packaged macOS keeps its native Sparkle quit handoff', () async {
    final native = _FakeNativeUpdater();
    final service = AutoUpdateService.test(
      native: native,
      client: MockClient((_) async => http.Response('', 500)),
      platform: 'macos',
      sourceRun: false,
      currentVersion: () async => '1.0.0',
      launch: (_) async => true,
    );

    await service.initialize();

    expect(native.quitForUpdate, isNull);
  });

  test('source runs never initialize the packaged updater', () async {
    final native = _FakeNativeUpdater();
    final service = AutoUpdateService.test(
      native: native,
      client: MockClient((_) async => http.Response('', 500)),
      platform: 'macos',
      sourceRun: true,
      currentVersion: () async => '1.0.0',
      launch: (_) async => true,
    );
    await service.initialize();
    expect((await service.checkForUpdates()).status, ClientUpdateStatus.sourceManaged);
    expect(native.checkCount, 0);
  });

  test('Linux opens only a newer canonical artifact', () async {
    Uri? opened;
    final service = AutoUpdateService.test(
      native: _FakeNativeUpdater(),
      client: MockClient((_) async => http.Response(jsonEncode(_linuxClientManifest()), 200)),
      platform: 'linux',
      sourceRun: false,
      currentVersion: () async => '1.0.0',
      launch: (uri) async {
        opened = uri;
        return true;
      },
    );
    await service.initialize();
    expect((await service.checkForUpdates()).status, ClientUpdateStatus.updateOpened);
    expect(opened?.host, 'github.com');
    expect(opened?.path, endsWith('sanad-client-1.1.0-linux-x64.deb'));
  });
}

Map<String, dynamic> _linuxClientManifest() => {
  'schema_version': 1,
  'version': '1.1.0',
  'build_number': 2,
  'tag': 'v1.1.0',
  'commit': '1234567890abcdef',
  'channel': 'stable',
  'repository': 'EastStarAI/sanad-agent',
  'artifacts': [
    {
      'component': 'client',
      'platform': 'linux',
      'architecture': 'x64',
      'format': 'deb',
      'filename': 'sanad-client-1.1.0-linux-x64.deb',
      'url': 'https://github.com/EastStarAI/sanad-agent/releases/download/v1.1.0/sanad-client-1.1.0-linux-x64.deb',
      'sha256': List.filled(64, 'a').join(),
      'size': 42,
      'public': true,
      'signature_type': 'github-attestation',
    },
  ],
};

String _sha256OfBytes(List<int> bytes) =>
    sha256.convert(bytes).toString();

Map<String, dynamic> _manifest({required int size, required String digest}) => {
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
      'url': 'https://github.com/EastStarAI/sanad-agent/releases/download/v1.1.0/sanad-agent-1.1.0-linux-x64',
      'sha256': digest,
      'size': size,
      'public': true,
      'signature_type': 'github-attestation',
    },
  ],
};
