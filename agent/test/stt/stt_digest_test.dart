// The digest is on the download's critical path, so it is now a native call.
//
// Two properties have to hold before that is safe to ship, and they are
// different kinds of claim:
//
// 1. **Same bytes, same answer.** The native path must be byte-identical to
//    `package:crypto` for every chunking the reader can produce. A wrong
//    checksum does not degrade a download, it fails every install, so this is
//    asserted across every block boundary the SHA-256 padding cares about
//    (0, 1, 63, 64, 65, 4095, 4096, 4097) and across three feeding patterns.
// 2. **The fast path is actually taken.** Measuring only the shipped factory
//    cannot tell a working accelerator from a silent fallback, so the factory's
//    implementation is asserted on a host that has an OS backend. How fast that
//    path is belongs to a *ratio*, and a ratio measured beside other suites
//    charges the shorter arm for whatever the host did during it: this file's
//    own copy of it measured 2.14 on `macos-15-intel` while the host was busy.
//    The speed claim therefore has its own process
//    (`stt_digest_cost_test.dart`), and this file keeps the byte-for-byte and
//    selection claims that no amount of host load can change.

import 'dart:typed_data';

import 'package:crypto/crypto.dart' as reference;
import 'package:sanad_agent/infrastructure/stt/stt_digest.dart';
import 'package:test/test.dart';

/// Sizes that sit on and beside every alignment SHA-256's padding cares about.
const List<int> _sizes = <int>[0, 1, 63, 64, 65, 127, 128, 4095, 4096, 4097];

String _hex(List<int> bytes) => reference.sha256.convert(bytes).toString();

Uint8List _pattern(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i * 37 + (i >> 8) * 11) & 0xFF;
  }
  return bytes;
}

String _feed(SttDigest digest, Uint8List bytes, int chunk) {
  for (var offset = 0; offset < bytes.length; offset += chunk) {
    final end = offset + chunk > bytes.length ? bytes.length : offset + chunk;
    digest.add(Uint8List.sublistView(bytes, offset, end));
  }
  return digest.finish();
}

void main() {
  final List<(String, SttDigest Function())> implementations =
      <(String, SttDigest Function())>[
        ('pure Dart', PureDartSttDigest.new),
        ('shipped factory', createSttDigest),
      ];

  group('digest parity with package:crypto', () {
    for (final (label, create) in implementations) {
      test('$label matches for every size and chunking', () {
        for (final size in _sizes) {
          final bytes = _pattern(size);
          final expected = _hex(bytes);
          for (final chunk in <int>[size == 0 ? 1 : size, 1, 7, 333, 4096]) {
            expect(
              _feed(create(), bytes, chunk),
              expected,
              reason: '$label diverged at $size bytes fed in $chunk-byte chunks',
            );
          }
        }
      });
    }

    test('a digest fed nothing is the digest of the empty string', () {
      for (final (label, create) in implementations) {
        expect(create().finish(), _hex(const <int>[]), reason: label);
      }
    });

    test('one artifact-sized stream agrees across both paths', () {
      final bytes = _pattern(3 * 1024 * 1024 + 17);
      final expected = _hex(bytes);
      for (final (label, create) in implementations) {
        expect(_feed(create(), bytes, 64 * 1024), expected, reason: label);
      }
    });

    test('a chunk larger than the native window is hashed whole', () {
      // The reader does not bound its chunk size: a socket read, a local file
      // re-read after a resume, and a server that flushes once all hand over
      // more than 64 KiB at a time. The native path stages bytes through a
      // fixed window, so a chunk wider than that window must be split, not
      // viewed past the end of the allocation — which corrupts the heap
      // silently and crashes somewhere else entirely.
      for (final size in <int>[
        64 * 1024 + 1,
        1024 * 1024,
        5 * 1024 * 1024 + 3,
      ]) {
        final bytes = _pattern(size);
        final expected = _hex(bytes);
        for (final (label, create) in implementations) {
          expect(
            _feed(create(), bytes, size),
            expected,
            reason: '$label diverged on a single $size-byte add',
          );
        }
      }
    });
  });

  group('the shipped digest', () {
    test('uses the OS implementation when the host has one', () {
      if (!sttNativeDigestAvailable) {
        // A host without CommonCrypto/libcrypto/bcrypt is a supported host; the
        // pure-Dart path is the answer there and the parity group covers it.
        markTestSkipped('no OS SHA-256 on this host');
        return;
      }
      expect(
        createSttDigest(),
        isNot(isA<PureDartSttDigest>()),
        reason: 'the factory fell back although the OS implementation loaded',
      );
    });

    test('two live digests keep two separate contexts', () {
      // The factory used to hand out one cached native instance, so two digests
      // alive at once shared a context: interleaved input produced a checksum
      // that belonged to neither artifact, and the first `finish()` freed the
      // memory the other was still writing.
      final first = _pattern(1024 * 1024 + 3);
      final second = _pattern(1024 * 1024 + 5);
      final firstExpected = _hex(first);
      final secondExpected = _hex(second);

      final a = createSttDigest();
      final b = createSttDigest();
      const step = 64 * 1024;
      for (var offset = 0;
          offset < first.length || offset < second.length;
          offset += step) {
        if (offset < first.length) {
          final end = offset + step > first.length
              ? first.length
              : offset + step;
          a.add(Uint8List.sublistView(first, offset, end));
        }
        if (offset < second.length) {
          final end = offset + step > second.length
              ? second.length
              : offset + step;
          b.add(Uint8List.sublistView(second, offset, end));
        }
      }
      expect(a.finish(), firstExpected, reason: 'the first digest was corrupted');
      expect(b.finish(), secondExpected, reason: 'the second digest was corrupted');
      a.close();
      b.close();
    });

    test('closing an abandoned digest releases it and leaves the factory able '
        'to start another', () {
      // A cancelled install, a refused write, or a dropped connection never
      // reaches `finish()`; without `close()` that context is leaked and the
      // next `init()` overwrote its pointers.
      final bytes = _pattern(512 * 1024);
      final expected = _hex(bytes);

      final abandoned = createSttDigest();
      abandoned.add(Uint8List.sublistView(bytes, 0, 1024));
      abandoned.close();
      abandoned.close(); // idempotent

      final fresh = createSttDigest();
      fresh.add(bytes);
      expect(fresh.finish(), expected);
      fresh.close(); // no-op after finish
    });

    test('finish then close is safe on every implementation', () {
      for (final (label, create) in implementations) {
        final digest = create();
        digest.add(Uint8List.fromList(const <int>[1, 2, 3]));
        expect(digest.finish(), _hex(const <int>[1, 2, 3]), reason: label);
        digest.close();
        digest.close();
      }
    });
  });
}
