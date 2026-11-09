import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/update/agent_runtime_bundle.dart';
import 'package:sanad_agent/core/update/agent_update_service.dart';
import 'package:sanad_release_contract/release_contract.dart';
import 'package:test/test.dart';

/// A failure to download or verify the packaged `agent-runtime` archive disables
/// **dictation only**.
///
/// The Agent update is the path that matters most here: a user who never
/// dictates must still receive the executable update, and the reason the runtime
/// is absent has to survive in a form dictation readiness can report. Trust
/// strictness is unchanged — an unverified archive is never extracted.
void main() {
  late Directory workspace;
  late File executable;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('agent-update-policy-');
    executable = File('${workspace.path}/sanad-agent')
      ..writeAsStringSync('installed-agent');
  });

  tearDown(() {
    if (workspace.existsSync()) workspace.deleteSync(recursive: true);
  });

  String digestOf(List<int> bytes) => sha256.convert(bytes).toString();

  List<int> agentBytes() => 'new-agent'.codeUnits;

  File runtimeArchive({Map<String, String> members = const {}}) {
    final staging = Directory('${workspace.path}/runtime-staging/native/linux-x64')
      ..createSync(recursive: true);
    final contents = members.isEmpty
        ? {'libsanad_whisper.so': 'shim'}
        : members;
    contents.forEach((name, value) {
      File('${staging.path}/$name').writeAsStringSync(value);
    });
    final archive = File('${workspace.path}/runtime.tar.gz');
    final tar = Process.runSync('tar', [
      '-czf',
      archive.path,
      '-C',
      '${workspace.path}/runtime-staging',
      'native/linux-x64',
    ]);
    expect(tar.exitCode, 0, reason: '${tar.stderr}');
    return archive;
  }

  String manifestJson({
    required File runtime,
    String? runtimeDigest,
    bool publishRuntime = true,
  }) {
    final bytes = agentBytes();
    final artifacts = <Map<String, Object?>>[
      {
        'component': 'agent',
        'platform': 'linux',
        'architecture': 'x64',
        'format': 'executable',
        'filename': 'sanad-agent-1.1.0-linux-x64',
        'url':
            'https://github.com/EastStarAI/sanad-agent/releases/download/'
            'v1.1.0/sanad-agent-1.1.0-linux-x64',
        'sha256': digestOf(bytes),
        'size': bytes.length,
        'public': true,
        'signature_type': 'github-attestation',
      },
      if (publishRuntime)
        {
          'component': 'agent-runtime',
          'platform': 'linux',
          'architecture': 'x64',
          'format': 'tar.gz',
          'filename': 'sanad-agent-runtime-1.1.0-linux-x64.tar.gz',
          'url':
              'https://github.com/EastStarAI/sanad-agent/releases/download/'
              'v1.1.0/sanad-agent-runtime-1.1.0-linux-x64.tar.gz',
          'sha256':
              runtimeDigest ?? digestOf(runtime.readAsBytesSync()),
          'size': runtime.lengthSync(),
          'public': true,
          'signature_type': 'github-attestation',
        },
    ];
    return jsonEncode(
      ReleaseManifest(
        schemaVersion: 1,
        version: ReleaseVersion.parse('1.1.0'),
        buildNumber: 2,
        tag: 'v1.1.0',
        commit: 'b' * 40,
        channel: ReleaseChannel.stable,
        repository: 'EastStarAI/sanad-agent',
        artifacts: [
          for (final artifact in artifacts) ReleaseArtifact.fromJson(artifact),
        ],
      ).toJson(),
    );
  }

  AgentUpdateService serviceFor({
    required String manifest,
    required List<int> runtimeBody,
    int runtimeStatus = 200,
  }) => AgentUpdateService(
    currentVersion: '1.0.0',
    executablePath: executable.path,
    isSourceManaged: false,
    manifestUri: Uri.parse('https://example.invalid/release-manifest.json'),
    operatingSystem: 'linux',
    architecture: 'x64',
    platformVerifier: (file, operatingSystem) async => true,
    client: MockClient((request) async {
      if (request.url.path.endsWith('release-manifest.json')) {
        return http.Response(manifest, 200);
      }
      if (request.url.path.endsWith('.tar.gz')) {
        return http.Response.bytes(runtimeBody, runtimeStatus);
      }
      return http.Response.bytes(agentBytes(), 200);
    }),
  );

  Directory nativeRoot() => Directory('${workspace.path}/native');

  test('a runtime download error never blocks the Agent update', () async {
    final runtime = runtimeArchive();
    final service = serviceFor(
      manifest: manifestJson(runtime: runtime),
      runtimeBody: const [],
      runtimeStatus: 503,
    );

    final result = await service.update();

    expect(result.status, AgentUpdateStatus.restartRequired);
    expect(result.isSuccess, isTrue);
    expect(result.runtimeStatus, AgentRuntimeBundleStatus.downloadFailed);
    expect(
      executable.readAsStringSync(),
      isNot('installed-agent'),
      reason: 'the verified executable is replaced',
    );
    expect(
      NativeRuntimeInstall.read(nativeRoot()),
      NativeRuntimeInstall.downloadFailed,
      reason: 'dictation readiness names the recorded cause',
    );
  });

  test('a runtime checksum mismatch never blocks the Agent update', () async {
    final runtime = runtimeArchive();
    final service = serviceFor(
      manifest: manifestJson(runtime: runtime, runtimeDigest: 'd' * 64),
      runtimeBody: runtime.readAsBytesSync(),
    );

    final result = await service.update();

    expect(result.status, AgentUpdateStatus.restartRequired);
    expect(result.isSuccess, isTrue);
    expect(result.runtimeStatus, AgentRuntimeBundleStatus.checksumFailed);
    expect(
      Directory('${nativeRoot().path}/linux-x64').existsSync(),
      isFalse,
      reason: 'an unverified archive is never extracted',
    );
    expect(
      NativeRuntimeInstall.read(nativeRoot()),
      NativeRuntimeInstall.checksumFailed,
    );
  });

  test('a verified runtime installs and leaves no failure recorded', () async {
    final runtime = runtimeArchive();
    await NativeRuntimeInstall.record(
      nativeRoot(),
      NativeRuntimeInstall.downloadFailed,
    );
    final service = serviceFor(
      manifest: manifestJson(runtime: runtime),
      runtimeBody: runtime.readAsBytesSync(),
    );

    final result = await service.update();

    expect(result.status, AgentUpdateStatus.restartRequired);
    expect(result.runtimeStatus, AgentRuntimeBundleStatus.installed);
    expect(
      File('${nativeRoot().path}/linux-x64/libsanad_whisper.so').existsSync(),
      isTrue,
    );
    expect(NativeRuntimeInstall.read(nativeRoot()), isNull);
  });

  test('a release without a runtime still updates and clears the record',
      () async {
    final runtime = runtimeArchive();
    await NativeRuntimeInstall.record(
      nativeRoot(),
      NativeRuntimeInstall.downloadFailed,
    );
    final service = serviceFor(
      manifest: manifestJson(runtime: runtime, publishRuntime: false),
      runtimeBody: const [],
    );

    final result = await service.update();

    expect(result.status, AgentUpdateStatus.restartRequired);
    expect(result.runtimeStatus, AgentRuntimeBundleStatus.notPublished);
    expect(NativeRuntimeInstall.read(nativeRoot()), isNull);
  });
}
