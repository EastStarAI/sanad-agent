import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/update/agent_runtime_bundle.dart';
import 'package:sanad_release_contract/release_contract.dart';
import 'package:test/test.dart';

/// The runtime bundle is an untrusted download that lands in the installed
/// layout. These tests pin the order that matters: nothing is extracted before
/// size, SHA-256, trust, and member layout all pass; a failure never damages the
/// runtime that is already there.
void main() {
  late Directory workspace;
  late Directory installDir;
  late File executable;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('agent-runtime-bundle-');
    installDir = Directory('${workspace.path}/install')..createSync(recursive: true);
    executable = File('${installDir.path}/sanad-agent')..writeAsStringSync('binary');
  });

  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  /// Builds a `native/<tag>/…` gzip tar with the host `tar`, exactly like the
  /// release job does, so the extractor sees real member names.
  File archiveWith(String tag, Map<String, String> members) {
    final staging = Directory('${workspace.path}/staging');
    if (staging.existsSync()) staging.deleteSync(recursive: true);
    final root = Directory('${staging.path}/native/$tag')
      ..createSync(recursive: true);
    members.forEach((name, contents) {
      final file = File('${root.path}/$name');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(contents);
    });
    final archive = File('${workspace.path}/runtime.tar.gz');
    final result = Process.runSync('tar', [
      '-czf',
      archive.path,
      '-C',
      staging.path,
      'native/$tag',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return archive;
  }

  Future<ReleaseManifest> manifestFor(
    File archive, {
    String platform = 'linux',
    String architecture = 'x64',
    bool published = true,
    String? sha256,
    int? size,
  }) async {
    final artifact = ReleaseArtifact(
      component: 'agent-runtime',
      platform: platform,
      architecture: architecture,
      format: 'tar.gz',
      filename: 'sanad-agent-runtime-1.0.0-$platform-$architecture.tar.gz',
      url: Uri.parse(
        'https://github.com/EastStarAI/sanad-agent/releases/download/'
        'v1.0.0/sanad-agent-runtime-1.0.0-$platform-$architecture.tar.gz',
      ),
      sha256: sha256 ?? await sha256OfFile(archive),
      size: size ?? archive.lengthSync(),
      public: true,
      signatureType: 'github-attestation',
    );
    return ReleaseManifest(
      schemaVersion: 1,
      version: ReleaseVersion.parse('1.0.0'),
      buildNumber: 1,
      tag: 'v1.0.0',
      commit: 'a' * 40,
      channel: ReleaseChannel.stable,
      repository: 'EastStarAI/sanad-agent',
      artifacts: published ? [artifact] : const [],
    );
  }

  AgentRuntimeBundle bundleFor(File archive) => AgentRuntimeBundle(
    client: MockClient(
      (request) async => http.Response.bytes(archive.readAsBytesSync(), 200),
    ),
    operatingSystem: 'linux',
    architecture: 'x64',
  );

  group('agent runtime bundle', () {
    test('a verified bundle is installed beside the executable', () async {
      final archive = archiveWith('linux-x64', {
        'libsanad_whisper.so': 'shim',
        'libggml.so.1': 'ggml',
      });
      final manifest = await manifestFor(archive);

      final result = await bundleFor(archive).refresh(
        manifest: manifest,
        executablePath: executable.path,
      );

      expect(result.status, AgentRuntimeBundleStatus.installed);
      final installed = Directory('${installDir.path}/native/linux-x64');
      expect(installed.existsSync(), isTrue);
      expect(
        File('${installed.path}/libsanad_whisper.so').readAsStringSync(),
        'shim',
      );
      expect(Directory('${installDir.path}/native/linux-x64.rollback').existsSync(), isFalse);
      expect(
        Directory('${installDir.path}/native')
            .listSync()
            .where((entity) => entity.path.endsWith('.tar.gz')),
        isEmpty,
        reason: 'the downloaded archive never outlives the refresh',
      );
    });

    test('a manifest without this target keeps the existing runtime', () async {
      final archive = archiveWith('linux-x64', {'libsanad_whisper.so': 'new'});
      final existing = Directory('${installDir.path}/native/linux-x64')
        ..createSync(recursive: true);
      File('${existing.path}/libsanad_whisper.so').writeAsStringSync('old');
      final manifest = await manifestFor(archive);

      final result = await AgentRuntimeBundle(
        client: MockClient((request) async => http.Response('', 200)),
        operatingSystem: 'linux',
        architecture: 'arm64',
      ).refresh(manifest: manifest, executablePath: executable.path);

      expect(result.status, AgentRuntimeBundleStatus.notPublished);
      expect(
        File('${existing.path}/libsanad_whisper.so').readAsStringSync(),
        'old',
      );
    });

    test('a checksum mismatch leaves the previous runtime untouched', () async {
      final archive = archiveWith('linux-x64', {'libsanad_whisper.so': 'new'});
      final existing = Directory('${installDir.path}/native/linux-x64')
        ..createSync(recursive: true);
      File('${existing.path}/libsanad_whisper.so').writeAsStringSync('old');
      final manifest = await manifestFor(archive, sha256: 'b' * 64);

      final result = await bundleFor(archive).refresh(
        manifest: manifest,
        executablePath: executable.path,
      );

      expect(result.status, AgentRuntimeBundleStatus.checksumFailed);
      expect(
        File('${existing.path}/libsanad_whisper.so').readAsStringSync(),
        'old',
      );
    });

    test('an unexpected member is refused before extraction', () async {
      final archive = archiveWith('linux-x64', {
        'libsanad_whisper.so': 'shim',
        'models/ggml-base.bin': 'model payload',
      });
      // The nested member arrives as `native/linux-x64/models/ggml-base.bin`.
      final manifest = await manifestFor(archive);

      final result = await bundleFor(archive).refresh(
        manifest: manifest,
        executablePath: executable.path,
      );

      expect(result.status, AgentRuntimeBundleStatus.layoutRejected);
      expect(
        Directory('${installDir.path}/native/linux-x64').existsSync(),
        isFalse,
      );
    });

    test('a member outside the tag directory is refused', () async {
      final staging = Directory('${workspace.path}/foreign')..createSync();
      final root = Directory('${staging.path}/native/macos-arm64')
        ..createSync(recursive: true);
      File('${root.path}/libsanad_whisper.dylib').writeAsStringSync('shim');
      final archive = File('${workspace.path}/foreign.tar.gz');
      final tar = Process.runSync('tar', [
        '-czf',
        archive.path,
        '-C',
        staging.path,
        'native/macos-arm64',
      ]);
      expect(tar.exitCode, 0);
      final manifest = await manifestFor(archive);

      final result = await bundleFor(archive).refresh(
        manifest: manifest,
        executablePath: executable.path,
      );

      expect(result.status, AgentRuntimeBundleStatus.layoutRejected);
    });

    test('a model payload is not a runtime library', () async {
      final archive = archiveWith('linux-x64', {'ggml-tiny.bin': 'model'});
      final manifest = await manifestFor(archive);

      final result = await bundleFor(archive).refresh(
        manifest: manifest,
        executablePath: executable.path,
      );

      expect(result.status, AgentRuntimeBundleStatus.layoutRejected);
    });

    test('an unreachable download never touches the installed runtime',
        () async {
      final archive = archiveWith('linux-x64', {'libsanad_whisper.so': 'new'});
      final existing = Directory('${installDir.path}/native/linux-x64')
        ..createSync(recursive: true);
      File('${existing.path}/libsanad_whisper.so').writeAsStringSync('old');
      final manifest = await manifestFor(archive);

      final result = await AgentRuntimeBundle(
        client: MockClient((request) async => http.Response('', 503)),
        operatingSystem: 'linux',
        architecture: 'x64',
      ).refresh(manifest: manifest, executablePath: executable.path);

      expect(result.status, AgentRuntimeBundleStatus.downloadFailed);
      expect(
        File('${existing.path}/libsanad_whisper.so').readAsStringSync(),
        'old',
      );
    });

    test('Windows stages the verified runtime for the restart script', () async {
      final archive = archiveWith('windows-x64', {'sanad_whisper.dll': 'dll'});
      final manifest = await manifestFor(
        archive,
        platform: 'windows',
        architecture: 'x64',
      );

      final result = await AgentRuntimeBundle(
        client: MockClient(
          (request) async => http.Response.bytes(archive.readAsBytesSync(), 200),
        ),
        operatingSystem: 'windows',
        architecture: 'x64',
      ).refresh(manifest: manifest, executablePath: executable.path);

      expect(result.status, AgentRuntimeBundleStatus.stagedForRestart);
      expect(result.stagedPath, '${installDir.path}/native/windows-x64.staged');
      expect(Directory(result.stagedPath!).existsSync(), isTrue);
      // The live directory is only replaced by the elevated restart script.
      expect(
        Directory('${installDir.path}/native/windows-x64').existsSync(),
        isFalse,
      );
    });

    test('a not-published manifest is a terminal success', () {
      const result = AgentRuntimeBundleResult(AgentRuntimeBundleStatus.notPublished);

      expect(result.isTerminalSuccess, isTrue);
      expect(
        const AgentRuntimeBundleResult(AgentRuntimeBundleStatus.checksumFailed)
            .isTerminalSuccess,
        isFalse,
      );
    });
  });
}
