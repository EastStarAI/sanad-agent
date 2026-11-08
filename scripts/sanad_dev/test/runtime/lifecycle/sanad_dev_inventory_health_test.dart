import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;

import '../../support/sanad_dev_inventory_fixture.dart';

/// Health, verdict, and optional pull-request coverage for `inventory`.
void main() {
  group('sanad-dev inventory removal verdict', () {
    final merged = sanad_dev.computeInventoryRemoval(
      primaryCheckout: false,
      missing: false,
      locked: false,
      detached: false,
      dirtyCount: 0,
      ahead: 0,
      upstream: null,
      upstreamState: sanad_dev.InventoryUpstreamState.none,
      upstreamAhead: null,
      liveRuntime: false,
      testHome: false,
      pullRequest: null,
    );

    test('keeps a primary, missing, locked, or detached worktree', () {
      expect(
        _verdict(primaryCheckout: true),
        ('keep', 'primary checkout'),
      );
      expect(_verdict(missing: true), ('keep', 'worktree directory is missing'));
      expect(_verdict(locked: true), ('keep', 'worktree is locked'));
      expect(_verdict(detached: true), ('keep', 'detached HEAD'));
    });

    test('keeps a live runtime or a Test Home before any Git reason', () {
      expect(_verdict(liveRuntime: true), ('keep', 'live runtime'));
      expect(_verdict(testHome: true), ('keep', 'Test Home'));
      expect(
        _verdict(dirtyCount: 4),
        ('keep', 'uncommitted changes (4)'),
      );
    });

    test('reports safe only for clean, merged or pushed work', () {
      expect(merged.verdict, sanad_dev.InventoryRemovalVerdict.safe);
      expect(merged.reason, 'clean and merged into origin/main');

      final pushed = _verdict(
        ahead: 2,
        upstream: 'origin/feat/x',
        upstreamState: sanad_dev.InventoryUpstreamState.tracking,
        upstreamAhead: 0,
        upstreamBehind: 1,
      );
      expect(pushed, ('safe', 'clean and pushed to origin/feat/x'));
    });

    test('keeps unpushed, gone-upstream, and unknown tracking states', () {
      expect(
        _verdict(
          ahead: 2,
          upstream: 'origin/feat/x',
          upstreamState: sanad_dev.InventoryUpstreamState.tracking,
          upstreamAhead: 2,
        ),
        ('keep', '2 commits not pushed to origin/feat/x'),
      );
      expect(
        _verdict(
          ahead: 1,
          upstream: 'origin/feat/x',
          upstreamState: sanad_dev.InventoryUpstreamState.gone,
        ),
        ('keep', 'upstream origin/feat/x is gone and 1 commits are not in origin/main'),
      );
      expect(
        _verdict(
          ahead: null,
          upstream: 'origin/feat/x',
          upstreamState: sanad_dev.InventoryUpstreamState.gone,
        ),
        ('keep', 'upstream origin/feat/x is gone'),
      );
      expect(_verdict(ahead: 2), ('keep', '2 commits not pushed'));
      expect(_verdict(ahead: null), ('keep', 'tracking state is unknown'));
    });

    test('treats a merged pull request as merged evidence', () {
      final removal = _verdict(
        ahead: 3,
        upstream: 'origin/feat/x',
        upstreamState: sanad_dev.InventoryUpstreamState.tracking,
        upstreamAhead: 3,
        pullRequest: _pullRequest(12, 'MERGED'),
      );
      expect(removal, ('safe', 'clean and merged via PR #12'));
    });
  });

  group('sanad-dev inventory disk sizing', () {
    late Directory root;

    setUp(() => root = Directory.systemTemp.createTempSync('sanad-disk-'));
    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('measures a bounded tree and never follows a link', () {
      final tree = Directory(p.join(root.path, 'tree'))..createSync();
      File(p.join(tree.path, 'a.bin')).writeAsBytesSync(List.filled(1000, 0));
      final nested = Directory(p.join(tree.path, 'nested'))..createSync();
      File(p.join(nested.path, 'b.bin')).writeAsBytesSync(List.filled(24, 0));
      final outside = Directory(p.join(root.path, 'outside'))..createSync();
      File(p.join(outside.path, 'c.bin')).writeAsBytesSync(List.filled(9000, 0));
      if (!Platform.isWindows) {
        Link(p.join(tree.path, 'escape')).createSync(outside.path);
      }

      final usage = sanad_dev.measureInventoryDiskUsage(
        tree.path,
        pass: Stopwatch()..start(),
      );

      expect(usage.scan, sanad_dev.InventoryDiskScan.measured);
      expect(usage.bytes, 1024);
    });

    test('reports skipped when the pass, row, or entry budget ends the walk',
        () {
      final tree = Directory(p.join(root.path, 'tree'))..createSync();
      File(p.join(tree.path, 'a.bin')).writeAsBytesSync(List.filled(10, 0));

      expect(
        sanad_dev
            .measureInventoryDiskUsage(
              tree.path,
              pass: Stopwatch()..start(),
              passBudget: Duration.zero,
            )
            .scan,
        sanad_dev.InventoryDiskScan.skipped,
      );
      expect(
        sanad_dev
            .measureInventoryDiskUsage(
              tree.path,
              pass: Stopwatch()..start(),
              entryLimit: 0,
            )
            .scan,
        sanad_dev.InventoryDiskScan.skipped,
      );
      expect(
        sanad_dev
            .measureInventoryDiskUsage(
              tree.path,
              pass: Stopwatch()..start(),
              rowBudget: Duration.zero,
            )
            .scan,
        sanad_dev.InventoryDiskScan.skipped,
      );
    });

    test('reports missing for a worktree directory that no longer exists', () {
      final usage = sanad_dev.measureInventoryDiskUsage(
        p.join(root.path, 'gone'),
        pass: Stopwatch()..start(),
      );
      expect(usage.scan, sanad_dev.InventoryDiskScan.missing);
      expect(usage.bytes, isNull);
    });
  });

  group('sanad-dev inventory health projection', () {
    late InventoryFixture fixture;

    setUp(() => fixture = InventoryFixture.create());
    tearDown(() => fixture.dispose());

    Future<sanad_dev.SanadDevInventory> collect({
      FakeInventoryGit? git,
      DateTime? now,
      bool pullRequests = false,
      sanad_dev.SanadDevGhRunner? gh,
      String? cachePath,
      Duration diskPassBudget = sanad_dev.inventoryDiskScanBudget,
    }) {
      return sanad_dev.collectSanadDevInventory(
        callerDirectory: fixture.linkedPath,
        environment: fixture.environment,
        git:
            (git ??
                    FakeInventoryGit(
                      entries: [
                        FakeWorktreeEntry(fixture.primaryPath, 'main', 'a' * 40),
                        FakeWorktreeEntry(
                          fixture.linkedPath,
                          'feat/health',
                          'b' * 40,
                        ),
                      ],
                      dirty: {fixture.primaryPath: 0, fixture.linkedPath: 0},
                      tracking: {
                        fixture.primaryPath: (behind: 2, ahead: 0),
                        fixture.linkedPath: (behind: 0, ahead: 0),
                      },
                    ))
                .call,
        processRunning: (pid) async => false,
        probeAgents: (runtime, ports) async => const [],
        discoverClients: (runtime) async => const [],
        clock: () => now ?? DateTime.utc(2026, 11, 9, 12),
        pullRequests: pullRequests,
        gh: gh ?? _ghUnavailable,
        pullRequestCachePath: cachePath,
        diskPassBudget: diskPassBudget,
      );
    }

    test('reads commit age, upstream state, and a safe verdict', () async {
      final commitSeconds = DateTime.utc(2026, 11, 9, 9).millisecondsSinceEpoch ~/
          1000;
      final inventory = await collect(
        git: FakeInventoryGit(
          entries: [
            FakeWorktreeEntry(fixture.primaryPath, 'main', 'a' * 40),
            FakeWorktreeEntry(fixture.linkedPath, 'feat/health', 'b' * 40),
          ],
          dirty: {fixture.primaryPath: 0, fixture.linkedPath: 0},
          tracking: {
            fixture.primaryPath: (behind: 2, ahead: 0),
            fixture.linkedPath: (behind: 0, ahead: 0),
          },
          upstreams: {fixture.linkedPath: 'origin/feat/health'},
          upstreamTracking: {
            fixture.linkedPath: (behind: 1, ahead: 0),
          },
          commitTimes: {
            fixture.primaryPath: commitSeconds,
            fixture.linkedPath: commitSeconds,
          },
        ),
      );

      final primary = inventory.worktrees.first;
      expect(primary.lastCommitAt, DateTime.utc(2026, 11, 9, 9));
      expect(primary.lastCommitAgeSeconds, 3 * 60 * 60);
      expect(primary.upstream, isNull);
      expect(primary.upstreamState, sanad_dev.InventoryUpstreamState.none);
      expect(primary.removal.verdict, sanad_dev.InventoryRemovalVerdict.keep);
      expect(primary.removal.reason, 'primary checkout');

      final linked = inventory.worktrees[1];
      expect(linked.upstream, 'origin/feat/health');
      expect(linked.upstreamState, sanad_dev.InventoryUpstreamState.tracking);
      expect(linked.upstreamAhead, 0);
      expect(linked.upstreamBehind, 1);
      expect(linked.diskScan, sanad_dev.InventoryDiskScan.measured);
      expect(linked.diskBytes, isNotNull);
      expect(linked.removal.verdict, sanad_dev.InventoryRemovalVerdict.safe);
      expect(linked.removal.reason, 'clean and merged into origin/main');
      expect(inventory.removableWorktrees.map((row) => row.worktreeId), [
        linked.worktreeId,
      ]);
      expect(inventory.toJson()['summary'], containsPair('removal_safe', 1));
    });

    test('keeps a dirty or unpushed worktree and names the reason', () async {
      final dirty = await collect(
        git: FakeInventoryGit(
          entries: [
            FakeWorktreeEntry(fixture.primaryPath, 'main', 'a' * 40),
            FakeWorktreeEntry(fixture.linkedPath, 'feat/health', 'b' * 40),
          ],
          dirty: {fixture.primaryPath: 0, fixture.linkedPath: 2},
          tracking: {
            fixture.primaryPath: (behind: 0, ahead: 0),
            fixture.linkedPath: (behind: 0, ahead: 0),
          },
        ),
      );
      expect(
        dirty.worktrees[1].removal.reason,
        'uncommitted changes (2)',
      );

      final unpushed = await collect(
        git: FakeInventoryGit(
          entries: [
            FakeWorktreeEntry(fixture.primaryPath, 'main', 'a' * 40),
            FakeWorktreeEntry(fixture.linkedPath, 'feat/health', 'b' * 40),
          ],
          dirty: {fixture.primaryPath: 0, fixture.linkedPath: 0},
          tracking: {
            fixture.primaryPath: (behind: 0, ahead: 0),
            fixture.linkedPath: (behind: 0, ahead: 3),
          },
          upstreams: {fixture.linkedPath: 'origin/feat/health'},
          upstreamTracking: {
            fixture.linkedPath: (behind: 0, ahead: 3),
          },
        ),
      );
      expect(
        unpushed.worktrees[1].removal.reason,
        '3 commits not pushed to origin/feat/health',
      );
      expect(unpushed.removableWorktrees, isEmpty);
    });

    test('keeps a worktree with a live runtime or a Test Home', () async {
      fixture.writeLease(
        home: fixture.linkedHome,
        port: 58092,
        sourceRoot: fixture.linkedPath,
        workspaceHash: fixture.linkedId.split('-').last,
        launcherPid: 4200,
        status: 'running',
        clientPids: const [7100],
        vmServicePorts: const [51092],
      );
      fixture.writeRecord(
        fixture.linkedId,
        workspaceHash: fixture.linkedId.split('-').last,
        agentPort: 58092,
        resolvedHome: fixture.linkedHome,
      );

      final inventory = await sanad_dev.collectSanadDevInventory(
        callerDirectory: fixture.linkedPath,
        environment: fixture.environment,
        git: FakeInventoryGit(
          entries: [
            FakeWorktreeEntry(fixture.primaryPath, 'main', 'a' * 40),
            FakeWorktreeEntry(fixture.linkedPath, 'feat/health', 'b' * 40),
          ],
          dirty: {fixture.primaryPath: 0, fixture.linkedPath: 0},
          tracking: {
            fixture.primaryPath: (behind: 0, ahead: 0),
            fixture.linkedPath: (behind: 0, ahead: 0),
          },
        ).call,
        processRunning: (pid) async => pid == 4200,
        probeAgents: (runtime, ports) async => [
          sanad_dev.AgentInstance(
            58092,
            fixture.linkedId.split('-').last,
            'worktree',
            launcherId: 'launcher-primary',
            runtimeNonce: 'nonce-primary',
            sanadHome: fixture.linkedHome,
          ),
        ],
        discoverClients: (runtime) async => const [],
        clock: () => DateTime.utc(2026, 11, 9, 12),
      );

      expect(
        inventory.worktrees[1].removal,
        isA<sanad_dev.InventoryWorktreeRemoval>()
            .having(
              (removal) => removal.verdict,
              'verdict',
              sanad_dev.InventoryRemovalVerdict.keep,
            )
            .having((removal) => removal.reason, 'reason', 'live runtime'),
      );
      expect(inventory.removableWorktrees, isEmpty);
    });

    test('works offline when gh is missing, failing, or hung', () async {
      final missing = await collect(pullRequests: true);
      expect(missing.pullRequestLookup, sanad_dev.InventoryPullRequestLookup.unavailable);
      expect(missing.pullRequestUnavailableReason, 'gh is not installed');
      expect(
        missing.worktrees.every(
          (row) =>
              row.pullRequestLookup ==
              sanad_dev.InventoryPullRequestLookup.unavailable,
        ),
        isTrue,
      );
      expect(missing.toJson()['pull_request_lookup'], 'unavailable');

      final hung = await collect(
        pullRequests: true,
        gh: (workingDirectory, args, timeout) async =>
            ProcessResult(0, sanad_dev.inventoryPullRequestTimeoutExitCode, '', ''),
      );
      expect(hung.pullRequestLookup, sanad_dev.InventoryPullRequestLookup.timeout);
      expect(hung.removableWorktrees, hasLength(1));
    });

    test('queries gh once and serves the next run from the cache', () async {
      final cachePath = p.join(
        fixture.userHome.path,
        '.sanad-dev',
        'inventory',
        'pr-cache.json',
      );
      var calls = 0;
      Future<ProcessResult> gh(
        String workingDirectory,
        List<String> args,
        Duration timeout,
      ) async {
        calls++;
        final head = args[args.indexOf('--head') + 1];
        if (head == 'main') return ProcessResult(0, 0, '[]', '');
        return ProcessResult(
          0,
          0,
          jsonEncode([
            {
              'number': 359,
              'state': 'MERGED',
              'url': 'https://example.invalid/pull/359',
              'isDraft': false,
              'mergedAt': '2026-11-08T10:00:00Z',
            },
          ]),
          '',
        );
      }

      final first = await collect(
        pullRequests: true,
        gh: gh,
        cachePath: cachePath,
      );
      final linked = first.worktrees[1];
      expect(calls, 2, reason: 'both real branches are queried once');
      expect(linked.pullRequest?.number, 359);
      expect(linked.pullRequestSource, 'gh');
      expect(linked.pullRequestLookup, sanad_dev.InventoryPullRequestLookup.ok);
      expect(linked.pullRequest?.merged, isTrue);
      expect(linked.removal.reason, 'clean and merged via PR #359');
      expect(File(cachePath).existsSync(), isTrue);

      calls = 0;
      final second = await collect(
        pullRequests: true,
        gh: (workingDirectory, args, timeout) async {
          calls++;
          return ProcessResult(1, 1, '', 'must not be called');
        },
        cachePath: cachePath,
      );
      expect(calls, 0, reason: 'a warm cache starts no child');
      expect(second.worktrees[1].pullRequestSource, 'cache');
      expect(second.worktrees[1].pullRequest?.number, 359);
    });

    test('renders the health columns and a skipped pull-request hint', () async {
      final inventory = await collect();
      final compact = _capture(inventory, showAll: false);
      expect(compact, contains('remove=safe'));
      expect(compact, contains('upstream=none'));
      expect(compact, contains('disk='));
      expect(compact, contains('age=-'));
      expect(compact, contains('PR lookup: skipped'));
      expect(compact, contains('1 safe to remove'));

      final detailed = _capture(inventory, showAll: true);
      expect(detailed, contains('removal: keep - primary checkout'));
      expect(detailed, contains('upstream: none configured'));
      expect(detailed, contains('last commit:'));
    });
  });
}

Future<ProcessResult> _ghUnavailable(
  String workingDirectory,
  List<String> args,
  Duration timeout,
) async {
  throw ProcessException('gh', args, 'No such file or directory', 2);
}

(String, String) _verdict({
  bool primaryCheckout = false,
  bool missing = false,
  bool locked = false,
  bool detached = false,
  int dirtyCount = 0,
  int? ahead = 0,
  String? upstream,
  sanad_dev.InventoryUpstreamState upstreamState =
      sanad_dev.InventoryUpstreamState.none,
  int? upstreamAhead,
  int? upstreamBehind,
  bool liveRuntime = false,
  bool testHome = false,
  sanad_dev.InventoryPullRequest? pullRequest,
}) {
  final removal = sanad_dev.computeInventoryRemoval(
    primaryCheckout: primaryCheckout,
    missing: missing,
    locked: locked,
    detached: detached,
    dirtyCount: dirtyCount,
    ahead: ahead,
    upstream: upstream,
    upstreamState: upstreamState,
    upstreamAhead: upstreamAhead,
    liveRuntime: liveRuntime,
    testHome: testHome,
    pullRequest: pullRequest,
  );
  return (removal.verdict.name, removal.reason);
}

sanad_dev.InventoryPullRequest _pullRequest(int number, String state) {
  return sanad_dev.InventoryPullRequest(
    number: number,
    state: state,
    source: 'gh',
    checkedAt: DateTime.utc(2026, 11, 9, 12),
    url: 'https://example.invalid/pull/$number',
  );
}

String _capture(
  sanad_dev.SanadDevInventory inventory, {
  required bool showAll,
}) {
  final lines = <String>[];
  runZoned(
    () => sanad_dev.printSanadDevInventory(inventory, showAll: showAll),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => lines.add(line),
    ),
  );
  return lines.join('\n');
}
