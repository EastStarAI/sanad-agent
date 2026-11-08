part of '../../../sanad_dev_cli.dart';

/// Wall-clock budget for the complete optional disk-size pass.
///
/// Sizing a worktree is best-effort evidence: once this budget is spent the
/// remaining rows report `skipped` instead of delaying the report.
const inventoryDiskScanBudget = Duration(milliseconds: 1600);

/// Wall-clock budget for one worktree's disk-size walk.
const inventoryDiskScanRowBudget = Duration(milliseconds: 400);

/// Filesystem-entry cap for one worktree's disk-size walk.
const inventoryDiskScanEntryLimit = 80000;

/// Global budget for the optional `gh` pull-request lookup.
const inventoryPullRequestBudget = Duration(seconds: 5);

/// Wall-clock cap for one `gh` child.
const inventoryPullRequestCommandTimeout = Duration(seconds: 4);

/// Maximum number of concurrent `gh` children.
const inventoryPullRequestConcurrency = 2;

/// How long one cached pull-request answer stays usable.
const inventoryPullRequestCacheTtl = Duration(minutes: 10);

/// Version of the on-disk pull-request cache document.
const inventoryPullRequestCacheVersion = 1;

/// Maximum number of branches kept in the pull-request cache.
const inventoryPullRequestCacheLimit = 200;

/// Exit status the bounded `gh` runner reports after it kills a hung child.
const inventoryPullRequestTimeoutExitCode = 124;

/// How completely one worktree's size was measured.
enum InventoryDiskScan { measured, skipped, missing }

/// Upstream branch state of one worktree branch.
enum InventoryUpstreamState { none, tracking, gone }

/// Whether one worktree may be removed without losing local evidence.
enum InventoryRemovalVerdict { safe, keep }

/// Outcome of the optional `gh` pull-request lookup for one worktree.
enum InventoryPullRequestLookup { notRequested, ok, unavailable, timeout }

/// The lowercase wire name of one pull-request lookup outcome.
String inventoryPullRequestLookupName(InventoryPullRequestLookup lookup) =>
    switch (lookup) {
      InventoryPullRequestLookup.notRequested => 'not_requested',
      InventoryPullRequestLookup.ok => 'ok',
      InventoryPullRequestLookup.unavailable => 'unavailable',
      InventoryPullRequestLookup.timeout => 'timeout',
    };

/// The `safe`/`keep` removal verdict plus the bounded reason behind it.
class InventoryWorktreeRemoval {
  const InventoryWorktreeRemoval({required this.verdict, required this.reason});

  final InventoryRemovalVerdict verdict;

  /// Bounded, ASCII, secret-free explanation of the verdict.
  final String reason;

  Map<String, Object?> toJson() => {
    'removal': verdict.name,
    'removal_reason': reason,
  };
}

/// One measured or skipped worktree size.
class InventoryDiskUsage {
  const InventoryDiskUsage({this.bytes, required this.scan});

  final int? bytes;
  final InventoryDiskScan scan;

  static const missing = InventoryDiskUsage(scan: InventoryDiskScan.missing);
  static const skipped = InventoryDiskUsage(scan: InventoryDiskScan.skipped);
}

/// The last-commit and upstream evidence read from one worktree.
class InventoryWorktreeTracking {
  const InventoryWorktreeTracking({
    this.lastCommitAt,
    this.upstream,
    this.upstreamState = InventoryUpstreamState.none,
    this.upstreamAhead,
    this.upstreamBehind,
  });

  final DateTime? lastCommitAt;
  final String? upstream;
  final InventoryUpstreamState upstreamState;
  final int? upstreamAhead;
  final int? upstreamBehind;

  static const none = InventoryWorktreeTracking();
}

/// One pull request reported by `gh`, or restored from the bounded cache.
class InventoryPullRequest {
  const InventoryPullRequest({
    required this.number,
    required this.state,
    required this.source,
    required this.checkedAt,
    this.url,
  });

  final int number;

  /// GitHub state name: `OPEN`, `CLOSED`, or `MERGED`.
  final String state;
  final String source;
  final DateTime checkedAt;
  final String? url;

  /// Whether the pull request merged its head branch into its base branch.
  bool get merged => state.toUpperCase() == 'MERGED';

  Map<String, Object?> toJson() => {
    'number': number,
    'state': state,
    'url': url,
    'source': source,
    'checked_at': checkedAt.toUtc().toIso8601String(),
  };
}

/// One branch's pull-request answer and how it was produced.
class InventoryPullRequestAnswer {
  const InventoryPullRequestAnswer({
    this.pullRequest,
    required this.lookup,
    this.source,
  });

  final InventoryPullRequest? pullRequest;
  final InventoryPullRequestLookup lookup;
  final String? source;

  static const notRequested = InventoryPullRequestAnswer(
    lookup: InventoryPullRequestLookup.notRequested,
  );

  static const unavailable = InventoryPullRequestAnswer(
    lookup: InventoryPullRequestLookup.unavailable,
  );

  static const timedOut = InventoryPullRequestAnswer(
    lookup: InventoryPullRequestLookup.timeout,
  );
}

/// The complete optional pull-request pass, including its failure reason.
class InventoryPullRequestLookupResult {
  const InventoryPullRequestLookupResult({
    required this.answers,
    this.unavailableReason,
  });

  final Map<String, InventoryPullRequestAnswer> answers;

  /// Bounded reason `gh` could not answer, when it could not.
  final String? unavailableReason;

  InventoryPullRequestAnswer answerFor(String? branch) {
    if (branch == null) return InventoryPullRequestAnswer.notRequested;
    return answers[branch] ?? InventoryPullRequestAnswer.notRequested;
  }
}

/// Runs one bounded external command without a shell.
typedef SanadDevGhRunner =
    Future<ProcessResult> Function(
      String workingDirectory,
      List<String> args,
      Duration timeout,
    );

/// Runs `gh` with a hard wall-clock cap, killing the child when it overruns.
///
/// A missing binary surfaces as [ProcessException] so the caller can report
/// `unavailable`; an overrun returns [inventoryPullRequestTimeoutExitCode].
Future<ProcessResult> runSanadDevGh(
  String workingDirectory,
  List<String> args,
  Duration timeout,
) async {
  final process = await Process.start(
    'gh',
    args,
    workingDirectory: workingDirectory,
  );
  // Drain both pipes before awaiting the exit status: a full pipe must never
  // deadlock a bounded child.
  final stdoutFuture = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  final stderrFuture = process.stderr
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  var timedOut = false;
  final exitStatus = await process.exitCode.timeout(
    timeout,
    onTimeout: () {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
      return inventoryPullRequestTimeoutExitCode;
    },
  );
  final output = await stdoutFuture;
  final errors = await stderrFuture;
  return ProcessResult(
    process.pid,
    timedOut ? inventoryPullRequestTimeoutExitCode : exitStatus,
    output,
    errors,
  );
}

/// Reads one worktree's last-commit timestamp and upstream state.
///
/// Every read is bounded Git metadata; a missing history, an absent upstream, or
/// a deleted remote branch is reported as evidence rather than an error.
Future<InventoryWorktreeTracking> readInventoryWorktreeTracking(
  SanadDevGitRunner git,
  String path, {
  required String? branch,
  required bool detached,
}) async {
  final rawSeconds = await readInventoryGitText(git, path, [
    'log',
    '-1',
    '--format=%ct',
  ]);
  final seconds = int.tryParse(rawSeconds ?? '');
  final lastCommitAt = seconds == null || seconds <= 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
  if (detached || branch == null || branch.isEmpty) {
    return InventoryWorktreeTracking(lastCommitAt: lastCommitAt);
  }
  final upstream = await readInventoryGitText(git, path, [
    'rev-parse',
    '--abbrev-ref',
    '--symbolic-full-name',
    '@{upstream}',
  ]);
  if (upstream == null || upstream.isEmpty) {
    return InventoryWorktreeTracking(lastCommitAt: lastCommitAt);
  }
  final counts = await readInventoryGitText(git, path, [
    'rev-list',
    '--left-right',
    '--count',
    '@{upstream}...HEAD',
  ]);
  final parts = counts
      ?.split(RegExp(r'\s+'))
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
  if (parts == null || parts.length != 2) {
    // The branch still configures this upstream, but the ref is gone.
    return InventoryWorktreeTracking(
      lastCommitAt: lastCommitAt,
      upstream: upstream,
      upstreamState: InventoryUpstreamState.gone,
    );
  }
  return InventoryWorktreeTracking(
    lastCommitAt: lastCommitAt,
    upstream: upstream,
    upstreamState: InventoryUpstreamState.tracking,
    upstreamBehind: int.tryParse(parts[0]),
    upstreamAhead: int.tryParse(parts[1]),
  );
}

/// Measures one worktree's size with a row budget and a shared pass deadline.
///
/// The walk never follows a symbolic link, never leaves [path], and stops as
/// soon as the row budget, the shared deadline, or the entry cap is reached, so
/// a large repository reports `skipped` instead of stalling the report.
InventoryDiskUsage measureInventoryDiskUsage(
  String path, {
  required Stopwatch pass,
  Duration passBudget = inventoryDiskScanBudget,
  Duration rowBudget = inventoryDiskScanRowBudget,
  int entryLimit = inventoryDiskScanEntryLimit,
}) {
  final rootType = FileSystemEntity.typeSync(path, followLinks: false);
  if (rootType == FileSystemEntityType.notFound) {
    return InventoryDiskUsage.missing;
  }
  if (rootType != FileSystemEntityType.directory) {
    return const InventoryDiskUsage(scan: InventoryDiskScan.skipped);
  }
  final row = Stopwatch()..start();
  var bytes = 0;
  var entries = 0;
  final pending = <Directory>[Directory(path)];
  while (pending.isNotEmpty) {
    if (row.elapsed >= rowBudget ||
        pass.elapsed >= passBudget ||
        entries >= entryLimit) {
      return InventoryDiskUsage.skipped;
    }
    final directory = pending.removeLast();
    List<FileSystemEntity> children;
    try {
      children = directory.listSync(followLinks: false);
    } on FileSystemException {
      // An unreadable directory contributes no evidence; the walk continues.
      continue;
    }
    for (final child in children) {
      entries++;
      if (entries > entryLimit) {
        return InventoryDiskUsage.skipped;
      }
      if (child is Link) continue;
      if (child is Directory) {
        pending.add(child);
        continue;
      }
      if (child is File) {
        try {
          bytes += child.statSync().size;
        } on FileSystemException {
          continue;
        }
      }
    }
  }
  return InventoryDiskUsage(bytes: bytes, scan: InventoryDiskScan.measured);
}

/// Resolves the optional `gh` pull-request answers for [branchHeads].
///
/// A fresh cache entry answers first, so a warm run starts no child. Every
/// remaining branch is queried under one shared budget; a missing, failing,
/// unauthenticated, or hung `gh` yields a reported marker and never fails the
/// report, which keeps `inventory` usable offline.
Future<InventoryPullRequestLookupResult> resolveInventoryPullRequests({
  required String workingDirectory,
  required Map<String, String> branchHeads,
  String? cachePath,
  DateTime Function()? clock,
  SanadDevGhRunner gh = runSanadDevGh,
  Duration budget = inventoryPullRequestBudget,
  Duration commandTimeout = inventoryPullRequestCommandTimeout,
  Duration cacheTtl = inventoryPullRequestCacheTtl,
}) async {
  final now = (clock ?? DateTime.now)().toUtc();
  final cached = cachePath == null
      ? const <String, InventoryPullRequestCacheEntry>{}
      : readInventoryPullRequestCache(cachePath);
  final answers = <String, InventoryPullRequestAnswer>{};
  final pending = <String>[];
  for (final entry in branchHeads.entries) {
    final cachedEntry = cached[entry.key];
    if (cachedEntry != null &&
        cachedEntry.head == entry.value &&
        now.difference(cachedEntry.checkedAt) <= cacheTtl) {
      answers[entry.key] = InventoryPullRequestAnswer(
        pullRequest: cachedEntry.pullRequest,
        lookup: InventoryPullRequestLookup.ok,
        source: cachedEntry.pullRequest == null ? null : 'cache',
      );
      continue;
    }
    pending.add(entry.key);
  }

  var unavailable = false;
  String? unavailableReason;
  final queried = <String>{};
  final pass = Stopwatch()..start();
  await mapBounded(pending, inventoryPullRequestConcurrency, (branch) async {
    if (unavailable) {
      answers[branch] = InventoryPullRequestAnswer.unavailable;
      return;
    }
    if (pass.elapsed >= budget) {
      answers[branch] = InventoryPullRequestAnswer.timedOut;
      return;
    }
    queried.add(branch);
    final ProcessResult result;
    try {
      result = await gh(workingDirectory, [
        'pr',
        'list',
        '--head',
        branch,
        '--state',
        'all',
        '--limit',
        '1',
        '--json',
        'number,state,url,isDraft,mergedAt',
      ], commandTimeout);
    } on ProcessException {
      unavailable = true;
      unavailableReason ??= 'gh is not installed';
      answers[branch] = InventoryPullRequestAnswer.unavailable;
      return;
    }
    if (result.exitCode == inventoryPullRequestTimeoutExitCode) {
      answers[branch] = InventoryPullRequestAnswer.timedOut;
      return;
    }
    if (result.exitCode != 0) {
      unavailable = true;
      unavailableReason ??= inventoryBoundedReason(result.stderr.toString());
      answers[branch] = InventoryPullRequestAnswer.unavailable;
      return;
    }
    final parsed = parseInventoryPullRequest(
      result.stdout.toString(),
      checkedAt: now,
    );
    answers[branch] = InventoryPullRequestAnswer(
      pullRequest: parsed,
      lookup: InventoryPullRequestLookup.ok,
      source: 'gh',
    );
  });

  if (cachePath != null) {
    final fresh = <String, InventoryPullRequestCacheEntry>{
      for (final branch in queried)
        if (answers[branch]?.lookup == InventoryPullRequestLookup.ok)
          branch: InventoryPullRequestCacheEntry(
            head: branchHeads[branch] ?? '',
            checkedAt: now,
            pullRequest: answers[branch]!.pullRequest,
          ),
    };
    if (fresh.isNotEmpty) {
      writeInventoryPullRequestCache(cachePath, cached, fresh);
    }
  }

  return InventoryPullRequestLookupResult(
    answers: answers,
    unavailableReason: unavailable ? unavailableReason : null,
  );
}

/// Parses one `gh pr list --json` answer into at most one pull request.
InventoryPullRequest? parseInventoryPullRequest(
  String stdout, {
  required DateTime checkedAt,
}) {
  final trimmed = stdout.trim();
  if (trimmed.isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException {
    return null;
  }
  if (decoded is! List || decoded.isEmpty) return null;
  final first = decoded.first;
  if (first is! Map) return null;
  final rawNumber = first['number'];
  final number = rawNumber is int ? rawNumber : int.tryParse('$rawNumber');
  if (number == null || number <= 0) return null;
  final url = first['url']?.toString().trim();
  return InventoryPullRequest(
    number: number,
    state: first['state']?.toString().trim().toUpperCase() ?? 'OPEN',
    source: 'gh',
    checkedAt: checkedAt,
    url: url == null || url.isEmpty ? null : url,
  );
}

/// One usable pull-request cache entry.
class InventoryPullRequestCacheEntry {
  const InventoryPullRequestCacheEntry({
    required this.head,
    required this.checkedAt,
    this.pullRequest,
  });

  final String head;
  final DateTime checkedAt;
  final InventoryPullRequest? pullRequest;
}

Map<String, InventoryPullRequestCacheEntry> readInventoryPullRequestCache(
  String path,
) {
  try {
    final file = File(path);
    if (!file.existsSync()) return const {};
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map || decoded['version'] != inventoryPullRequestCacheVersion) {
      return const {};
    }
    final entries = decoded['entries'];
    if (entries is! Map) return const {};
    final result = <String, InventoryPullRequestCacheEntry>{};
    for (final entry in entries.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      final head = value['head']?.toString() ?? '';
      final checkedAt = DateTime.tryParse(value['checked_at']?.toString() ?? '');
      if (head.isEmpty || checkedAt == null) continue;
      final rawNumber = value['number'];
      final number = rawNumber is int ? rawNumber : int.tryParse('$rawNumber');
      result[entry.key.toString()] = InventoryPullRequestCacheEntry(
        head: head,
        checkedAt: checkedAt.toUtc(),
        pullRequest: number == null || number <= 0
            ? null
            : InventoryPullRequest(
                number: number,
                state: value['state']?.toString() ?? 'OPEN',
                source: 'cache',
                checkedAt: checkedAt.toUtc(),
                url: value['url']?.toString(),
              ),
      );
    }
    return result;
  } on Object {
    // A corrupt cache is a cache miss, never a failure.
    return const {};
  }
}

void writeInventoryPullRequestCache(
  String path,
  Map<String, InventoryPullRequestCacheEntry> existing,
  Map<String, InventoryPullRequestCacheEntry> fresh,
) {
  try {
    final merged = <String, InventoryPullRequestCacheEntry>{
      ...existing,
      ...fresh,
    };
    final ordered = merged.entries.toList()
      ..sort(
        (left, right) => right.value.checkedAt.compareTo(left.value.checkedAt),
      );
    final kept = ordered.take(inventoryPullRequestCacheLimit);
    final document = {
      'version': inventoryPullRequestCacheVersion,
      'entries': {
        for (final entry in kept)
          entry.key: {
            'head': entry.value.head,
            'checked_at': entry.value.checkedAt.toUtc().toIso8601String(),
            if (entry.value.pullRequest != null) ...{
              'number': entry.value.pullRequest!.number,
              'state': entry.value.pullRequest!.state,
              'url': entry.value.pullRequest!.url,
            },
          },
      },
    };
    final file = File(path);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('${jsonEncode(document)}\n');
  } on Object {
    // The cache is an optimization only; a write failure cannot fail inventory.
  }
}

/// Collapses one child's error output to a single bounded, path-free line.
String inventoryBoundedReason(String value) {
  final line = value
      .split('\n')
      .map((candidate) => candidate.trim())
      .firstWhere((candidate) => candidate.isNotEmpty, orElse: () => '');
  if (line.isEmpty) return 'gh failed';
  return line.length <= 120 ? line : '${line.substring(0, 117)}...';
}

/// Decides whether one worktree may be removed without losing evidence.
///
/// [safe] requires a clean tree, merged or pushed work, no live runtime, and no
/// Test Home. Every other combination keeps the worktree and names the first
/// reason that blocks removal, in the order an operator needs to act on it.
InventoryWorktreeRemoval computeInventoryRemoval({
  required bool primaryCheckout,
  required bool missing,
  required bool locked,
  required bool detached,
  required int dirtyCount,
  required int? ahead,
  required String? upstream,
  required InventoryUpstreamState upstreamState,
  required int? upstreamAhead,
  required bool liveRuntime,
  required bool testHome,
  required InventoryPullRequest? pullRequest,
}) {
  InventoryWorktreeRemoval keep(String reason) => InventoryWorktreeRemoval(
    verdict: InventoryRemovalVerdict.keep,
    reason: reason,
  );

  if (primaryCheckout) return keep('primary checkout');
  if (missing) return keep('worktree directory is missing');
  if (locked) return keep('worktree is locked');
  if (detached) return keep('detached HEAD');
  if (liveRuntime) return keep('live runtime');
  if (testHome) return keep('Test Home');
  if (dirtyCount > 0) return keep('uncommitted changes ($dirtyCount)');

  final mergedIntoMain = ahead != null && ahead == 0;
  final pushed =
      upstreamState == InventoryUpstreamState.tracking &&
      upstreamAhead != null &&
      upstreamAhead == 0;
  if (pullRequest != null && pullRequest.merged) {
    return InventoryWorktreeRemoval(
      verdict: InventoryRemovalVerdict.safe,
      reason: 'clean and merged via PR #${pullRequest.number}',
    );
  }
  if (mergedIntoMain) {
    return const InventoryWorktreeRemoval(
      verdict: InventoryRemovalVerdict.safe,
      reason: 'clean and merged into origin/main',
    );
  }
  if (pushed) {
    return InventoryWorktreeRemoval(
      verdict: InventoryRemovalVerdict.safe,
      reason: 'clean and pushed to ${upstream ?? 'upstream'}',
    );
  }
  if (upstreamAhead != null && upstreamAhead > 0) {
    return keep('$upstreamAhead commits not pushed to ${upstream ?? 'upstream'}');
  }
  if (upstreamState == InventoryUpstreamState.gone) {
    final pending = ahead ?? 0;
    return keep(
      pending > 0
          ? 'upstream $upstream is gone and $pending commits are not in origin/main'
          : 'upstream $upstream is gone',
    );
  }
  if (ahead != null && ahead > 0) return keep('$ahead commits not pushed');
  if (ahead == null) return keep('tracking state is unknown');
  return keep('work is not pushed or merged');
}

/// Compact human-readable size, for example `812K`, `1.2M`, or `3G`.
String formatInventoryBytes(int bytes) {
  const units = ['B', 'K', 'M', 'G', 'T'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = unit == 0 || value >= 10 ? 0 : 1;
  return '${value.toStringAsFixed(digits)}${units[unit]}';
}

/// Compact commit age, for example `45s`, `12m`, `5h`, or `3d`.
String formatInventoryAge(int? seconds) {
  if (seconds == null) return '-';
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) return '${seconds ~/ 60}m';
  if (seconds < 86400) return '${seconds ~/ 3600}h';
  return '${seconds ~/ 86400}d';
}
