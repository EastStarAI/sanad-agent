/// Free disk space for a model install.
///
/// `dart:io` exposes no `statvfs`, so the only portable answer is the platform's
/// own reporting tool. The probe is deliberately tiny, read-only, and
/// best-effort: it runs once per install, it may not block for more than
/// [kSttFreeSpaceProbeTimeout], and an unknown answer (`null`) never fails an
/// install — the write path maps a real `ENOSPC` to `storage_full` instead.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Head-room an install keeps beyond the bytes it is about to write.
///
/// A volume that is exactly large enough still fails in practice: the atomic
/// rename, the digest bookkeeping, and the rest of the machine write to the same
/// volume while the download runs. The margin is what turns "it fit at the
/// moment we checked" into "it fits until the install finishes".
const int kSttInstallFreeSpaceMarginBytes = 256 * 1024 * 1024;

/// How long the probe may take before the answer is treated as unknown.
const Duration kSttFreeSpaceProbeTimeout = Duration(seconds: 3);

/// Free bytes available to the volume that holds [path], or null when unknown.
typedef SttFreeSpaceProbe = Future<int?> Function(String path);

/// Reads the free space of the volume holding [path].
///
/// Returns null when the platform cannot answer, the command fails, or the
/// output is not the shape this parser understands. A caller treats null as
/// "unknown", never as "full".
Future<int?> defaultSttFreeSpace(String path) async {
  if (Platform.isWindows) {
    // `df` is a POSIX tool. Windows installs fall back to the write-time
    // `storage_full` mapping, which is the same typed outcome one error later.
    return null;
  }
  try {
    final result = await Process.run(
      'df',
      ['-Pk', path],
      stdoutEncoding: const Utf8Codec(),
    ).timeout(kSttFreeSpaceProbeTimeout);
    if (result.exitCode != 0) return null;
    return parseSttFreeSpace('${result.stdout}');
  } on Object {
    return null;
  }
}

/// Parses `df -Pk` output into bytes, or null when it is not that shape.
///
/// POSIX output is one header line and one data line of six whitespace-separated
/// columns, the fourth being the available 1024-byte blocks. A mounted path with
/// spaces still leaves the numeric columns in place, so the line is read from the
/// left instead of by exact column count.
int? parseSttFreeSpace(String output) {
  final lines = output
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  if (lines.length < 2) return null;
  final columns = lines.last.split(RegExp(r'\s+'));
  if (columns.length < 4) return null;
  final availableKib = int.tryParse(columns[3]);
  if (availableKib == null || availableKib < 0) return null;
  return availableKib * 1024;
}
