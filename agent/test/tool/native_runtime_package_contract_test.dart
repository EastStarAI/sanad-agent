import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/infrastructure/stt/stt_native_platform.dart';
import 'package:test/test.dart';

import '../../tool/stt_native_archive.dart';

/// The release has to ship the native dictation runtime **with the Agent**, not
/// in a side artifact the manifest ignores (audit D9).
///
/// Three places must agree for that to be true, so each one is asserted here:
/// the release contract that declares the archive, the tool that writes it with
/// the packaged layout, and the installers that place it beside the executable.
void main() {
  final contract =
      jsonDecode(File('../release/release-contract.json').readAsStringSync())
          as Map<String, dynamic>;
  final version = contract['version'] as String;
  final artifacts = (contract['artifacts'] as List)
      .cast<Map<String, dynamic>>();

  List<Map<String, dynamic>> runtimesFor(String platform, String architecture) {
    return artifacts
        .where(
          (artifact) =>
              artifact['component'] == 'agent-runtime' &&
              artifact['platform'] == platform &&
              artifact['architecture'] == architecture,
        )
        .toList();
  }

  group('release contract', () {
    test('every packaged Agent platform declares one runtime archive', () {
      final agents = artifacts
          .where((artifact) => artifact['component'] == 'agent')
          .toList();
      expect(agents, isNotEmpty);
      for (final agent in agents) {
        final platform = agent['platform'] as String;
        final architecture = agent['architecture'] as String;
        final runtimes = runtimesFor(platform, architecture);
        expect(
          runtimes,
          hasLength(1),
          reason: 'expected one agent-runtime for $platform-$architecture',
        );
        final runtime = runtimes.single;
        expect(runtime['format'], 'tar.gz');
        expect(runtime['public'], isTrue);
        expect(
          runtime['filename'],
          'sanad-agent-runtime-$version-$platform-$architecture.tar.gz',
        );
        // The declared name carries the release version, so the contract
        // validator accepts it and a version bump rewrites it with everything
        // else.
        expect((runtime['filename'] as String).contains(version), isTrue);
      }
    });

    test('the declared runtime tag is the directory the loader searches', () {
      for (final target in SttNativeTarget.values) {
        final runtimes = runtimesFor(target.os.name, target.cpu.name);
        if (runtimes.isEmpty) continue;
        expect(runtimes, hasLength(1));
        expect(runtimes.single['filename'], contains('-${target.tag}.tar.gz'));
        expect(target.nativeDirectory, target.tag);
      }
    });

    test('the Agent executable stays a single file for the Client installer', () {
      // The Client bootstrap installer selects `component: agent` and expects
      // one downloadable file; declaring the runtime separately is what keeps
      // that contract intact.
      final agents = artifacts.where(
        (artifact) =>
            artifact['component'] == 'agent' && artifact['public'] == true,
      );
      for (final agent in agents) {
        expect(agent['format'], 'executable');
      }
    });
  });

  group('packaged layout', () {
    test('archive members live under native/<tag>/', () {
      const target = SttNativeTarget.macosX64;
      final bytes = buildDeterministicTarGz({
        'native/${target.nativeDirectory}/libsanad_whisper.dylib': List<int>.filled(8, 7),
        'native/${target.nativeDirectory}/libwhisper.1.dylib': List<int>.filled(8, 9),
      });
      final tar = GZipCodec().decode(bytes);
      final names = <String>[];
      var offset = 0;
      while (offset + 512 <= tar.length) {
        final block = tar.sublist(offset, offset + 512);
        final name = utf8
            .decode(block.sublist(0, 100))
            .replaceAll('\u0000', '')
            .trim();
        if (name.isEmpty) break;
        names.add(name);
        final sizeField = utf8
            .decode(block.sublist(124, 136))
            .replaceAll('\u0000', '')
            .trim();
        final size = int.parse(sizeField.isEmpty ? '0' : sizeField, radix: 8);
        offset += 512 + ((size + 511) ~/ 512) * 512;
      }
      expect(names, [
        'native/macos-x64/libsanad_whisper.dylib',
        'native/macos-x64/libwhisper.1.dylib',
      ]);
    });
  });

  group('installers', () {
    test('both installers consume the declared archive', () {
      final posix = File('../scripts/install.sh').readAsStringSync();
      final windows = File('../scripts/install.ps1').readAsStringSync();
      for (final script in [posix, windows]) {
        expect(script, contains('agent-runtime'));
        expect(script, contains('native/'));
        expect(script, contains('Native runtime SHA-256 verification failed'));
      }
      expect(posix, contains(r'native/$RUNTIME_TAG'));
      expect(
        posix,
        contains(r'sanad-agent-runtime-*-"$RUNTIME_TAG".tar.gz'),
      );
      expect(windows, contains('native/windows-x64'));
      expect(windows, contains('Native runtime archive contains a file outside'));
    });
  });

  group('release workflow', () {
    test('stages the runtime into the Agent payload and stays required', () {
      final workflow = File('../.github/workflows/release.yml').readAsStringSync();
      expect(workflow, contains('SANAD_STT_REQUIRE_NATIVE'));
      expect(workflow, contains('ensure_native_stt.dart --verify'));
      expect(workflow, contains('--stage ../dist'));
      expect(workflow, contains('--archive-name'));
      expect(workflow, contains('--expect-target'));
      expect(
        workflow,
        contains(
          r'ARCHIVE_NAME: sanad-agent-runtime-${{ needs.validate.outputs.artifact_version }}-${{ matrix.platform }}-${{ matrix.architecture }}.tar.gz',
        ),
      );
      // The standalone job that produced an artifact the manifest ignored is
      // gone; a release cannot pass while the runtime is missing.
      expect(workflow, isNot(contains('agent-native-runtime:')));
      expect(workflow, isNot(contains('stt-runtime-')));
      expect(workflow, isNot(contains('continue-on-error')));
    });

    test('the Agent job keeps its budget and a native shell per platform', () {
      final workflow = File('../.github/workflows/release.yml').readAsStringSync();
      final start = workflow.indexOf('\n  agent:\n');
      final end = workflow.indexOf('\n  client-linux-web:\n');
      expect(start, isNonNegative);
      expect(end, greaterThan(start));
      final job = workflow.substring(start, end);

      // No measurement justifies raising the job budget, so it stays 35.
      expect(job, contains('timeout-minutes: 35'));
      // Windows has only ever run fvm through PowerShell in this job; the
      // runner's fvm entry point is a .bat shim, and Git-Bash `tee`/`sed`
      // semantics were never verified on that lane.
      expect(job, isNot(contains('tee ')));
    });

    test('no bash step can execute on a Windows runner', () {
      for (final path in [
        '../.github/workflows/release.yml',
        '../.github/workflows/ci.yml',
      ]) {
        expect(
          windowsBashSteps(File(path).readAsStringSync()),
          isEmpty,
          reason: '$path runs bash on a Windows-capable job',
        );
      }
    });

    test('every Windows-reachable step keeps a pwsh twin', () {
      final release = File('../.github/workflows/release.yml').readAsStringSync();
      final ci = File('../.github/workflows/ci.yml').readAsStringSync();

      // The lanes W5 repaired: the same command must exist under both shells,
      // so the guard above can see and keep a Windows twin in place.
      for (final name in [
        'Load the packaged runtime in a real process',
      ]) {
        expect(_namedSteps(release, name), 2, reason: 'release.yml: $name');
      }
      for (final name in [
        'Build the native runtime for this runner',
        'Verify the installed runtime and its manifest entry',
        'Stage and archive the runtime for packaging',
      ]) {
        expect(_namedSteps(ci, name), 2, reason: 'ci.yml: $name');
      }
    });
  });
}

int _namedSteps(String workflow, String name) =>
    RegExp('- name: ${RegExp.escape(name)}\\n').allMatches(workflow).length;

/// Every `shell: bash` run step in a job that can execute on Windows.
///
/// A job is Windows-capable when its header (everything before `steps:`) names
/// a Windows runner image, so an unguarded step cannot hide behind a job-level
/// matrix. Only runner names count — a `needs:` entry such as `client-windows`
/// does not make an Ubuntu job Windows-capable. A step is acceptable only when
/// its own guard excludes Windows using one of [windowsExclusions]; any other
/// form fails so a new lane has to state its platform boundary explicitly.
List<String> windowsBashSteps(String workflow) {
  final violations = <String>[];
  final windowsRunner = RegExp(r'windows-(?:20\d\d|latest)');
  for (final entry in _jobs(workflow).entries) {
    final stepsAt = entry.value.indexOf('    steps:');
    if (stepsAt < 0) continue;
    final header = entry.value.substring(0, stepsAt);
    if (!windowsRunner.hasMatch(header)) continue;
    for (final step in entry.value.substring(stepsAt).split('      - ').skip(1)) {
      if (!step.contains('shell: bash')) continue;
      final beforeRun = step.split('run:').first;
      if (windowsExclusions.any((form) => beforeRun.contains(form))) continue;
      final name =
          RegExp(r'name: (.+)').firstMatch(step)?.group(1)?.trim() ?? step.trim();
      violations.add('${entry.key}: $name');
    }
  }
  return violations;
}

/// The guard forms this repository uses to keep a step off Windows.
const windowsExclusions = [
  "runner.os != 'Windows'",
  "matrix.platform != 'windows'",
  "runner.os == 'macOS'",
  "runner.os == 'Linux'",
  "matrix.platform == 'macos'",
  "matrix.platform == 'linux'",
];

Map<String, String> _jobs(String workflow) {
  final jobs = <String, String>{};
  String? current;
  final buffer = StringBuffer();
  for (final line in const LineSplitter().convert(workflow)) {
    final job = RegExp(r'^  ([A-Za-z0-9_-]+):$').firstMatch(line);
    if (job != null) {
      if (current != null) jobs[current] = buffer.toString();
      current = job.group(1)!;
      buffer.clear();
      continue;
    }
    if (current != null) buffer.writeln(line);
  }
  if (current != null) jobs[current] = buffer.toString();
  return jobs;
}
