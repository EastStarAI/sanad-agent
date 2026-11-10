import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/infrastructure/stt/stt_native_platform.dart';
import 'package:sanad_agent/infrastructure/stt/whispercpp_bindings.dart';
import 'package:test/test.dart';

import '../../tool/stt_native_runtime.dart';

/// The tool and `tool/build_whispercpp.sh` are two halves of one argument
/// contract. A mismatch here is invisible on Apple Silicon (`arm64` happens to
/// equal the CMake spelling) and fatal on Intel, so it is asserted directly.
///
/// The script's plan mode runs the same validation and the same architecture
/// mapping as a real build and then exits before touching a compiler or the
/// filesystem, which keeps this test host-independent.
void main() {
  final windows = Platform.isWindows;
  final bash = windows
      ? null
      : Process.runSync('bash', ['--version']).exitCode == 0;

  test('the tool builds the vector the POSIX script accepts', () {
    if (windows || bash != true) {
      markTestSkipped('bash is required to exercise the POSIX builder script');
      return;
    }
    final target = SttNativeTarget.tryCurrent();
    if (target == null) {
      markTestSkipped('this host has no native dictation target');
      return;
    }

    final arguments = sttPosixBuilderArguments(
      target: target,
      whisperSource: Directory.current.path,
      outputDirectory: 'native/.plan-only',
    );
    final result = Process.runSync(
      'bash',
      arguments,
      environment: {'SANAD_BUILD_PLAN_ONLY': '1'},
    );

    expect(result.exitCode, 0, reason: '${result.stderr}');
    final plan = <String, String>{
      for (final line in LineSplitter().convert(result.stdout as String))
        if (line.contains('=')) line.split('=').first: line.split('=').last,
    };
    expect(plan['build_plan_arch'], target.cpuName);
    expect(plan['build_plan_out'], 'native/.plan-only');
    // The CMake spelling is the script's job: `x64` must arrive as `x86_64`.
    if (target.os == SttNativeOs.macos) {
      expect(
        plan['build_plan_cmake_arch'],
        target.cpu == SttNativeCpu.x64 ? 'x86_64' : 'arm64',
      );
      expect(
        plan['build_plan_deploy_target'],
        SttNativeTarget.macosMinimumDeploymentTarget,
      );
    } else {
      expect(plan['build_plan_metal'], 'OFF');
    }
  });

  test('the script refuses the other architecture', () {
    if (windows || bash != true) {
      markTestSkipped('bash is required to exercise the POSIX builder script');
      return;
    }
    final target = SttNativeTarget.tryCurrent();
    if (target == null) {
      markTestSkipped('this host has no native dictation target');
      return;
    }
    final other = target.cpu == SttNativeCpu.x64 ? 'arm64' : 'x64';
    final result = Process.runSync('bash', [
      'tool/build_whispercpp.sh',
      Directory.current.path,
      'native/.plan-only',
      other,
      SttNativeTarget.macosMinimumDeploymentTarget,
    ], environment: {'SANAD_BUILD_PLAN_ONLY': '1'});

    expect(result.exitCode, isNot(0));
    expect(result.stderr as String, contains('Refusing to build $other'));
  });

  test('the script rejects the CMake spelling on macOS', () {
    if (windows || bash != true) {
      markTestSkipped('bash is required to exercise the POSIX builder script');
      return;
    }
    if (!Platform.isMacOS) {
      // Linux takes no architecture argument at all, so there is nothing to
      // reject there.
      markTestSkipped('only the macOS path maps a tag-style architecture');
      return;
    }

    final result = Process.runSync('bash', [
      'tool/build_whispercpp.sh',
      Directory.current.path,
      'native/.plan-only',
      'x86_64',
      SttNativeTarget.macosMinimumDeploymentTarget,
    ], environment: {'SANAD_BUILD_PLAN_ONLY': '1'});

    expect(result.exitCode, isNot(0));
    expect(result.stderr as String, contains('x86_64'));
  });

  test('the POSIX builder links every shipped Linux library self-relatively', () {
    // The shim's own rpath is not enough: glibc resolves `libwhisper.so.1`'s
    // DT_NEEDED through that library's RUNPATH, so an arm64 install shipped a
    // runtime that could not find its ggml siblings. Every library the script
    // copies out of the build tree has to carry `$ORIGIN`, and a restored build
    // cache must not be reused without it.
    final script = File('tool/build_whispercpp.sh').readAsStringSync();
    expect(script, contains(r"-Wl,-rpath,'$ORIGIN'"));
    expect(script, contains(r"-DCMAKE_INSTALL_RPATH='$ORIGIN'"));
    expect(script, contains('-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON'));

    // A cached tree is only relinked when its link command is re-run, and the
    // Makefile generator compares timestamps only, so the guard has to discard a
    // tree that does not record the contract before cmake configures.
    final guard = script.lastIndexOf(r'CMAKE_INSTALL_RPATH:STRING=$ORIGIN');
    final configure = script.lastIndexOf('cmake -B build');
    expect(guard, isNonNegative);
    expect(configure, isNonNegative);
    expect(
      guard,
      lessThan(configure),
      reason: 'the stale-cache guard must run before cmake configures',
    );
  });

  test('every POSIX build is portable instead of tuned to the build host', () {
    // `GGML_NATIVE=ON` is ggml's default and compiles `-march=native`, so the
    // shipped libraries require exactly the build runner's CPU. v1.0.22 shipped
    // that and trapped with SIGILL on an older arm64 host. The flag is the
    // contract; the configure line is where it has to reach ggml.
    final script = File('tool/build_whispercpp.sh').readAsStringSync();
    expect(script, contains('ggml_native=OFF'));
    expect(
      script,
      contains(r'-DGGML_NATIVE="$ggml_native"'),
      reason: 'both configure branches must pass the portable baseline',
    );
    expect(
      r'-DGGML_NATIVE="$ggml_native"'.allMatches(script).length,
      2,
      reason: 'the macOS and Linux branches both configure ggml',
    );
    // Linux arm64 is pinned to an explicit floor instead of inheriting whatever
    // the runner's compiler defaults to: Armv8.2-A with the dot-product and
    // half-precision arithmetic the release host proves.
    expect(script, contains('armv8.2-a+dotprod+fp16'));
    expect(script, contains('-DGGML_CPU_ARM_ARCH='));
    // A restored tree that recorded the native baseline must be discarded, or
    // the Makefile generator reuses libraries compiled for the build runner.
    expect(script, contains(r'GGML_NATIVE:BOOL=$ggml_native'));
    expect(
      script.lastIndexOf(r'GGML_NATIVE:BOOL=$ggml_native'),
      lessThan(script.lastIndexOf('cmake -B build')),
      reason: 'the portable-baseline guard must run before cmake configures',
    );
  });

  test('the Linux arm64 lane resolves the documented portable floor', () {
    // `uname` decides which branch the script builds, so a fake one executes the
    // Linux arm64 path on any host: the value below is what the release lane
    // configures, and it is the widest floor the release host proves.
    if (windows || bash != true) {
      markTestSkipped('bash is required to exercise the POSIX builder script');
      return;
    }
    final shim = Directory.systemTemp.createTempSync('uname-shim-');
    addTearDown(() {
      if (shim.existsSync()) shim.deleteSync(recursive: true);
    });
    for (final entry in [
      (
        system: 'Linux',
        machine: 'aarch64',
        arch: 'arm64',
        floor: 'armv8.2-a+dotprod+fp16',
      ),
      (system: 'Linux', machine: 'x86_64', arch: 'x64', floor: ''),
      (system: 'Darwin', machine: 'arm64', arch: 'arm64', floor: ''),
    ]) {
      File('${shim.path}/uname').writeAsStringSync(
        '#!/bin/sh\n'
        'case "\$1" in\n'
        '  -m) echo "${entry.machine}" ;;\n'
        '  *) echo "${entry.system}" ;;\n'
        'esac\n',
      );
      Process.runSync('chmod', ['+x', '${shim.path}/uname']);
      final result = Process.runSync(
        'bash',
        [
          'tool/build_whispercpp.sh',
          Directory.current.path,
          'native/.plan-only',
          entry.arch,
        ],
        environment: {
          'SANAD_BUILD_PLAN_ONLY': '1',
          'PATH': '${shim.path}:${Platform.environment['PATH']}',
        },
      );

      expect(result.exitCode, 0, reason: '${result.stderr}');
      final plan = <String, String>{
        for (final line in LineSplitter().convert(result.stdout as String))
          if (line.contains('='))
            line.substring(0, line.indexOf('=')):
                line.substring(line.indexOf('=') + 1),
      };
      expect(
        plan['build_plan_ggml_native'],
        'OFF',
        reason: '${entry.system}/${entry.machine} must not be native',
      );
      expect(
        plan['build_plan_ggml_arm_arch'],
        entry.floor,
        reason: '${entry.system}/${entry.machine} arm64 floor',
      );
    }
  });

  test('the whisper build cache is invalidated for the portable baseline', () {
    // The libraries are reused byte-for-byte from a restored `build/` tree, so a
    // key that does not change ships the old `-march=native` bytes again.
    for (final path in [
      '../.github/workflows/ci.yml',
      '../.github/workflows/release.yml',
    ]) {
      final workflow = File(path).readAsStringSync();
      expect(workflow, contains('whisper-build-v4-'), reason: path);
      expect(
        workflow,
        isNot(contains('whisper-build-v3-')),
        reason: '$path must not restore a tree built with -march=native',
      );
    }
  });

  test('the Windows vector carries the tag-style architecture', () {
    final arguments = sttWindowsBuilderArguments(
      target: SttNativeTarget.windowsX64,
      whisperSource: r'C:\src\whisper.cpp',
      outputDirectory: r'native\windows-x64.tmp',
    );

    expect(arguments, [
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      'tool/build_whispercpp.ps1',
      r'C:\src\whisper.cpp',
      r'native\windows-x64.tmp',
      '-Arch',
      'x64',
    ]);
    expect(arguments, isNot(contains('x86_64')));
  });

  test('the Windows builder discards a CMake cache for another platform', () {
    // A restored CI cache (or a developer's earlier build) can carry a
    // CMakeCache configured without the requested platform, and CMake then
    // refuses to reconfigure instead of reusing the tree. The builder must
    // discard such a tree itself, because no workflow key can guarantee it.
    final script = File('tool/build_whispercpp.ps1').readAsStringSync();
    expect(script, contains('CMAKE_GENERATOR_PLATFORM'));
    expect(
      script,
      contains(r'Remove-Item -Recurse -Force -LiteralPath $buildDir'),
    );
    final guard = script.indexOf('CMAKE_GENERATOR_PLATFORM');
    final configure = script.indexOf(r'cmake -B build');
    expect(guard, isNonNegative);
    expect(
      guard,
      lessThan(configure),
      reason: 'the stale-cache guard must run before cmake configures',
    );
  });

  test('the Windows x64 build is portable instead of host-tuned', () {
    // ggml defaults to `GGML_NATIVE=ON`, which lets MSVC pick the host's
    // instruction set: the same class of defect v1.0.22 shipped on arm64. MSVC
    // has no portable ggml mode on ARM at all (ggml rejects `GGML_NATIVE=OFF`
    // there), so only the x64 slice can be — and is — produced portable.
    final script = File('tool/build_whispercpp.ps1').readAsStringSync();
    expect(
      script,
      contains(r"$ggmlNative = if ($Arch -eq 'x64') { 'OFF' } else { 'ON' }"),
      reason: 'x64 must configure GGML_NATIVE=OFF',
    );
    expect(script, contains(r'-DGGML_NATIVE=$ggmlNative'));
    // A restored tree built with the native baseline is discarded like one
    // configured for another platform: the generators compare timestamps only.
    expect(script, contains('GGML_NATIVE:BOOL'));
    expect(
      script.indexOf(r'GGML_NATIVE:BOOL'),
      lessThan(script.indexOf(r'cmake -B build')),
      reason: 'the portable-baseline guard must run before cmake configures',
    );
  });

  test('the Windows builder stages exactly the DLLs the loader preloads', () {
    // The loader registers each sibling DLL before opening the shim, because
    // Windows does not search the shim's directory for its imports. If the
    // builder stops staging one of these, the load fails at runtime instead.
    final script = File('tool/build_whispercpp.ps1').readAsStringSync();
    for (final name in WhisperCppLibrary.windowsRuntimeLibraries) {
      expect(script, contains(name), reason: '$name must be staged');
    }
    // Order is the dependency graph: ggml.dll and whisper.dll import
    // ggml-base, so preloading them first reintroduces the same error 126.
    final libraries = WhisperCppLibrary.windowsRuntimeLibraries;
    expect(
      libraries.indexOf('ggml-base.dll'),
      lessThan(libraries.indexOf('ggml.dll')),
    );
    expect(
      libraries.indexOf('ggml-base.dll'),
      lessThan(libraries.indexOf('whisper.dll')),
    );
    expect(
      libraries.indexOf('ggml.dll'),
      lessThan(libraries.indexOf('whisper.dll')),
    );
  });

  test('the shim exports every symbol the FFI bindings look up', () {
    // POSIX exports these by default; MSVC exports nothing without a marker, so
    // an unmarked shim builds and stages cleanly on Windows and then fails to
    // load with "procedure could not be found" (error 127).
    final source = File('native/whispercpp/sanad_whisper.c').readAsStringSync();
    expect(source, contains('__declspec(dllexport)'));
    for (final symbol in [
      'sanad_whisper_load',
      'sanad_whisper_free',
      'sanad_whisper_audio_ctx',
      'sanad_whisper_run',
      'sanad_whisper_system_info',
    ]) {
      expect(
        RegExp('SANAD_WHISPER_EXPORT[^;]*\\b$symbol\\b').hasMatch(source),
        isTrue,
        reason: '$symbol must be exported explicitly',
      );
    }
  });

  test('every decode owns a fresh whisper state over shared weights', () {
    final source = File('native/whispercpp/sanad_whisper.c').readAsStringSync();
    expect(source, contains('whisper_init_from_file_with_params_no_state'));
    expect(source, contains('whisper_init_state(ctx)'));
    expect(source, contains('whisper_full_with_state(ctx, state'));
    expect(source, contains('whisper_full_n_segments_from_state(state)'));
    expect(
      source,
      contains('whisper_full_get_segment_text_from_state(state, i)'),
    );
    expect(source, contains('cleanup:\n  whisper_free_state(state);'));
    expect(
      RegExp(r'\bwhisper_full\(ctx').hasMatch(source),
      isFalse,
      reason: 'the context must not retain an implicit decode state',
    );
  });

  test('the shim applies the decode window and the greedy candidate bound', () {
    // The C is compiled only in the native lanes, which do no decode, so this is
    // where the two measured decode parameters are kept wired: the utterance
    // window the daemon computes (with 0 meaning "whisper's own") and one
    // candidate per temperature tier.
    final source = File('native/whispercpp/sanad_whisper.c').readAsStringSync();
    expect(
      RegExp(
        r'if \(audio_ctx > 0\)[\s\S]*?params\.audio_ctx = ',
      ).hasMatch(source),
      isTrue,
      reason: 'a positive window must reach whisper_full_params',
    );
    expect(source, contains('params.audio_ctx = 0;'));
    expect(source, contains('params.greedy.best_of = 1;'));
    expect(
      source,
      contains('whisper_n_audio_ctx(ctx)'),
      reason: 'the shim must clamp to the loaded model, not a constant',
    );
  });
}
