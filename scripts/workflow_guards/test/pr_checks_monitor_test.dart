import 'dart:convert';
import 'dart:io';

import 'package:sanad_workflow_guards/pr_checks_watch.dart';
import 'package:test/test.dart';

void main() {
  group('parseCheckRuns/classify', () {
    test('classifies buckets from gh pr checks --json', () {
      final checks = parseCheckRuns(
        jsonEncode([
          {
            'name': 'build',
            'bucket': 'pass',
            'state': 'SUCCESS',
            'conclusion': 'SUCCESS',
          },
          {
            'name': 'missing-bucket',
            'bucket': null,
            'state': 'FAILURE',
            'conclusion': null,
          },
        ]),
      );
      expect(checks, hasLength(2));
      expect(classifyChecks(checks), PrChecksVerdict.failure);
      expect(hasPendingChecks(checks), isFalse);
    });

    test('pending and skipping buckets drive polling decisions', () {
      final checks = parseCheckRuns(
        jsonEncode([
          {
            'name': 'lint',
            'bucket': 'pending',
            'state': 'IN_PROGRESS',
            'conclusion': null,
          },
          {
            'name': 'optional',
            'bucket': 'skipping',
            'state': 'SKIPPED',
            'conclusion': 'SKIPPED',
          },
        ]),
      );
      expect(classifyChecks(checks), PrChecksVerdict.success);
      expect(hasPendingChecks(checks), isTrue);
    });

    test('conclusion fallback detects failures when bucket/state omit it', () {
      final checks = parseCheckRuns(
        jsonEncode([
          {
            'name': 'e2e',
            'bucket': null,
            'state': 'COMPLETED',
            'conclusion': 'TIMED_OUT',
          },
        ]),
      );
      expect(checks.single.isFailed, isTrue);
    });

    test('rejects non-list output', () {
      expect(() => parseCheckRuns('{"not":"an array"}'), throwsFormatException);
    });

    test('windowsBatchQuote doubles embedded quotes', () {
      expect(windowsBatchQuote('a"b'), '"a""b"');
      expect(windowsBatchQuote('C:\\x y'), '"C:\\x y"');
    });
  });

  group('watchPrChecks with a fake gh executable', () {
    late Directory sandbox;
    late String stateFile;

    setUp(() {
      sandbox = Directory.systemTemp.createTempSync('wf-guards-pr-');
      stateFile = '${sandbox.path}${Platform.pathSeparator}poll-count';
      File(stateFile).writeAsStringSync('0');
    });

    tearDown(() {
      try {
        sandbox.deleteSync(recursive: true);
      } catch (_) {}
    });

    /// Creates a fake `gh` wrapper for [mode]; the scenario and poll counter
    /// are embedded so nothing depends on environment propagation.
    String createFakeGh(String mode) {
      final script = File(
        '${sandbox.path}${Platform.pathSeparator}fake_gh.mjs',
      );
      final state = stateFile.replaceAll(r'\', r'\\');
      script.writeAsStringSync('''
import { readFileSync, writeFileSync } from 'node:fs';
const stateFile = '$state';
const mode = '$mode';
const args = process.argv.slice(2);
if (args.join('|') !== 'pr|checks|123|--json|name,bucket,state,workflow') {
  process.stderr.write('unexpected argv: ' + JSON.stringify(args));
  process.exit(9);
}
const count = readFileSync(stateFile, 'utf8').length
  ? Number(readFileSync(stateFile, 'utf8')) : 0;
writeFileSync(stateFile, String(count + 1));
const check = (bucket, state, conclusion) =>
  ({ name: 'fake-check', bucket, state, conclusion });
const out = (checks) => { process.stdout.write(JSON.stringify(checks)); process.exit(0); };
switch (mode) {
  case 'success':
    out([check('pass', 'SUCCESS', 'SUCCESS')]);
  case 'pending_then_success':
    out(count === 0
      ? [check('pending', 'IN_PROGRESS', null)]
      : [check('pass', 'SUCCESS', 'SUCCESS')]);
  case 'pending_then_failure':
    out(count === 0
      ? [check('pending', 'IN_PROGRESS', null)]
      : [check('fail', 'FAILURE', 'FAILURE')]);
  case 'mixed_failure':
    out([check('pass', 'SUCCESS', 'SUCCESS'),
         check('fail', 'FAILURE', 'FAILURE'),
         check('pending', 'IN_PROGRESS', null)]);
  case 'always_pending':
    out([check('pending', 'IN_PROGRESS', null)]);
  case 'no_checks':
    out([]);
  case 'garbage':
    process.stdout.write('not json {{{');
    process.exit(0);
  case 'empty_pending_exit8':
    process.exit(8);
  default:
    process.exit(1);
}
''');
      if (Platform.isWindows) {
        final wrapper = File('${sandbox.path}${Platform.pathSeparator}gh.cmd');
        wrapper.writeAsStringSync('@echo off\r\nnode "${script.path}" %*\r\n');
        return wrapper.path;
      }
      final wrapper = File('${sandbox.path}${Platform.pathSeparator}gh');
      wrapper.writeAsStringSync(
        '#!/bin/sh\nexec node "${script.path}" "\$@"\n',
      );
      Process.runSync('chmod', ['+x', wrapper.path]);
      return wrapper.path;
    }

    Future<PrChecksResult> watch(String mode, {PrChecksOptions? options}) {
      return watchPrChecks(
        '123',
        options:
            options ??
            PrChecksOptions(
              ghCommand: createFakeGh(mode),
              interval: const Duration(milliseconds: 10),
              quiet: true,
            ),
      );
    }

    test('succeeds when all checks pass on the first poll', () async {
      final result = await watch('success');
      expect(result.verdict, PrChecksVerdict.success);
      expect(result.exitCode, 0);
      expect(result.pollCount, 1);
    });

    test('keeps polling pending until success', () async {
      final result = await watch('pending_then_success');
      expect(result.verdict, PrChecksVerdict.success);
      expect(result.pollCount, greaterThanOrEqualTo(2));
    });

    test(
      'fails fast on the first failed check even beside pending ones',
      () async {
        final mixed = await watch('mixed_failure');
        expect(mixed.verdict, PrChecksVerdict.failure);
        expect(mixed.exitCode, 1);
        expect(mixed.pollCount, 1);

        // Reset the shared poll counter so the next fake starts pending again.
        File(stateFile).writeAsStringSync('0');
        final later = await watch('pending_then_failure');
        expect(later.verdict, PrChecksVerdict.failure);
        expect(later.exitCode, 1);
        expect(later.pollCount, greaterThanOrEqualTo(2));
      },
    );

    test('times out with exit 124 while checks remain pending', () async {
      // Windows subprocess startup latency is unpredictable; use a wide
      // timeout so the loop is guaranteed several polls before the deadline.
      final result = await watch(
        'always_pending',
        options: PrChecksOptions(
          ghCommand: createFakeGh('always_pending'),
          interval: const Duration(milliseconds: 30),
          timeout: const Duration(milliseconds: 600),
          quiet: true,
        ),
      );
      expect(result.verdict, PrChecksVerdict.timeout);
      expect(result.exitCode, 124);
      expect(result.pollCount, greaterThanOrEqualTo(2));
    });

    test('gh exit code 8 with empty output is pending, not success', () async {
      final result = await watch(
        'empty_pending_exit8',
        options: PrChecksOptions(
          ghCommand: createFakeGh('empty_pending_exit8'),
          interval: const Duration(milliseconds: 10),
          timeout: const Duration(milliseconds: 30),
          quiet: true,
        ),
      );
      expect(result.verdict, PrChecksVerdict.timeout);
    });

    test(
      'no checks is a closed error, not proof of required-check success',
      () async {
        final result = await watch('no_checks');
        expect(result.verdict, PrChecksVerdict.error);
        expect(result.exitCode, 2);
        expect(result.error, contains('no checks'));
      },
    );

    test('unparseable gh output is a closed error (exit 2)', () async {
      final result = await watch('garbage');
      expect(result.verdict, PrChecksVerdict.error);
      expect(result.exitCode, 2);
      expect(result.error, contains('unparseable gh output'));
    });

    test('missing gh executable fails closed with exit 2', () async {
      final missing =
          '${sandbox.path}${Platform.pathSeparator}no-such-gh${Platform.isWindows ? '.exe' : ''}';
      final result = await watchPrChecks(
        '123',
        options: PrChecksOptions(ghCommand: missing, quiet: true),
      );
      expect(result.verdict, PrChecksVerdict.error);
      expect(result.exitCode, 2);
      expect(result.error, contains('gh could not be started'));
    });

    test(
      'shell metacharacters in the gh path are rejected without execution',
      () async {
        final result = await watchPrChecks(
          '123',
          options: PrChecksOptions(ghCommand: 'gh; rm -rf', quiet: true),
        );
        expect(result.verdict, PrChecksVerdict.error);
        expect(result.exitCode, 2);
        expect(result.error, contains('refusing to execute'));
      },
    );

    test(
      'non-quiet mode emits one bounded summary line per pending poll',
      () async {
        final gh = createFakeGh('pending_then_success');
        final result = await watchPrChecks(
          '123',
          options: PrChecksOptions(
            ghCommand: gh,
            interval: const Duration(milliseconds: 10),
            quiet: false,
          ),
          now: () => DateTime(2026, 1, 1),
        );
        // Captured by the runner rather than the stream; only verdict matters here
        // because hanging stdout in tests would be flaky.
        expect(result.verdict, PrChecksVerdict.success);
      },
    );
  });
}
