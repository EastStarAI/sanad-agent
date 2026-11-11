// The dictation digest's speed gate, measured in its own process.
//
// SHA-256 runs over every byte of every model install, and #164 paid for a
// native backend (CommonCrypto / libcrypto / BCrypt through `dart:ffi`) to take
// the per-byte cost off the download path: 196 MB/s and 5.25 CPU-s/GB in pure
// Dart against 2 578 MB/s and 0.41 CPU-s/GB native on the reference host. That
// claim is a product property, so it stays gated. It is a *ratio* though, and a
// ratio measured beside other suites — or always in the same order — charges the
// shorter arm for whatever the host did during it.
//
// That is not hypothetical. This case used to live in `stt_digest_test.dart`,
// and on `macos-15-intel` (run 42902755118, attempt 1) it measured 2.14 — native
// 556 ms against pure Dart 1193 ms for 64 MiB — while the native backend was
// selected and both arms returned the expected digest. The rest of that file
// still asserts every byte-for-byte, selection, context, and cleanup claim.
//
// The method is the one the CI-flakiness design review locked for this class of
// gate, and the one `stt_pipeline_cost_test.dart` already uses: one file per
// process (package:test gives every file its own), both arms warmed, five
// **alternating paired** trials so order bias cancels, and the **median** paired
// ratio as the verdict. Every trial prints a structured line so a lane log
// carries the numbers, not only red or green.
//
// The threshold does not move. 2.5x is the point below which the accelerator is
// not the thing being measured; a lane that cannot meet it with this method
// reports its numbers, and the bound is then decided explicitly — optimize the
// copy/call path, or approve a platform threshold with evidence. It is never
// lowered, skipped, or retried here.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as reference;
import 'package:sanad_agent/infrastructure/stt/stt_digest.dart';
import 'package:test/test.dart';

/// One artifact-sized buffer for every trial, so both arms hash the same bytes.
const int _bytes = 64 * 1024 * 1024;

/// The native path stages bytes through a 64 KiB window, so this is also the
/// feed size the download reader uses.
const int _chunk = 64 * 1024;

/// The shipped bound, unchanged: below it the accelerator is not what is being
/// measured.
const double _threshold = 2.5;

Uint8List _buffer() {
  final bytes = Uint8List(_bytes);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = (i * 37 + (i >> 8) * 11) & 0xFF;
  }
  return bytes;
}

/// Hashes [bytes] in download-shaped chunks and returns the hex digest.
///
/// `finish()` releases the native context; `close()` is the idempotent
/// owner-side release for every other path, so the gate leaves nothing behind in
/// a process it keeps for five trials.
String _hash(SttDigest Function() create, Uint8List bytes) {
  final digest = create();
  try {
    for (var offset = 0; offset < bytes.length; offset += _chunk) {
      final end = offset + _chunk > bytes.length
          ? bytes.length
          : offset + _chunk;
      digest.add(Uint8List.sublistView(bytes, offset, end));
    }
    return digest.finish();
  } finally {
    digest.close();
  }
}

/// One arm's timed run: the digest work only, never the assertion around it.
({int micros, String hex}) _time(SttDigest Function() create, Uint8List bytes) {
  final stopwatch = Stopwatch()..start();
  final hex = _hash(create, bytes);
  stopwatch.stop();
  return (micros: stopwatch.elapsedMicroseconds, hex: hex);
}

void main() {
  test('native SHA-256 stays 2.5x the pure-Dart path', () {
    if (!sttNativeDigestAvailable) {
      // A host with no CommonCrypto/libcrypto/bcrypt is a supported host and
      // uses the pure-Dart path; the unit suite's parity group covers it there.
      stdout.writeln(
        'stt-digest-cost skipped=no-native-digest '
        'platform=${Platform.operatingSystem}',
      );
      markTestSkipped('no OS SHA-256 on this host');
      return;
    }
    // A ratio against a silent fallback would measure nothing, so restate the
    // selection claim in the process that measures it.
    final shipped = createSttDigest();
    expect(
      shipped,
      isNot(isA<PureDartSttDigest>()),
      reason: 'the factory fell back although the OS implementation loaded',
    );
    shipped.close();

    final buffer = _buffer();
    final expected = reference.sha256.convert(buffer).toString();

    // Warm both arms: the OS library load and FFI lookup, the pure-Dart JIT
    // path, and the first touch of every page in the buffer.
    final implementations = <(String, SttDigest Function())>[
      ('pure Dart', PureDartSttDigest.new),
      ('native', createSttDigest),
    ];
    for (final (label, create) in implementations) {
      expect(
        _time(create, buffer).hex,
        expected,
        reason: '$label warm-up digest',
      );
    }

    const int trials = 5;
    final ratios = <double>[];
    for (var trial = 1; trial <= trials; trial++) {
      // Alternating order: whichever arm runs first absorbs the drift and the
      // other's warm-up, so the pair — not the run — is the unit of measurement.
      final nativeFirst = trial.isOdd;
      late final ({int micros, String hex}) pure;
      late final ({int micros, String hex}) native;
      if (nativeFirst) {
        native = _time(createSttDigest, buffer);
        pure = _time(PureDartSttDigest.new, buffer);
      } else {
        pure = _time(PureDartSttDigest.new, buffer);
        native = _time(createSttDigest, buffer);
      }
      // Equal digests are part of the measurement: a faster wrong answer is not
      // this property, and a fallback would make the ratio meaningless.
      expect(pure.hex, expected, reason: 'trial $trial pure-Dart digest');
      expect(native.hex, expected, reason: 'trial $trial native digest');
      final ratio = pure.micros / math.max(native.micros, 1);
      ratios.add(ratio);
      stdout.writeln(
        'stt-digest-cost trial=$trial/$trials '
        'order=${nativeFirst ? 'native-first' : 'pure-first'} '
        'pure_us=${pure.micros} native_us=${native.micros} '
        'ratio=${ratio.toStringAsFixed(3)}',
      );
    }

    final sorted = <double>[...ratios]..sort();
    final median = sorted[trials ~/ 2];
    final rendered = ratios.map((double r) => r.toStringAsFixed(3)).join(',');
    stdout.writeln(
      'stt-digest-cost median=${median.toStringAsFixed(3)} trials=$rendered '
      'bytes=$_bytes platform=${Platform.operatingSystem} '
      'threshold=$_threshold',
    );
    expect(
      median,
      greaterThanOrEqualTo(_threshold),
      reason:
          'native SHA-256 ran at ${median.toStringAsFixed(2)}x the pure-Dart '
          'path (median of $trials alternating pairs over 64 MiB, trials: '
          '$rendered)',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
