import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/cli/runner/commands/update_command.dart';
import 'package:sanad_agent/core/update/agent_update_service.dart';
import 'package:sanad_release_contract/release_contract.dart';
import 'package:test/test.dart';

/// Task 107 — typed, bounded, sanitized platform trust diagnostics.
void main() {
  group('sanitizePlatformVerifierOutput', () {
    test('strips artifact, home, temp and per-user paths', () {
      final sanitized = sanitizePlatformVerifierOutput(
        '/private/var/folders/ab/cd123/T/stage/sanad: invalid signature\n'
        'requirement from /Volumes/Data/alice/.sanad/bin/sanad '
        'tmp /var/folders/zz/yy/T/other '
        '/Users/bob/x /home/carol/y D:\\Users\\dave\\z.exe',
        filePath: '/var/folders/ab/cd123/T/stage/sanad',
        environment: const {
          'HOME': '/Volumes/Data/alice',
          'TMPDIR': '/var/folders/zz/yy/T/',
        },
      );

      expect(sanitized, startsWith('<artifact>: invalid signature'));
      expect(sanitized, contains('<home>/.sanad/bin/sanad'));
      expect(sanitized, contains('tmp <temp>/other'));
      expect(sanitized, contains('/Users/<user>/x'));
      expect(sanitized, contains('/home/<user>/y'));
      expect(sanitized, contains(r'D:\Users\<user>\z.exe'));
      for (final private in [
        'alice',
        'bob',
        'carol',
        'dave',
        'cd123',
        'zz/yy',
      ]) {
        expect(sanitized, isNot(contains(private)));
      }
    });

    test('collapses control sequences into one bounded line', () {
      final sanitized = sanitizePlatformVerifierOutput(
        '\x1B[31mfirst\x1B[0m\r\n\tsecond${' x' * 600}',
        environment: const {},
      );

      expect(sanitized, startsWith('first second x'));
      expect(sanitized, isNot(contains('\n')));
      expect(sanitized, isNot(contains('\x1B')));
      expect(
        sanitized.length,
        lessThanOrEqualTo(platformVerifierDetailMaxLength),
      );
      expect(sanitized, endsWith('...'));
    });

    test('never treats a filesystem root as a private prefix', () {
      expect(
        sanitizePlatformVerifierOutput(
          'error at /usr/bin/codesign',
          environment: const {'HOME': '/', 'TMPDIR': '/'},
        ),
        'error at /usr/bin/codesign',
      );
    });
  });

  group('verifyPlatformCodeSignatureDetailed', () {
    final candidate = File('/tmp/sanad-agent-candidate');

    test('maps codesign exit 3 to the publisher requirement stage', () async {
      final result = await verifyPlatformCodeSignatureDetailed(
        candidate,
        'macos',
        processRunner: (_, _) async => ProcessResult(
          1,
          3,
          '',
          '/tmp/sanad-agent-candidate: valid on disk\n'
              'test-requirement: code failed to satisfy specified code requirement(s)',
        ),
      );

      expect(result.isTrusted, isFalse);
      expect(result.stage, PlatformTrustStage.publisherRequirement);
      expect(result.exitCode, 3);
      expect(result.detail, startsWith('<artifact>: valid on disk'));
      expect(
        result.summary,
        startsWith('stage=publisher_requirement: exit=3: '),
      );
    });

    test('maps other codesign failures to signature verification', () async {
      final result = await verifyPlatformCodeSignatureDetailed(
        candidate,
        'macos',
        processRunner: (_, _) async =>
            ProcessResult(1, 1, '', 'code object is not signed at all'),
      );

      expect(result.stage, PlatformTrustStage.codesignVerification);
      expect(result.detail, 'code object is not signed at all');
    });

    test('fails closed when codesign cannot be launched', () async {
      final result = await verifyPlatformCodeSignatureDetailed(
        candidate,
        'macos',
        processRunner: (_, _) async =>
            throw const ProcessException('/usr/bin/codesign', [], 'missing'),
      );

      expect(result.isTrusted, isFalse);
      expect(result.stage, PlatformTrustStage.verifierUnavailable);
      expect(
        await verifyPlatformCodeSignature(
          candidate,
          'macos',
          processRunner: (_, _) async =>
              throw const ProcessException('/usr/bin/codesign', [], 'missing'),
        ),
        isFalse,
      );
    });

    test(
      'reports a non-Valid Authenticode status through the runner',
      () async {
        String? executable;
        final result = await verifyPlatformCodeSignatureDetailed(
          File(r'C:\Users\erin\AppData\Local\Temp\sanad.exe'),
          'windows',
          processRunner: (command, _) async {
            executable = command;
            return ProcessResult(1, 0, 'False', '');
          },
        );

        expect(executable, 'powershell.exe');
        expect(result.stage, PlatformTrustStage.authenticodeSignature);
        expect(result.detail, 'False');
      },
    );
  });

  group('verifyReleaseArtifactTrustDetailed', () {
    late File file;

    setUp(() async {
      file = File(
        '${Directory.systemTemp.path}/sanad-trust-detailed-${DateTime.now().microsecondsSinceEpoch}',
      );
      await file.writeAsBytes([1, 2, 3]);
    });

    tearDown(() async {
      if (file.existsSync()) await file.delete();
    });

    test('reports the metadata stage for a policy violation', () async {
      final artifact = _macosArtifact();
      final result = await verifyReleaseArtifactTrustDetailed(
        file,
        artifact: ReleaseArtifact.fromJson({
          ...artifact.toJson(),
          'signature_type': 'github-attestation',
        }),
        detailedVerifier: (_, _) async => const PlatformTrustResult.trusted(),
      );

      expect(result.isTrusted, isFalse);
      expect(result.stage, PlatformTrustStage.metadataValidation);
    });

    test('labels a legacy boolean rejection and keeps the bool API', () async {
      final result = await verifyReleaseArtifactTrustDetailed(
        file,
        artifact: _macosArtifact(),
        platformVerifier: (_, _) async => false,
      );

      expect(result.stage, PlatformTrustStage.platformVerifier);
      expect(
        await verifyReleaseArtifactTrust(
          file,
          artifact: _macosArtifact(),
          platformVerifier: (_, _) async => true,
        ),
        isTrue,
      );
    });

    test('fails closed when a detailed verifier throws', () async {
      final result = await verifyReleaseArtifactTrustDetailed(
        file,
        artifact: _macosArtifact(),
        detailedVerifier: (_, _) async => throw StateError('boom'),
      );

      expect(result.isTrusted, isFalse);
      expect(result.stage, PlatformTrustStage.verifierUnavailable);
    });
  });

  group('AgentUpdateService trust failure', () {
    test('returns the typed sanitized stage and keeps the old binary', () async {
      final directory = await Directory.systemTemp.createTemp('sanad-trust-');
      addTearDown(() => directory.delete(recursive: true));
      final executable = File('${directory.path}/sanad')
        ..writeAsStringSync('old');
      final bytes = [1, 2, 3];
      final artifactFile = File('${directory.path}/artifact')
        ..writeAsBytesSync(bytes);
      final artifact = _macosArtifact(
        size: bytes.length,
        sha256: await sha256OfFile(artifactFile),
      );
      final manifest = jsonEncode(_manifest(artifact));
      final service = AgentUpdateService(
        currentVersion: '1.0.0',
        executablePath: executable.path,
        isSourceManaged: false,
        operatingSystem: 'macos',
        architecture: 'x64',
        detailedPlatformVerifier: (file, _) async =>
            PlatformTrustResult.untrusted(
              stage: PlatformTrustStage.publisherRequirement,
              exitCode: 3,
              detail: sanitizePlatformVerifierOutput(
                '${file.path}: failed requirement',
                filePath: file.path,
              ),
            ),
        client: MockClient((request) async {
          if (request.url.path.endsWith('release-manifest.json')) {
            return http.Response(manifest, 200);
          }
          return http.Response.bytes(bytes, 200);
        }),
      );

      final result = await service.update();

      expect(result.status, AgentUpdateStatus.trustFailed);
      expect(
        result.message,
        contains(
          '(stage=publisher_requirement: exit=3: <artifact>: failed requirement)',
        ),
      );
      expect(result.message, isNot(contains(directory.path)));
      expect(executable.readAsStringSync(), 'old');
    });
  });

  group('sanad update recovery guidance', () {
    test('names only the official POSIX installer outside Windows', () {
      for (final os in ['macos', 'linux']) {
        final guidance = trustFailureRecoveryGuidance(os);
        expect(
          guidance,
          contains(
            'curl -fsSL https://sanad.eaststarai.com/install.sh -o install.sh '
            '&& bash install.sh --no-login',
          ),
        );
        expect(guidance, isNot(contains('install.ps1')));
        expect(guidance, contains('restarts the background service'));
      }
    });

    test('names the official PowerShell installer on Windows', () {
      final guidance = trustFailureRecoveryGuidance('windows');
      expect(
        guidance,
        contains(
          '& ([scriptblock]::Create((irm https://sanad.eaststarai.com/install.ps1))) -NoLogin',
        ),
      );
      expect(guidance, isNot(contains('bash')));
    });

    test('pairing commands quote the token for their shell', () {
      expect(
        OfficialAgentInstaller.pairingCommand('linux', "pairing' token"),
        "curl -fsSL https://sanad.eaststarai.com/install.sh | bash -s -- --pairing-token 'pairing'\\'' token'",
      );
      expect(
        OfficialAgentInstaller.pairingCommand('windows', "pairing' token"),
        "& ([scriptblock]::Create((irm https://sanad.eaststarai.com/install.ps1))) -PairingToken 'pairing'' token'",
      );
    });

    test('never names a host other than the documented installer host', () {
      for (final os in ['macos', 'linux', 'windows']) {
        final hosts = RegExp(r'https://([^/\s]+)')
            .allMatches(trustFailureRecoveryGuidance(os))
            .map((match) => match.group(1))
            .toSet();
        expect(hosts, {'sanad.eaststarai.com'});
      }
    });
  });
}

ReleaseArtifact _macosArtifact({
  int size = 3,
  String? sha256,
}) => ReleaseArtifact.fromJson({
  'component': 'agent',
  'platform': 'macos',
  'architecture': 'x64',
  'format': 'executable',
  'filename': 'sanad-agent-1.1.0-macos-x64',
  'url':
      'https://github.com/EastStarAI/sanad-agent/releases/download/v1.1.0/sanad-agent-1.1.0-macos-x64',
  'sha256': sha256 ?? 'a' * 64,
  'size': size,
  'public': true,
  'signature_type': 'developer-id+notarization+github-attestation',
});

Map<String, dynamic> _manifest(ReleaseArtifact artifact) => {
  'schema_version': 1,
  'version': '1.1.0',
  'build_number': 2,
  'tag': 'v1.1.0',
  'commit': '1234567890abcdef',
  'channel': 'stable',
  'repository': 'EastStarAI/sanad-agent',
  'artifacts': [artifact.toJson()],
};
