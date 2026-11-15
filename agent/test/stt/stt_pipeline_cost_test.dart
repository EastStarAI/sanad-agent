// The dictation write pipeline's cost gate, measured in its own process.
//
// It is deliberately **not** part of `stt_download_pipeline_test.dart`. What this
// asserts is a *ratio*, and a ratio measured beside other suites — or always in
// the same order — charges one arm for the other's contention and warm-up. The
// `windows-2025` lane measured the isolate at 2.78x the in-process cost in that
// shape (1232 ms against 443 ms for 64 MiB) while the same code measured ~1x on
// macOS, which is a harness fact, not a pipeline fact.
//
// The method is the one the CI-flakiness design review locked for this class of
// gate: one file per process (package:test gives every file its own), both arms
// warmed, five **alternating paired** trials so order bias cancels, and the
// **median** paired ratio as the verdict. Each trial prints a structured line so
// a lane log carries the numbers, not just red or green.
//
// What it guards is the shape, not the win: the win is against network latency
// (29.1 -> 61.2 MB/s measured on the reference host), which a loopback test
// cannot reproduce. The threshold stays 0.5 — the isolate may cost up to twice the
// in-process sink — and a platform that cannot meet it is reported with its
// numbers and decided explicitly; it is never lowered here.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sanad_agent/infrastructure/stt/stt_download_pipeline.dart';
import 'package:test/test.dart';

const int _chunk = 64 * 1024;

Uint8List _block() {
  final bytes = Uint8List(_chunk);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = (i * 37) & 0xFF;
  }
  return bytes;
}

void main() {
  test('the isolate hop stays inside twice the in-process sink', () async {
    final dir = Directory.systemTemp.createTempSync('stt-pipeline-cost-');
    addTearDown(() => dir.deleteSync(recursive: true));
    // One window short of a chunk: neither arm forces page cache out mid-transfer,
    // so this compares the isolate hop and not a 64 MiB fsync, which is disk
    // latency that would swamp it. The flush cadence has its own tests.
    const int total = kSttFlushWindowBytes - _chunk;
    final block = _block();

    Future<int> run({required bool isolate, required int trial}) async {
      final file = File('${dir.path}/cost-${isolate ? 'i' : 'p'}-$trial.bin');
      final stopwatch = Stopwatch()..start();
      final pipeline = isolate
          ? await IsolateWritePipeline.open(file, FileMode.write)
          : await inProcessPipeline()(file, FileMode.write);
      for (var written = 0; written < total; written += block.length) {
        await pipeline.add(block);
      }
      await pipeline.drain();
      await pipeline.close();
      stopwatch.stop();
      expect(
        file.lengthSync(),
        total,
        reason: 'both arms must write the same bytes for the ratio to mean this',
      );
      file.deleteSync();
      return stopwatch.elapsedMicroseconds;
    }

    // Warm both arms: the isolate spawn, the page cache, and the code paths.
    await run(isolate: true, trial: 0);
    await run(isolate: false, trial: 0);

    const int trials = 5;
    final ratios = <double>[];
    for (var trial = 1; trial <= trials; trial++) {
      // Alternating order: whichever arm runs first absorbs the drift and the
      // other's warm-up, so the pair — not the run — is the unit of measurement.
      final isolateFirst = trial.isOdd;
      late final int isolateUs;
      late final int inProcessUs;
      if (isolateFirst) {
        isolateUs = await run(isolate: true, trial: trial);
        inProcessUs = await run(isolate: false, trial: trial);
      } else {
        inProcessUs = await run(isolate: false, trial: trial);
        isolateUs = await run(isolate: true, trial: trial);
      }
      final ratio = inProcessUs / math.max(isolateUs, 1);
      ratios.add(ratio);
      stdout.writeln(
        'stt-pipeline-cost trial=$trial/$trials '
        'order=${isolateFirst ? 'isolate-first' : 'in-process-first'} '
        'isolate_us=$isolateUs in_process_us=$inProcessUs '
        'ratio=${ratio.toStringAsFixed(3)}',
      );
    }

    final sorted = <double>[...ratios]..sort();
    final median = sorted[trials ~/ 2];
    final rendered = ratios.map((double r) => r.toStringAsFixed(3)).join(',');
    stdout.writeln(
      'stt-pipeline-cost median=${median.toStringAsFixed(3)} trials=$rendered '
      'platform=${Platform.operatingSystem} threshold=0.5',
    );
    expect(
      median,
      greaterThan(0.5),
      reason:
          'the isolate pipeline costs ${(1 / median).toStringAsFixed(2)}x the '
          'in-process sink (median of $trials alternating pairs for 64 MiB, '
          'trials: $rendered)',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
