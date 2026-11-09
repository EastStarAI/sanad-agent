import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

/// Behavioural tests for the POSIX installer's native-runtime step.
///
/// These run the real `scripts/install.sh` against a sandboxed Home, a local
/// `file://` manifest, a fake Agent binary, and a fault-injecting `mv` on
/// `PATH`. Asserting source strings would not catch the double-rollback bug:
/// the script deleted the restored runtime and still printed a clean rollback.
///
/// macOS only on purpose. The Linux branch refuses a host without systemd or
/// OpenRC before it reaches this code, and the macOS branch is where the
/// publisher-signature check lives — shimmed here so the runtime state machine
/// is what the test exercises.
void main() {
  if (Platform.isWindows || !Platform.isMacOS) {
    test('installer runtime rollback', () {
      markTestSkipped('the installer harness runs the macOS installer branch');
    });
    return;
  }

  group('runtime install', () {
    test('a runtime that cannot be installed never fails the install', () {
      final sandbox = _Sandbox.create(
        libraries: {'libsanad_whisper.dylib': 'fake-whisper'},
        failFinalMove: true,
      );
      try {
        final result = sandbox.run();
        final stderr = result.stderr as String;

        expect(result.exitCode, 0, reason: stderr);
        expect(
          stderr,
          contains('Native dictation runtime installation failed'),
          reason: 'the dictation-only failure is still reported',
        );
        expect(stderr, isNot(contains('rollback completed')));
        expect(
          sandbox.targetFile.readAsStringSync(),
          isNot(sandbox.previousAgent),
          reason: 'the verified Agent installs and runs regardless',
        );
        expect(
          File('${sandbox.runtimeDir.path}/OLD-MARKER').existsSync(),
          isTrue,
          reason: 'the previous runtime is restored, not lost to the failure',
        );
        expect(
          sandbox.runtimeFailureMarker.readAsStringSync().trim(),
          'runtime_install_failed',
          reason: 'dictation readiness has to name the failure',
        );
        expect(
          Directory('${sandbox.runtimeDir.path}.rollback').existsSync(),
          isFalse,
        );
        expect(File('${sandbox.targetFile.path}.rollback').existsSync(), isFalse);
      } finally {
        sandbox.dispose();
      }
    });

    test('a runtime checksum mismatch never fails the install', () {
      final sandbox = _Sandbox.create(
        libraries: {'libsanad_whisper.dylib': 'fake-whisper'},
        runtimeShaMismatch: true,
      );
      try {
        final result = sandbox.run();
        final stderr = result.stderr as String;

        expect(result.exitCode, 0, reason: stderr);
        expect(stderr, contains('Native runtime SHA-256 verification failed'));
        expect(
          sandbox.targetFile.readAsStringSync(),
          isNot(sandbox.previousAgent),
          reason: 'the Agent update is independent of the runtime',
        );
        expect(
          File('${sandbox.runtimeDir.path}/OLD-MARKER').existsSync(),
          isTrue,
          reason: 'an unverified archive never replaces the installed runtime',
        );
        expect(
          File('${sandbox.runtimeDir.path}/libsanad_whisper.dylib').existsSync(),
          isFalse,
          reason: 'nothing from the rejected archive is extracted',
        );
        expect(
          sandbox.runtimeFailureMarker.readAsStringSync().trim(),
          'runtime_install_failed',
        );
      } finally {
        sandbox.dispose();
      }
    });

    test('a runtime download error never fails the install', () {
      final sandbox = _Sandbox.create(
        libraries: {'libsanad_whisper.dylib': 'fake-whisper'},
        runtimeDownloadFails: true,
      );
      try {
        final result = sandbox.run();
        final stderr = result.stderr as String;

        expect(result.exitCode, 0, reason: stderr);
        expect(
          sandbox.targetFile.readAsStringSync(),
          isNot(sandbox.previousAgent),
          reason: 'a transient download error must not block the Agent',
        );
        expect(
          File('${sandbox.runtimeDir.path}/OLD-MARKER').existsSync(),
          isTrue,
        );
        expect(
          sandbox.runtimeFailureMarker.readAsStringSync().trim(),
          'runtime_install_failed',
        );
      } finally {
        sandbox.dispose();
      }
    });

    test('a verified runtime installs and clears a previous failure', () {
      final sandbox = _Sandbox.create(
        libraries: {'libsanad_whisper.dylib': 'fake-whisper'},
      );
      File(sandbox.runtimeFailureMarker.path)
        ..createSync(recursive: true)
        ..writeAsStringSync('runtime_download_failed\n');
      try {
        final result = sandbox.run();
        final stderr = result.stderr as String;

        expect(result.exitCode, 0, reason: stderr);
        expect(
          File('${sandbox.runtimeDir.path}/libsanad_whisper.dylib').existsSync(),
          isTrue,
          reason: 'the verified runtime is installed beside the Agent',
        );
        expect(
          sandbox.runtimeFailureMarker.existsSync(),
          isFalse,
          reason: 'a successful install clears the recorded reason',
        );
      } finally {
        sandbox.dispose();
      }
    });

    test('a later service failure restores the runtime this run replaced', () {
      final sandbox = _Sandbox.create(
        libraries: {'libsanad_whisper.dylib': 'fake-whisper'},
        failServiceInstall: true,
      );
      try {
        final result = sandbox.run();
        final stderr = result.stderr as String;

        expect(result.exitCode, isNot(0));
        expect(stderr, contains('Service health verification failed'));
        expect(stderr, contains('installation rollback completed'));
        expect(stderr, isNot(contains('could not be fully restored')));
        expect(
          sandbox.targetFile.readAsStringSync(),
          sandbox.previousAgent,
          reason: 'the previous executable must be restored',
        );
        expect(
          File('${sandbox.runtimeDir.path}/OLD-MARKER').existsSync(),
          isTrue,
          reason: 'the runtime this run replaced must come back',
        );
        expect(
          File('${sandbox.runtimeDir.path}/libsanad_whisper.dylib').existsSync(),
          isFalse,
          reason: 'the runtime installed by the failed run must be gone',
        );
        expect(
          Directory('${sandbox.runtimeDir.path}.rollback').existsSync(),
          isFalse,
          reason: 'a completed restore leaves no backup behind',
        );
        expect(File('${sandbox.targetFile.path}.rollback').existsSync(), isFalse);
      } finally {
        sandbox.dispose();
      }
    });

    test('a restore that fails keeps the backup and never claims success', () {
      final sandbox = _Sandbox.create(
        libraries: {'libsanad_whisper.dylib': 'fake-whisper'},
        failServiceInstall: true,
        failRestoreMove: true,
      );
      try {
        final result = sandbox.run();
        final stderr = result.stderr as String;

        expect(result.exitCode, isNot(0));
        expect(stderr, contains('Service health verification failed'));
        expect(
          stderr,
          contains('could not be fully restored'),
          reason: 'a failed restore must never read as a completed rollback',
        );
        expect(stderr, isNot(contains('installation rollback completed')));
        expect(
          File('${sandbox.runtimeDir.path}.rollback/OLD-MARKER').existsSync(),
          isTrue,
          reason: 'the only surviving copy of the previous runtime is kept',
        );
        expect(
          Directory(sandbox.runtimeDir.path).existsSync(),
          isFalse,
          reason: 'the failed run must not leave its own runtime installed',
        );
        expect(
          sandbox.targetFile.readAsStringSync(),
          sandbox.previousAgent,
          reason: 'the executable restore is independent and still succeeds',
        );
      } finally {
        sandbox.dispose();
      }
    });

    test('a first install that fails later removes the runtime it added', () {
      final sandbox = _Sandbox.create(
        libraries: {'libsanad_whisper.dylib': 'fake-whisper'},
        failServiceInstall: true,
        noPreviousRuntime: true,
      );
      try {
        final result = sandbox.run();
        final stderr = result.stderr as String;

        expect(result.exitCode, isNot(0));
        expect(stderr, contains('installation rollback completed'));
        expect(
          Directory(sandbox.runtimeDir.path).existsSync(),
          isFalse,
          reason: 'with no predecessor the run must not leave its runtime',
        );
        expect(
          sandbox.targetFile.readAsStringSync(),
          sandbox.previousAgent,
          reason: 'the executable predecessor still comes back',
        );
        expect(File('${sandbox.targetFile.path}.rollback').existsSync(), isFalse);
      } finally {
        sandbox.dispose();
      }
    });

    test('a failed removal of the replaced runtime keeps both copies and reports', () {
      final sandbox = _Sandbox.create(
        libraries: {'libsanad_whisper.dylib': 'fake-whisper'},
        failServiceInstall: true,
        failRuntimeRemoval: true,
      );
      try {
        final result = sandbox.run();
        final stderr = result.stderr as String;

        expect(result.exitCode, isNot(0));
        expect(
          stderr,
          contains('could not be fully restored'),
          reason: 'a runtime that could not be removed is not a clean rollback',
        );
        expect(stderr, isNot(contains('installation rollback completed')));
        expect(
          sandbox.targetFile.readAsStringSync(),
          sandbox.previousAgent,
          reason: 'executable restoration still runs after the removal failure',
        );
        expect(
          File('${sandbox.runtimeDir.path}.rollback/OLD-MARKER').existsSync(),
          isTrue,
          reason: 'the predecessor backup is never buried by a forced move',
        );
        expect(
          Directory(sandbox.runtimeDir.path).existsSync(),
          isTrue,
          reason: 'the unremovable directory is kept and reported, not hidden',
        );
      } finally {
        sandbox.dispose();
      }
    });

    test('a failed removal on a first install still restores and reports', () {
      final sandbox = _Sandbox.create(
        libraries: {'libsanad_whisper.dylib': 'fake-whisper'},
        failServiceInstall: true,
        failRuntimeRemoval: true,
        noPreviousRuntime: true,
      );
      try {
        final result = sandbox.run();
        final stderr = result.stderr as String;

        expect(result.exitCode, isNot(0));
        expect(stderr, contains('could not be fully restored'));
        expect(stderr, isNot(contains('installation rollback completed')));
        expect(
          sandbox.targetFile.readAsStringSync(),
          sandbox.previousAgent,
          reason: 'the executable predecessor comes back regardless',
        );
        expect(
          Directory(sandbox.runtimeDir.path).existsSync(),
          isTrue,
          reason: 'the directory that could not be removed is left intact',
        );
      } finally {
        sandbox.dispose();
      }
    });

    test('a symlink in the archive is refused and nothing is replaced', () {
      final sandbox = _Sandbox.create(
        libraries: {'libsanad_whisper.dylib': 'fake-whisper'},
        extraLinks: {'libevil.dylib': 'libsanad_whisper.dylib'},
      );
      try {
        final result = sandbox.run();
        final stderr = result.stderr as String;

        expect(result.exitCode, 0, reason: stderr);
        expect(
          stderr,
          contains('entry that is not a regular file'),
          reason: stderr,
        );
        expect(
          File('${sandbox.runtimeDir.path}/OLD-MARKER').existsSync(),
          isTrue,
        );
        expect(
          File('${sandbox.runtimeDir.path}/libevil.dylib').existsSync(),
          isFalse,
        );
        expect(
          sandbox.runtimeFailureMarker.readAsStringSync().trim(),
          'runtime_install_failed',
        );
      } finally {
        sandbox.dispose();
      }
    });

    test('a hidden archive member is refused', () {
      final sandbox = _Sandbox.create(
        libraries: {'libsanad_whisper.dylib': 'fake-whisper', '.hidden': 'x'},
      );
      try {
        final result = sandbox.run();
        final stderr = result.stderr as String;

        expect(result.exitCode, 0, reason: stderr);
        expect(stderr, contains('hidden entry'), reason: stderr);
        expect(
          File('${sandbox.runtimeDir.path}/OLD-MARKER').existsSync(),
          isTrue,
        );
        expect(
          sandbox.runtimeFailureMarker.readAsStringSync().trim(),
          'runtime_install_failed',
        );
      } finally {
        sandbox.dispose();
      }
    });

    test('the engine subtree installs, a deeper one is refused', () {
      // The packaged runtime carries the sherpa-onnx libraries under `sherpa/`
      // with the loader-relative macOS layout; that is the only nesting the
      // installer accepts.
      const macosSherpa =
          'sherpa/sherpa_onnx_macos/sherpa-onnx.xcframework/'
          'macos-arm64_x86_64/libsherpa-onnx-c-api.dylib';
      final accepted = _Sandbox.create(
        libraries: {
          'libsanad_whisper.dylib': 'fake-whisper',
          macosSherpa: 'fake-sherpa',
        },
      );
      try {
        final result = accepted.run();
        expect(result.exitCode, 0, reason: result.stderr as String);
        expect(
          File('${accepted.runtimeDir.path}/$macosSherpa').existsSync(),
          isTrue,
          reason: 'the engine subtree is installed beside the shim',
        );
        expect(
          accepted.runtimeFailureMarker.existsSync(),
          isFalse,
          reason: result.stderr as String,
        );
      } finally {
        accepted.dispose();
      }

      final refused = _Sandbox.create(
        libraries: {
          'libsanad_whisper.dylib': 'fake-whisper',
          'sherpa/a/b/c/d/e/libsherpa-onnx-c-api.dylib': 'too-deep',
        },
      );
      try {
        final result = refused.run();
        final stderr = result.stderr as String;
        expect(result.exitCode, 0, reason: stderr);
        expect(stderr, contains('unexpected layout'), reason: stderr);
        expect(
          File('${refused.runtimeDir.path}/OLD-MARKER').existsSync(),
          isTrue,
          reason: 'a refused archive never replaces the installed runtime',
        );
      } finally {
        refused.dispose();
      }
    });

    test('a release without a runtime keeps the installed one', () {
      final sandbox = _Sandbox.create(
        libraries: {'libsanad_whisper.dylib': 'fake-whisper'},
        declareRuntime: false,
      );
      File(sandbox.runtimeFailureMarker.path)
        ..createSync(recursive: true)
        ..writeAsStringSync('runtime_download_failed\n');
      try {
        final result = sandbox.run();
        final stderr = result.stderr as String;

        expect(result.exitCode, 0, reason: stderr);
        expect(stderr, contains('keeping the runtime already installed'));
        expect(
          File('${sandbox.runtimeDir.path}/OLD-MARKER').existsSync(),
          isTrue,
        );
        expect(
          sandbox.targetFile.readAsStringSync(),
          isNot(sandbox.previousAgent),
          reason: 'the new executable is installed even without a runtime',
        );
        expect(
          sandbox.runtimeFailureMarker.existsSync(),
          isFalse,
          reason: 'publishing no runtime is not a recorded failure',
        );
      } finally {
        sandbox.dispose();
      }
    });
  });
}

class _Sandbox {
  _Sandbox._({
    required this.root,
    required this.home,
    required this.runtimeDir,
    required this.targetFile,
    required this.previousAgent,
    required this.manifestPath,
    required this.shims,
  });

  factory _Sandbox.create({
    required Map<String, String> libraries,
    Map<String, String> extraLinks = const {},
    bool declareRuntime = true,
    bool failFinalMove = false,
    bool failServiceInstall = false,
    bool failRestoreMove = false,
    bool failRuntimeRemoval = false,
    bool noPreviousRuntime = false,
    bool runtimeShaMismatch = false,
    bool runtimeDownloadFails = false,
  }) {
    final root = Directory.systemTemp.createTempSync('installer-runtime-');
    final home = Directory('${root.path}/home')..createSync(recursive: true);
    final bin = Directory('${home.path}/bin')..createSync(recursive: true);
    final runtimeDir = Directory('${bin.path}/native/macos-arm64');
    if (!noPreviousRuntime) {
      runtimeDir.createSync(recursive: true);
      File('${runtimeDir.path}/OLD-MARKER')
          .writeAsStringSync('previous runtime');
    }

    final previousAgent = _agentScript();
    final installedAgent = _agentScript(failServiceInstall: failServiceInstall);
    final target = File('${bin.path}/sanad')
      ..writeAsStringSync(previousAgent);
    Process.runSync('chmod', ['755', target.path]);

    final stage = Directory('${root.path}/stage/native/macos-arm64')
      ..createSync(recursive: true);
    for (final entry in libraries.entries) {
      // A key may carry a relative path (the engine's `sherpa/` subtree keeps
      // the loader-relative layout), so the parent is created here.
      final file = File('${stage.path}/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }
    for (final link in extraLinks.entries) {
      Link('${stage.path}/${link.key}').createSync(link.value);
    }
    final archive = File('${root.path}/runtime.tar.gz');
    final tar = Process.runSync('tar', [
      '-czf',
      archive.path,
      '-C',
      '${root.path}/stage',
      'native',
    ]);
    if (tar.exitCode != 0) {
      throw StateError('tar failed: ${tar.stderr}');
    }

    final agentArtifact = File('${root.path}/sanad-agent-1.0.20-macos-arm64')
      ..writeAsStringSync('$installedAgent# release artifact\n');
    Process.runSync('chmod', ['755', agentArtifact.path]);

    final runtimeName = 'sanad-agent-runtime-1.0.20-macos-arm64.tar.gz';
    final runtimeUrl = runtimeDownloadFails
        ? '${root.uri}missing/runtime.tar.gz'
        : archive.uri.toString();
    final manifest = <String, Object?>{
      'schema_version': 1,
      'version': '1.0.20',
      'tag': 'v1.0.20',
      'repository': 'EastStarAI/sanad-agent',
      'artifacts': [
        {
          'component': 'agent',
          'platform': 'macos',
          'architecture': 'arm64',
          'format': 'executable',
          'filename': 'sanad-agent-1.0.20-macos-arm64',
          'public': true,
          'signature_type': 'developer-id+notarization+github-attestation',
          'url': agentArtifact.uri.toString(),
          'sha256': _sha256(agentArtifact.readAsBytesSync()),
          'size': agentArtifact.lengthSync(),
        },
        if (declareRuntime)
          {
            'component': 'agent-runtime',
            'platform': 'macos',
            'architecture': 'arm64',
            'format': 'tar.gz',
            'filename': runtimeName,
            'public': true,
            'signature_type': 'github-attestation',
            'url': runtimeUrl,
            'sha256': runtimeShaMismatch
                ? '0' * 64
                : _sha256(archive.readAsBytesSync()),
            'size': archive.lengthSync(),
          },
      ],
    };
    final manifestPath = File('${root.path}/release-manifest.json')
      ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));

    final shims = Directory('${root.path}/shims')..createSync(recursive: true);
    File('${shims.path}/codesign').writeAsStringSync('#!/bin/sh\nexit 0\n');
    final mv = StringBuffer('#!/bin/sh\n')
      ..writeln('last=""')
      ..writeln('for arg in "\$@"; do last="\$arg"; done');
    if (failFinalMove) {
      mv
        ..writeln('case "\$last" in')
        ..writeln('  */bin/native/macos-arm64)')
        ..writeln('    case "\$1" in')
        ..writeln(
          '      */runtime/native/macos-arm64) '
          'echo "forced final move failure" >&2; exit 1 ;;',
        )
        ..writeln('    esac')
        ..writeln('    ;;')
        ..writeln('esac');
    }
    if (failRestoreMove) {
      mv
        ..writeln('case "\$1" in')
        ..writeln(
          '  */bin/native/macos-arm64.rollback) '
          'echo "forced runtime restore failure" >&2; exit 1 ;;',
        )
        ..writeln('esac');
    }
    mv.writeln('exec /bin/mv "\$@"');
    File('${shims.path}/mv').writeAsStringSync(mv.toString());
    final rm = StringBuffer('#!/bin/sh\n')
      ..writeln('last=""')
      ..writeln('for arg in "\$@"; do last="\$arg"; done');
    if (failRuntimeRemoval) {
      rm
        ..writeln('case "\$last" in')
        ..writeln(
          '  */bin/native/macos-arm64) '
          'echo "forced runtime removal failure" >&2; exit 1 ;;',
        )
        ..writeln('esac');
    }
    rm.writeln('exec /bin/rm "\$@"');
    File('${shims.path}/rm').writeAsStringSync(rm.toString());
    for (final name in ['codesign', 'mv', 'rm']) {
      Process.runSync('chmod', ['755', '${shims.path}/$name']);
    }

    return _Sandbox._(
      root: root,
      home: home,
      runtimeDir: runtimeDir,
      targetFile: target,
      previousAgent: previousAgent,
      manifestPath: manifestPath,
      shims: shims,
    );
  }

  final Directory root;
  final Directory home;
  final Directory runtimeDir;
  final File targetFile;
  final String previousAgent;
  final File manifestPath;
  final Directory shims;

  /// The machine-readable reason the installer records for a dictation-only
  /// runtime failure.
  File get runtimeFailureMarker =>
      File('${home.path}/bin/native/.runtime-install-failed');

  ProcessResult run() {
    final environment = Map<String, String>.from(Platform.environment)
      ..['SANAD_HOME'] = home.path
      ..['SANAD_INSTALL_ALLOW_TEST_URL'] = '1'
      ..['SANAD_RELEASE_MANIFEST_URL'] = manifestPath.uri.toString()
      ..['PATH'] = '${shims.path}:${Platform.environment['PATH'] ?? ''}';
    return Process.runSync(
      'bash',
      [File('../scripts/install.sh').absolute.path, '--no-login'],
      workingDirectory: Directory.current.path,
      environment: environment,
      includeParentEnvironment: false,
    );
  }

  void dispose() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  }

  static String _agentScript({bool failServiceInstall = false}) =>
      '#!/bin/sh\n'
      'case "\$1" in\n'
      '  service)\n'
      '    case "\$2" in\n'
      '      status) echo "Installed:  No"; echo "Running:    No" ;;\n'
      '${failServiceInstall ? '      install) exit 1 ;;\n' : ''}'
      '      *) exit 0 ;;\n'
      '    esac\n'
      '    ;;\n'
      '  login)\n'
      '    case "\$2" in\n'
      '      --status) echo "Status: Not authenticated" ;;\n'
      '      *) exit 0 ;;\n'
      '    esac\n'
      '    ;;\n'
      '  *) exit 0 ;;\n'
      'esac\n';

  static String _sha256(List<int> bytes) => sha256.convert(bytes).toString();
}
