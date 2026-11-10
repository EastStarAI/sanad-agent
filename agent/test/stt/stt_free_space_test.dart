// The free-space probe's parsing and degradation.
//
// `dart:io` cannot report free space, so the answer comes from `df -Pk` on POSIX
// and from `null` (unknown) anywhere else. Parsing is the risky part: a wrong
// column would silently refuse or silently allow an install.

import 'dart:io';

import 'package:sanad_agent/infrastructure/stt/stt_free_space.dart';
import 'package:test/test.dart';

void main() {
  group('df parsing', () {
    test('reads the available 1024-byte blocks of the data line', () {
      const output =
          'Filesystem   1024-blocks      Used Available Capacity  Mounted on\n'
          '/dev/disk7s1   488181744 382225156 105799528    79%    /Volumes/Storage\n';
      expect(parseSttFreeSpace(output), 105799528 * 1024);
    });

    test('tolerates a mount point with spaces', () {
      const output =
          'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
          '/dev/disk1s2 100 50 50 50% /Volumes/My Disk\n';
      expect(parseSttFreeSpace(output), 50 * 1024);
    });

    test('a header-only or malformed output is unknown, never zero', () {
      expect(
        parseSttFreeSpace('Filesystem 1024-blocks Used Available Capacity\n'),
        isNull,
      );
      expect(parseSttFreeSpace(''), isNull);
      expect(parseSttFreeSpace('garbage here and there\n'), isNull);
      expect(
        parseSttFreeSpace('/dev/x 1 2 notanumber 3% /mnt\n'),
        isNull,
      );
    });
  });

  test('the real probe answers for a directory that exists', () async {
    if (Platform.isWindows) {
      expect(await defaultSttFreeSpace(Directory.current.path), isNull);
      return;
    }
    final free = await defaultSttFreeSpace(Directory.current.path);
    expect(free, isNotNull);
    expect(free, greaterThan(0));
  });

  test('an unknown path is unknown, not a failure', () async {
    if (Platform.isWindows) return;
    final free = await defaultSttFreeSpace(
      '${Directory.systemTemp.path}/stt-free-space-does-not-exist',
    );
    expect(free, isNull);
  });
}
