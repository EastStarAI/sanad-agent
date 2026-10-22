part of '../../../sanad_dev_cli.dart';

/// Changed paths plus the fingerprints they were derived from.
class SanadDevChangedPaths {
  const SanadDevChangedPaths({required this.paths});

  final List<String> paths;
}

/// Paths that differ from what the live runtime was last given.
///
/// The candidate set is the union of three sources: the working tree, the commit
/// range since [startCommit], and every path recorded in [appliedFingerprints].
/// The recorded paths are essential, because a file can differ from the applied
/// baseline while being invisible to Git: reverting an applied tracked edit to
/// `HEAD` removes it from both `git status` and `git diff <start commit>`, and an
/// applied untracked file leaves no trace at all after deletion. Only the
/// recorded fingerprint can tell that the running Agent still holds the applied
/// code and needs a restart.
///
/// [appliedFingerprints] is the per-path content snapshot recorded by the last
/// successful `apply`. A candidate is dropped only when its current content
/// matches the fingerprint that was applied for it, so an already-applied tracked
/// working-tree edit is not reported twice, a reverted or deleted applied file
/// is, a second edit of the same file is, and untracked files behave identically.
Future<SanadDevChangedPaths> inspectChangedPaths({
  required String repositoryRoot,
  required String? startCommit,
  Map<String, String> appliedFingerprints = const {},
}) async {
  final candidates = <String>{...appliedFingerprints.keys};
  final statusOutput = await _gitOutput(repositoryRoot, [
    'status',
    '--porcelain',
    '--untracked-files=all',
  ]);
  candidates.addAll(_porcelainPaths(statusOutput));
  if (startCommit != null && startCommit.trim().isNotEmpty) {
    candidates.addAll(
      await _gitChangedPaths(repositoryRoot, [
        'diff',
        '--name-only',
        startCommit.trim(),
      ]),
    );
  }
  final paths = <String>[];
  for (final path in candidates) {
    final applied = appliedFingerprints[path];
    if (applied != null &&
        applied == sanadDevApplyPathFingerprint(repositoryRoot, path)) {
      continue;
    }
    paths.add(path);
  }
  paths.sort();
  return SanadDevChangedPaths(paths: paths);
}

Future<String> _gitOutput(String repositoryRoot, List<String> arguments) async {
  final result = await Process.run('git', ['-C', repositoryRoot, ...arguments]);
  return result.exitCode == 0 ? result.stdout.toString() : '';
}

List<String> _porcelainPaths(String output) {
  final paths = <String>[];
  for (final raw in const LineSplitter().convert(output)) {
    final line = raw.trimRight();
    if (line.isEmpty) continue;
    final path = line.length > 3 ? line.substring(3).trim() : '';
    if (path.isEmpty) continue;
    final renamed = path.contains(' -> ')
        ? path.split(' -> ').last.trim()
        : path;
    paths.add(renamed.replaceAll('"', ''));
  }
  return paths;
}

Future<List<String>> _gitChangedPaths(
  String repositoryRoot,
  List<String> arguments,
) async {
  final output = await _gitOutput(repositoryRoot, arguments);
  final paths = <String>[];
  for (final raw in const LineSplitter().convert(output)) {
    final line = raw.trimRight();
    if (line.isEmpty) continue;
    paths.add(line.replaceAll('"', ''));
  }
  return paths;
}
