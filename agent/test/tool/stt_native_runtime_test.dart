import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/infrastructure/stt/stt_native_platform.dart';
import 'package:sanad_stt_sherpa/sanad_stt_sherpa.dart' show sherpaEngineAvailable;
import 'package:test/test.dart';

import '../../tool/stt_native_runtime.dart';
import '../support/native_binary_fixture.dart';

/// Verification and staging rules for the native dictation runtime.
///
/// Everything runs against synthetic Mach-O files for `macos-x64`, so the Intel
/// path is exercised on any host without building whisper.cpp: a test that
/// needed a real build could only prove what the runner is, not what the rules
/// are.
void main() {
  const target = SttNativeTarget.macosX64;
  late Directory nativeRoot;
  late Directory stageRoot;

  setUp(() {
    nativeRoot = Directory.systemTemp.createTempSync('stt-native-root-');
    stageRoot = Directory.systemTemp.createTempSync('stt-stage-');
  });

  tearDown(() {
    for (final directory in [nativeRoot, stageRoot]) {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    }
  });
  Directory runtimeDirectory([SttNativeTarget value = target]) {
    final directory = Directory('${nativeRoot.path}/${value.nativeDirectory}')
      ..createSync(recursive: true);
    return directory;
  }

  SttRuntimeManifest manifestWith(
    Map<String, Object?> entry, {
    SttNativeTarget value = target,
  }) {
    return SttRuntimeManifest.fromJson({
      'whisper_cpp_version': '1.9.5',
      'artifacts': {value.tag: entry},
    });
  }

  group('verify', () {
    test('an architecture-valid runtime with a matching entry verifies', () async {
      runtimeDirectory();
      final hashes = writeFakeRuntime(
        directory: runtimeDirectory(),
        target: target,
      );

      final verification = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: target,
        manifest: manifestWith(hashes),
      );

      expect(verification.ok, isTrue);
      expect(verification.problems, isEmpty);
      expect(verification.pinned, isTrue);
      expect(verification.pinState, SttRuntimePinState.pinned);
      expect(verification.hashes, hashes);
    });

    test('a missing manifest entry fails verification', () async {
      writeFakeRuntime(directory: runtimeDirectory(), target: target);

      final verification = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: target,
        manifest: SttRuntimeManifest.fromJson(const {'artifacts': {}}),
      );

      expect(verification.ok, isFalse);
      expect(
        verification.problems,
        contains('manifest_entry_missing:${target.tag}'),
      );
      expect(verification.pinState, SttRuntimePinState.missing);
    });

    test('an unpinned entry is reported, never a silent pass', () async {
      writeFakeRuntime(directory: runtimeDirectory(), target: target);

      final verification = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: target,
        manifest: manifestWith({sttManifestStatusKey: 'unpinned'}),
      );

      expect(verification.ok, isTrue);
      expect(verification.pinned, isFalse);
      expect(verification.pinState, SttRuntimePinState.unpinned);
      expect(verification.unpinned, target.requiredLibraries);
      expect(
        verification.warnings,
        contains('unpinned_hashes:${target.requiredLibraries.length}'),
      );
    });

    test('the legacy locally-built status keeps its hashes authoritative', () async {
      final hashes = writeFakeRuntime(
        directory: runtimeDirectory(),
        target: target,
      );

      final verification = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: target,
        manifest: manifestWith({...hashes, sttManifestStatusKey: 'locally-built'}),
      );

      expect(verification.ok, isTrue);
      expect(verification.pinState, SttRuntimePinState.locallyBuilt);
      // Locally built bytes are not an independently reproducible artifact, so
      // the stage must not claim to be pinned.
      expect(verification.pinned, isFalse);
    });

    test('a foreign-architecture library fails verification', () async {
      final directory = runtimeDirectory();
      writeFakeRuntime(directory: directory, target: target);
      // Replace one dylib with the other slice: the exact leftover that made
      // readiness report ready and the session fail at load.
      final shim = File('${directory.path}/libsanad_whisper.dylib')
        ..writeAsBytesSync(
          fakeLibraryBytes(
            target: SttNativeTarget.macosArm64,
            fileName: 'libsanad_whisper.dylib',
          ),
        );

      final verification = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: target,
        manifest: manifestWith(const {}),
      );

      expect(verification.ok, isFalse);
      expect(
        verification.problems,
        contains('architecture_mismatch:${shim.uri.pathSegments.last}'),
      );
    });

    test('a library newer than the deployment target fails', () async {
      writeFakeRuntime(
        directory: runtimeDirectory(),
        target: target,
        minimumMacOs: '26.0',
      );

      final verification = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: target,
        manifest: manifestWith(const {}),
      );

      expect(verification.ok, isFalse);
      expect(
        verification.problems.where(
          (problem) => problem.startsWith('deployment_target_too_high:'),
        ),
        hasLength(target.requiredLibraries.length),
      );
    });

    test('a library without a recorded deployment target only warns', () async {
      final directory = runtimeDirectory();
      for (final name in target.requiredLibraries) {
        File('${directory.path}/$name').writeAsBytesSync(
          machOThin(cpu: SttNativeCpu.x64),
        );
      }

      final verification = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: target,
        manifest: manifestWith(const {}),
      );

      expect(verification.ok, isTrue);
      expect(
        verification.warnings.where(
          (warning) => warning.startsWith('deployment_target_unknown:'),
        ),
        hasLength(target.requiredLibraries.length),
      );
    });

    test('a missing library is reported by name', () async {
      final directory = runtimeDirectory();
      writeFakeRuntime(directory: directory, target: target);
      File('${directory.path}/libggml-cpu.0.dylib').deleteSync();

      final verification = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: target,
        manifest: manifestWith(const {}),
      );

      expect(verification.ok, isFalse);
      expect(verification.missing, ['libggml-cpu.0.dylib']);
      expect(
        verification.problems,
        contains('missing_library:libggml-cpu.0.dylib'),
      );
    });

    test('a text file in a library slot is not a native library', () async {
      final directory = runtimeDirectory();
      writeFakeRuntime(directory: directory, target: target);
      File('${directory.path}/libggml.0.dylib')
          .writeAsStringSync('not a dylib');

      final verification = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: target,
        manifest: manifestWith(const {}),
      );

      expect(verification.ok, isFalse);
      expect(
        verification.problems,
        contains('unrecognized_native_binary:libggml.0.dylib'),
      );
    });

    test('a pinned mismatch is a warning unless pinned hashes are required', () async {
      final hashes = writeFakeRuntime(
        directory: runtimeDirectory(),
        target: target,
      );
      final stale = {...hashes, 'libggml.0.dylib': 'a' * 64};

      final advisory = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: target,
        manifest: manifestWith(stale),
      );
      expect(advisory.ok, isTrue);
      expect(advisory.warnings, contains('checksum_differs_from_pinned:libggml.0.dylib'));

      final strict = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: target,
        manifest: manifestWith(stale),
        requirePinnedHashes: true,
      );
      expect(strict.ok, isFalse);
      expect(strict.problems, contains('checksum_mismatch:libggml.0.dylib'));
    });

    test('the legacy Apple Silicon directory is never a build output', () async {
      final legacy = Directory('${nativeRoot.path}/macos')..createSync();
      writeFakeRuntime(directory: legacy, target: SttNativeTarget.macosArm64);

      final verification = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: SttNativeTarget.macosArm64,
        manifest: manifestWith(const {}, value: SttNativeTarget.macosArm64),
      );

      expect(verification.directory, '${nativeRoot.path}/macos-arm64');
      expect(verification.ok, isFalse);
      expect(
        verification.problems,
        contains('missing_library:libsanad_whisper.dylib'),
      );
    });
  });

  group('linux relocatability', () {
    // glibc resolves a library's DT_NEEDED through that library's own RUNPATH,
    // not through the search path of the image that loaded it. The first arm64
    // install shipped `libwhisper.so.1` beside a shim that carried `$ORIGIN` and
    // still failed with `libggml.so.0 => not found`: the staged bytes were
    // correct, the recorded search path was not.
    test('a runtime whose libraries record \$ORIGIN verifies', () async {
      const linux = SttNativeTarget.linuxArm64;
      final hashes = writeFakeRuntime(
        directory: runtimeDirectory(linux),
        target: linux,
      );

      final verification = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: linux,
        manifest: manifestWith(hashes, value: linux),
      );

      expect(verification.problems, isEmpty);
      expect(verification.ok, isTrue);
      expect(verification.runPaths.keys, unorderedEquals(hashes.keys));
      for (final name in hashes.keys) {
        expect(verification.runPaths[name], [elfOriginRunPath]);
      }
    });

    test('a library without an origin search path fails verification', () async {
      const linux = SttNativeTarget.linuxX64;
      final directory = runtimeDirectory(linux);
      for (final name in linux.requiredLibraries) {
        // Exactly the shape the cmake build produced before the install rpath
        // was configured: a real library, the right architecture, no `$ORIGIN`.
        File('${directory.path}/$name')
            .writeAsBytesSync(elfLibrary(linux.cpu));
      }

      final verification = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: linux,
        manifest: manifestWith(const {}, value: linux),
      );

      expect(verification.ok, isFalse);
      for (final name in linux.requiredLibraries) {
        expect(verification.problems, contains('origin_runpath_missing:$name'));
      }
    });

    test('an engine library is reported, never a build this cannot fix', () async {
      // The sherpa libraries are third-party bytes: this repository cannot
      // relink them, so a missing `$ORIGIN` there is a stated warning rather
      // than a failure no change in this tree could clear.
      if (!sherpaEngineAvailable) {
        markTestSkipped('this build has no sherpa engine');
        return;
      }
      const linux = SttNativeTarget.linuxX64;
      final directory = runtimeDirectory(linux);
      writeFakeRuntime(directory: directory, target: linux);
      final relative = linux.sherpaLibraries.first;
      final engineKey = '${linux.sherpaNativeSubdirectory}/$relative';
      for (final relativePath in linux.sherpaLibraries) {
        final file = File(
          '${directory.path}/${linux.sherpaNativeSubdirectory}/$relativePath',
        );
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(elfLibrary(linux.cpu));
      }

      final verification = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: linux,
        manifest: manifestWith(const {}, value: linux),
      );

      expect(verification.ok, isTrue);
      expect(
        verification.warnings,
        contains('origin_runpath_missing:$engineKey'),
      );
    });

    test('the loader gate never passes a folder it could not probe', () async {
      const linux = SttNativeTarget.linuxX64;
      final directory = Directory.systemTemp.createTempSync('stt-ldd-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });

      final check = await checkLoaderResolution(
        target: linux,
        directory: directory.path,
      );

      if (!Platform.isLinux) {
        expect(
          check.skipped,
          isTrue,
          reason: 'only Linux can answer this question',
        );
        return;
      }
      expect(check.skipped, isFalse);
      expect(check.ok, isFalse);
      expect(check.unresolved, unorderedEquals(linux.requiredLibraries));
    });
  });

  group('manifest', () {
    test('reads artifact entries and their provenance', () {
      final manifest = SttRuntimeManifest.fromJson({
        'whisper_cpp_version': '1.9.5',
        'artifacts': {
          'macos-x64': {sttManifestStatusKey: 'unpinned'},
          'macos-arm64': {
            'libsanad_whisper.dylib': 'b' * 64,
            sttManifestArchiveKey: 'c' * 64,
          },
        },
      });

      expect(manifest.whisperCppVersion, '1.9.5');
      expect(
        manifest.pinStateFor(SttNativeTarget.macosX64),
        SttRuntimePinState.unpinned,
      );
      expect(
        manifest.pinStateFor(SttNativeTarget.macosArm64),
        SttRuntimePinState.pinned,
      );
      expect(
        manifest.archiveHashFor(SttNativeTarget.macosArm64),
        'c' * 64,
      );
      expect(manifest.archiveHashFor(SttNativeTarget.macosX64), isNull);
    });

    test('tolerates a missing or malformed manifest file', () {
      final missing = SttRuntimeManifest.load(
        File('${nativeRoot.path}/absent.json'),
      );
      expect(missing.artifacts, isEmpty);
      expect(missing.whisperCppVersion, isEmpty);

      final broken = File('${nativeRoot.path}/checksums.json')
        ..writeAsStringSync('{ not json');
      expect(SttRuntimeManifest.load(broken).artifacts, isEmpty);
    });

    test('the tracked manifest declares Intel as unpinned', () {
      // The tracked file must not invent hashes for a platform no authorized
      // producer has built yet.
      final manifest = SttRuntimeManifest.load(
        File('${Directory.current.path}/native/$sttRuntimeManifestFileName'),
      );
      expect(
        manifest.pinStateFor(SttNativeTarget.macosX64),
        SttRuntimePinState.unpinned,
      );
      expect(manifest.archiveHashFor(SttNativeTarget.macosX64), isNull);
      expect(
        manifest.pinStateFor(SttNativeTarget.macosArm64),
        SttRuntimePinState.locallyBuilt,
      );
    });

    test('every buildable target declares its provenance', () {
      // `--verify` and `--stage` refuse a platform with no entry, so adding a
      // target to the shared mapping without a manifest entry would break the
      // build lane for that platform.
      final manifest = SttRuntimeManifest.load(
        File('${Directory.current.path}/native/$sttRuntimeManifestFileName'),
      );
      for (final value in SttNativeTarget.values) {
        expect(
          manifest.pinStateFor(value),
          isNot(SttRuntimePinState.missing),
          reason: '${value.tag} has no artifacts entry',
        );
      }
    });
  });

  group('stage', () {
    test('copies exactly the required libraries and records real hashes', () async {
      final runtime = runtimeDirectory();
      final whisperHashes = writeFakeRuntime(directory: runtime, target: target);
      // Model weights and build leftovers must never travel with the Agent.
      File('${runtime.path}/ggml-model-q8.bin').writeAsBytesSync([1, 2, 3]);
      File('${runtime.path}/libggml.0.dylib.bak').writeAsBytesSync([4, 5, 6]);

      // The sherpa libraries come from the engine's own resolution, so the test
      // hands staging a source directory exactly as the tool does. A build
      // without the engine links a stand-in, stages no engine subtree, and must
      // not be asked for one here.
      final sherpaSource = Directory('${nativeRoot.parent.path}'
          '/stt-sherpa-source-${DateTime.now().microsecondsSinceEpoch}');
      final sherpaHashes = sherpaEngineAvailable
          ? writeFakeSherpaRuntime(directory: sherpaSource, target: target)
          : <String, String>{};
      final hashes = {...whisperHashes, ...sherpaHashes};

      final verification = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: target,
        manifest: manifestWith(hashes),
      );
      final stage = await stageSttRuntime(
        nativeRoot: nativeRoot,
        target: target,
        stageRoot: stageRoot,
        manifest: manifestWith(hashes),
        verification: verification,
        sherpaSource: sherpaSource.path,
      );

      final staged = <String>{};
      for (final entity
          in Directory(stage.directory).listSync(recursive: true)) {
        if (entity is! File) continue;
        staged.add(
          entity.path.substring(stage.directory.length + 1),
        );
      }
      expect(
        staged,
        {...target.requiredLibraries, ...sherpaHashes.keys},
      );
      expect(
        File('${stage.directory}/ggml-model-q8.bin').existsSync(),
        isFalse,
      );
      expect(stage.hashes, hashes);

      final manifestFile = await writeStageManifest(
        stageRoot: stageRoot,
        target: target,
        manifest: buildStageManifest(
          stage: stage,
          verification: verification,
          archive: const {'file': 'sanad-stt-macos-x64-v1.9.5.tar.gz'},
        ),
      );
      final recorded =
          jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
      expect(recorded['target'], 'macos-x64');
      expect(recorded['native_directory'], 'macos-x64');
      expect(recorded['pin_state'], 'pinned');
      expect(recorded['pinned'], isTrue);
      expect(recorded['whisper_cpp_version'], '1.9.5');
      expect(
        (recorded['files'] as Map<String, dynamic>)['libsanad_whisper.dylib']['sha256'],
        hashes['libsanad_whisper.dylib'],
      );
      expect(
        manifestFile.readAsStringSync(),
        isNot(contains(nativeRoot.path)),
        reason: 'the stage record must not embed absolute paths',
      );
    });

    test('refuses to stage an unverified runtime', () async {
      runtimeDirectory();
      final verification = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: target,
        manifest: manifestWith(const {}),
      );

      await expectLater(
        stageSttRuntime(
          nativeRoot: nativeRoot,
          target: target,
          stageRoot: stageRoot,
          manifest: manifestWith(const {}),
          verification: verification,
        ),
        throwsA(isA<SttRuntimeStageException>()),
      );
    });
  });

  group('versions', () {
    test('compares dotted deployment targets', () {
      expect(compareVersions('12.0', '12.0'), 0);
      expect(compareVersions('12.0', '11.9'), greaterThan(0));
      expect(compareVersions('10.15.7', '12.0'), lessThan(0));
      expect(compareVersions('12', '12.0.0'), 0);
      expect(compareVersions('26.0', '12.0'), greaterThan(0));
    });
  });

  group('strict pins', () {
    test('an unpinned entry cannot pass the download layer', () async {
      writeFakeRuntime(directory: runtimeDirectory(), target: target);
      final verification = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: target,
        manifest: manifestWith({sttManifestStatusKey: 'unpinned'}),
        requirePinnedHashes: true,
      );

      expect(verification.ok, isFalse);
      expect(
        verification.problems,
        contains('pin_state_unpinned:${target.tag}'),
      );
      for (final name in target.requiredLibraries) {
        expect(verification.problems, contains('pinned_hash_missing:$name'));
      }
      // The strict gate must not silently downgrade to "unpinned is fine".
      expect(verification.unpinned, target.requiredLibraries);
    });

    test('a malformed pin fails instead of counting as unpinned', () async {
      final hashes = writeFakeRuntime(
        directory: runtimeDirectory(),
        target: target,
      );
      final first = target.requiredLibraries.first;
      final malformed = {
        for (final entry in hashes.entries)
          entry.key: entry.key == first ? entry.value.substring(1) : entry.value,
      };
      final verification = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: target,
        manifest: manifestWith(malformed),
        requirePinnedHashes: true,
      );

      expect(verification.ok, isFalse);
      expect(verification.problems, contains('pinned_hash_missing:$first'));
    });

    test('strict pins accept a configured artifact that matches', () async {
      final hashes = writeFakeRuntime(
        directory: runtimeDirectory(),
        target: target,
      );
      final verification = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: target,
        manifest: manifestWith(hashes),
        requirePinnedHashes: true,
      );

      expect(verification.ok, isTrue);
      expect(verification.unpinned, isEmpty);
    });

    test('a fresh build stays advisory even when pins exist', () async {
      final hashes = writeFakeRuntime(
        directory: runtimeDirectory(),
        target: target,
      );
      final drifted = {
        for (final entry in hashes.entries) entry.key: 'a' * 64,
      };
      final verification = await verifySttRuntime(
        nativeRoot: nativeRoot,
        target: target,
        manifest: manifestWith(drifted),
      );

      // Locally built bytes are expected to differ from a published artifact;
      // that is a named warning, never a silent pass and never a hard failure.
      expect(verification.ok, isTrue);
      expect(
        verification.warnings,
        contains('checksum_differs_from_pinned:${target.requiredLibraries.first}'),
      );
      expect(verification.pinned, isFalse);
    });
  });

  group('builder arguments', () {
    test('Intel receives the tag-style architecture the script accepts', () {
      final arguments = sttPosixBuilderArguments(
        target: SttNativeTarget.macosX64,
        whisperSource: '/src/whisper.cpp',
        outputDirectory: 'native/macos-x64.tmp',
      );

      expect(arguments, [
        'tool/build_whispercpp.sh',
        '/src/whisper.cpp',
        'native/macos-x64.tmp',
        'x64',
        '12.0',
      ]);
      // `x86_64` is the CMake spelling. The script maps it itself, so passing
      // it here failed the script's own architecture check and Intel could
      // never build.
      expect(arguments, isNot(contains('x86_64')));
    });

    test('Apple Silicon keeps Metal and its deployment target', () {
      expect(
        sttPosixBuilderArguments(
          target: SttNativeTarget.macosArm64,
          whisperSource: '/src',
          outputDirectory: 'out',
        ),
        ['tool/build_whispercpp.sh', '/src', 'out', 'arm64', '12.0'],
      );
    });

    test('Linux takes no deployment target', () {
      expect(
        sttPosixBuilderArguments(
          target: SttNativeTarget.linuxX64,
          whisperSource: '/src',
          outputDirectory: 'out',
        ),
        ['tool/build_whispercpp.sh', '/src', 'out', 'x64'],
      );
    });
  });

  group('download request', () {
    final pinned = SttRuntimeManifest.fromJson({
      'whisper_cpp_version': '1.9.5',
      'artifacts': {
        target.tag: {sttManifestArchiveKey: 'c' * 64},
      },
    });

    test('a release asset URL becomes the exact requested name', () {
      final request = sttArchiveRequest(
        target: target,
        manifest: pinned,
        whisperVersion: '1.9.5',
        archiveUrl:
            'https://github.com/EastStarAI/sanad-agent/releases/download/'
            'v1.0.20/sanad-agent-runtime-1.0.20-macos-x64.tar.gz',
      );

      expect(request, isNotNull);
      expect(request!.fileName, 'sanad-agent-runtime-1.0.20-macos-x64.tar.gz');
      expect(
        request.url,
        'https://github.com/EastStarAI/sanad-agent/releases/download/'
        'v1.0.20/sanad-agent-runtime-1.0.20-macos-x64.tar.gz',
      );
      expect(request.sha256, 'c' * 64);
    });

    test('base URL plus explicit name matches the release artifact', () {
      final request = sttArchiveRequest(
        target: target,
        manifest: pinned,
        whisperVersion: '1.9.5',
        baseUrl: 'https://example.test/assets/',
        archiveName: 'sanad-agent-runtime-1.0.20-macos-x64.tar.gz',
      );

      expect(request, isNotNull);
      expect(
        request!.url,
        'https://example.test/assets/sanad-agent-runtime-1.0.20-macos-x64.tar.gz',
      );
    });

    test('the whisper-version default stays a local name only', () {
      final request = sttArchiveRequest(
        target: target,
        manifest: pinned,
        whisperVersion: '1.9.5',
        baseUrl: 'https://example.test/assets',
      );

      expect(request!.fileName, 'sanad-stt-macos-x64-v1.9.5.tar.gz');
    });

    test('no pinned archive hash refuses every form', () {
      final unpinned = SttRuntimeManifest.fromJson({
        'artifacts': {
          target.tag: {sttManifestStatusKey: 'unpinned'},
        },
      });

      expect(
        sttArchiveRequest(
          target: target,
          manifest: unpinned,
          whisperVersion: '1.9.5',
          baseUrl: 'https://example.test/assets',
        ),
        isNull,
      );
      expect(
        sttArchiveRequest(
          target: target,
          manifest: unpinned,
          whisperVersion: '1.9.5',
          archiveUrl: 'https://example.test/assets/x.tar.gz',
        ),
        isNull,
      );
    });

    test('a non-archive URL is refused', () {
      expect(
        sttArchiveRequest(
          target: target,
          manifest: pinned,
          whisperVersion: '1.9.5',
          archiveUrl: 'https://example.test/assets/not-a-tarball.zip',
        ),
        isNull,
      );
    });

    test('only an HTTPS product location is accepted', () {
      for (final url in [
        'http://example.test/assets/sanad-agent-runtime-1.0.20-macos-x64.tar.gz',
        'file:///tmp/sanad-agent-runtime-1.0.20-macos-x64.tar.gz',
        'ftp://example.test/sanad-agent-runtime-1.0.20-macos-x64.tar.gz',
      ]) {
        expect(
          sttArchiveRequest(
            target: target,
            manifest: pinned,
            whisperVersion: '1.9.5',
            archiveUrl: url,
          ),
          isNull,
          reason: 'cleartext or local scheme $url must not be a product source',
        );
      }
      for (final base in [
        'http://example.test/assets',
        'file:///tmp/assets',
      ]) {
        expect(
          sttArchiveRequest(
            target: target,
            manifest: pinned,
            whisperVersion: '1.9.5',
            baseUrl: base,
            archiveName: 'sanad-agent-runtime-1.0.20-macos-x64.tar.gz',
          ),
          isNull,
          reason: 'base URL $base must not produce a cleartext product URL',
        );
      }
    });
  });

  group('instruction sets', () {
    // The listings below are real disassembly, not hand-written mnemonics. Each
    // was produced by compiling one probe twice with the host clang —
    // `-march=armv8.6-a+sve2+i8mm+bf16` (the shape a `GGML_NATIVE=ON` build on a
    // newer runner takes) and `-march=armv8.2-a+dotprod+fp16` (the shipped
    // baseline) — and keeping the compiler's own output. The instruction column
    // is what `objdump` writes on the CI runners, which is the column the guard
    // reads.
    const nativeArm64Listing =
        '       0:      \tfmla.4s\tv0, v2, v1\n'
        '       4:      \tmovi.2d\tv1, #0000000000000000\n'
        '       8:      \tsmmla\n'
        '       c:      \tfcvtzs.4s\tv0, v0\n'
        '      10:      \tmov.s\tv1[1], v0[0]\n'
        '      14:      \tstr\td1, [x0]\n'
        '      18:      \twhilelt\tp0.s, wzr, w2\n'
        '      1c:      \tld1w\t{ z0.s }, p0/z, [x1]\n'
        '      20:      \tfadd\tz0.s, p0/m, z0.s, z0.s\n'
        '      24:      \tst1w\t{ z0.s }, p0, [x1]\n'
        '      28:      \tret\n';
    const portableArm64Listing =
        '       0:      \tfmla.4s\tv0, v2, v1\n'
        '       4:      \tmovi.2d\tv1, #0000000000000000\n'
        '       8:      \tsdot.4s\tv1, v3, v4\n'
        '       c:      \tfcvtzs.4s\tv0, v0\n'
        '      10:      \tmov.s\tv1[1], v0[0]\n'
        '      14:      \tstr\td1, [x0]\n'
        '      18:      \tret\n';
    // GNU objdump's ELF shape: offset, raw bytes, instruction. The guard must
    // read the same instruction column here as in the listings above.
    const gnuArm64SveShapes =
        'libggml-cpu.so.0:     file format elf64-littleaarch64\n'
        '\n'
        '0000000000001234 <ggml_cpu_init>:\n'
        '    1234:\ta9bf7bfd \tstp\tx29, x30, [sp, #-16]!\n'
        '    1238:\t910003fd \tmov\tx29, sp\n'
        '    12c4:\t2518e3e0 \tptrue\tp0.b\n'
        '    12c8:\ta4404c20 \tld1w\t{ z0.s }, p0/z, [x1]\n'
        '    12cc:\t65800000 \tfadd\tz0.s, p0/m, z0.s, z0.s\n';
    const gnuArm64Bf16 =
        '    2000:\t6e40ec00 \tbfdot\tv0.4s, v1.8h, v2.8h\n'
        '    2004:\t6e40ec10 \tbfmmla\tv0.4s, v1.8h, v2.8h\n'
        '    2008:\t1e634000 \tbfcvt\tv0.4s, v0.2d\n';
    const gnuX64Avx512 =
        'libggml-cpu.so.0:     file format elf64-x86-64\n'
        '\n'
        '0000000000002000 <ggml_cpu_init>:\n'
        '    2000:\t62 f1 7c 48 10 04 0f \tvmovups\t(%rdi,%r9), %zmm0\n'
        '    2007:\t62 f1 7c 48 28 cb   \tvpmadd52huq\t%zmm3, %zmm0, %zmm1\n';
    const gnuX64Avx2 =
        '    2000:\tc5 fc 10 04 0f       \tvmovups\t(%rdi,%r9), %ymm0\n'
        '    2005:\tc4 e2 75 a8 cb       \tvfmadd213ps\t%ymm3, %ymm1, %ymm0\n'
        '    200a:\tc4 e2 79 13 c1       \tvcvtph2ps\t%xmm1, %ymm0\n';

    test('the arm64 guard rejects the listing a native build produces', () {
      final match = firstForbiddenAarch64Instruction(nativeArm64Listing);

      expect(match, isNotNull, reason: 'smmla needs i8mm');
      expect(match!.family, 'i8mm');
      expect(match.mnemonic, 'smmla');
    });

    test('the arm64 guard accepts the listing the portable baseline produces',
        () {
      // `sdot` is the dotprod the shipped baseline includes; forbidding it would
      // reject the runtime this repository builds on purpose.
      expect(firstForbiddenAarch64Instruction(portableArm64Listing), isNull);
    });

    test('the arm64 guard reads SVE operand shapes, not only SVE mnemonics', () {
      // A mnemonic list alone misses SVE: `fadd`/`ld1w` carry it as a z/p
      // operand, which is exactly how the faulting kernel is shaped.
      for (final line in [
        '    12cc:\t65800000 \tfadd\tz0.s, p0/m, z0.s, z0.s\n',
        '    12c8:\ta4404c20 \tld1w\t{ z0.s }, p0/z, [x1]\n',
        '    12c4:\t2518e3e0 \tptrue\tp0.b\n',
        '    12d0:\t2538cfe1 \twhilelt\tp1.s, wzr, w2\n',
      ]) {
        final listing = '    1234:\ta9bf7bfd \tstp\tx29, x30, [sp, #-16]!\n'
            '$line';
        expect(
          firstForbiddenAarch64Instruction(listing),
          isNotNull,
          reason: 'must reject $line',
        );
      }
      expect(firstForbiddenAarch64Instruction(gnuArm64SveShapes), isNotNull);
    });

    test('the arm64 guard rejects every BF16 instruction', () {
      expect(firstForbiddenAarch64Instruction(gnuArm64Bf16)?.family, 'bf16');
      for (final mnemonic in ['bfdot', 'bfmmla', 'bfcvt', 'bfcvtn2']) {
        expect(
          firstForbiddenAarch64Instruction('    0:\t0 \t$mnemonic\tv0.4s\n'),
          isNotNull,
          reason: '$mnemonic needs BF16',
        );
      }
    });

    test('the x64 guard rejects AVX-512 and accepts AVX2', () {
      final match = firstForbiddenX64Instruction(gnuX64Avx512);

      expect(match, isNotNull);
      expect(match!.family, 'avx512');
      expect(match.mnemonic, 'vmovups');
      expect(firstForbiddenX64Instruction(gnuX64Avx2), isNull);
    });

    test('a symbol name that looks like an instruction is ignored', () {
      // Mangled names can contain `z0`/`k1` by accident; they carry no tab and
      // are not instructions. Reading only the instruction column is what keeps
      // the guard from failing a portable build.
      const listing = '0000000000001234 <_ZN4ggml15z0_kernelEii>:\n'
          '    1234:\ta9bf7bfd \tstp\tx29, x30, [sp, #-16]!\n';

      expect(firstForbiddenAarch64Instruction(listing), isNull);
    });

    test('a portable listing reports ok and names each shipped library',
        () async {
      final directory = Directory.systemTemp.createTempSync('stt-isa-ok-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      for (final name in SttNativeTarget.linuxArm64.requiredLibraries) {
        File('${directory.path}/$name').writeAsStringSync('');
      }

      final check = await checkInstructionSets(
        target: SttNativeTarget.linuxArm64,
        directory: directory.path,
        requireDisassembler: true,
        disassembler: (_) async => portableArm64Listing,
      );

      expect(check.skipped, isFalse);
      expect(check.ok, isTrue);
      expect(
        check.evidence,
        unorderedEquals([
          for (final name in SttNativeTarget.linuxArm64.requiredLibraries)
            'native_stt_isa_$name=ok',
        ]),
      );
    });

    test('a CPU-specific listing fails the gate and points at the file',
        () async {
      final directory = Directory.systemTemp.createTempSync('stt-isa-bad-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      for (final name in SttNativeTarget.linuxArm64.requiredLibraries) {
        File('${directory.path}/$name').writeAsStringSync('');
      }

      final check = await checkInstructionSets(
        target: SttNativeTarget.linuxArm64,
        directory: directory.path,
        requireDisassembler: true,
        disassembler: (path) async =>
            path.endsWith('libggml-cpu.so.0') ? nativeArm64Listing : portableArm64Listing,
      );

      expect(check.ok, isFalse);
      expect(check.forbidden['libggml-cpu.so.0'], 'i8mm:smmla');
      expect(
        check.evidence,
        contains('native_stt_isa_libggml-cpu.so.0=forbidden:smmla'),
      );
      expect(
        check.evidence,
        contains('native_stt_isa_libggml.so.0=ok'),
        reason: 'one offending library must not condemn the portable ones',
      );
    });

    test('a missing disassembler is a stated skip, never a silent pass',
        () async {
      final directory = Directory.systemTemp.createTempSync('stt-isa-none-');
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      for (final name in SttNativeTarget.linuxArm64.requiredLibraries) {
        File('${directory.path}/$name').writeAsStringSync('');
      }
      Future<String> unavailable(String path) async =>
          throw const SttDisassemblyUnavailable('objdump');

      final skipped = await checkInstructionSets(
        target: SttNativeTarget.linuxArm64,
        directory: directory.path,
        disassembler: unavailable,
      );
      expect(skipped.skipped, isTrue);
      expect(skipped.ok, isTrue);

      // The proof lanes (CI sets SANAD_STT_REQUIRE_NATIVE=1) turn the same
      // condition into a failure: a guard that skips in CI is not a guard.
      final required = await checkInstructionSets(
        target: SttNativeTarget.linuxArm64,
        directory: directory.path,
        requireDisassembler: true,
        disassembler: unavailable,
      );
      expect(required.skipped, isFalse);
      expect(required.ok, isFalse);
      expect(required.problems, contains('isa_guard_unavailable:objdump'));
    });

    test('a target the disassembler cannot cover is skipped, not guessed',
        () async {
      // macOS and Windows payloads are pinned by the builder contract; claiming
      // a disassembly result there would be worse than stating the skip.
      final check = await checkInstructionSets(
        target: target,
        directory: nativeRoot.path,
        requireDisassembler: true,
        disassembler: (_) async => nativeArm64Listing,
      );

      expect(check.skipped, isTrue);
      expect(check.evidence, isEmpty);
    });
  });
}
