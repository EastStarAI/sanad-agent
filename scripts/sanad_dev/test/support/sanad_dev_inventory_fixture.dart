import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:sanad_dev/src/infrastructure/client_launch_profile.dart'
    as launch_profile;
import 'package:sanad_dev/src/infrastructure/runtime_context.dart'
    as runtime_context;

/// A throwaway Git/Home fixture for `sanad-dev inventory` tests.
///
/// It writes a fake `git worktree list --porcelain`, per-worktree status and
/// tracking answers, one primary Home, one linked Home, one Test Home, and the
/// runtime records and endpoint records the collector reads. Nothing here binds
/// a port or touches the developer's own Home.
class InventoryFixture {
  InventoryFixture._(this.root, this.userHome) {
    primaryHome = Directory(p.join(userHome.path, '.sanad'));
    primaryPath = p.join(root.path, 'repo');
    linkedPath = p.join(root.path, 'repo', '.agent', 'worktrees', 'lt-feature');
    testHomePath = p.join(
      root.path,
      'repo',
      '.agent',
      'worktrees',
      'test-home',
    );
    for (final path in [primaryPath, linkedPath, testHomePath]) {
      Directory(path).createSync(recursive: true);
    }
    primaryHome.createSync(recursive: true);
    // Ids are derived after the directories exist: the worktree hash resolves
    // symbolic links (for example /var -> /private/var on macOS), so the
    // production derivation must see the real directories.
    primaryId = runtime_context.deriveWorktreeId(primaryPath, 'main');
    linkedId = runtime_context.deriveWorktreeId(linkedPath, 'feat/inventory');
    testHomeWorktreeId = runtime_context.deriveWorktreeId(
      testHomePath,
      'test/test-home',
    );
  }

  factory InventoryFixture.create() {
    final root = Directory.systemTemp.createTempSync('sanad-inventory-');
    final userHome = Directory(p.join(root.path, 'user'))
      ..createSync(recursive: true);
    return InventoryFixture._(root, userHome);
  }

  final Directory root;
  final Directory userHome;
  late final Directory primaryHome;
  late final String primaryPath;
  late final String linkedPath;
  late final String testHomePath;
  late final String primaryId;
  late final String linkedId;
  late final String testHomeWorktreeId;

  String get linkedHome => p.join(primaryHome.path, 'dev', 'homes', linkedId);

  Map<String, String> get environment => {
    'HOME': userHome.path,
    'USERPROFILE': userHome.path,
  };

  void dispose() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  }

  /// Writes one launcher lease below [home]/dev.
  void writeLease({
    required String home,
    required int port,
    required String sourceRoot,
    required String workspaceHash,
    required int launcherPid,
    required String status,
    required List<int> clientPids,
    required List<int> vmServicePorts,
    String sourceCommit = '',
    String launcherId = 'launcher-primary',
    String runtimeNonce = 'nonce-primary',
  }) {
    final devDirectory = Directory(p.join(home, 'dev'))
      ..createSync(recursive: true);
    File(
      p.join(devDirectory.path, 'runtime-launcher-$port.json'),
    ).writeAsStringSync(
      jsonEncode({
        'version': 1,
        'launcher_id': launcherId,
        'runtime_nonce': runtimeNonce,
        'launcher_pid': launcherPid,
        'launcher_process_identity': 'process-$launcherPid',
        'workspace_hash': workspaceHash,
        'source_root': sourceRoot,
        'agent_port': port,
        'sanad_home': home,
        'preferences_prefix': '',
        'client_pids': clientPids,
        'vm_service_ports': vmServicePorts,
        'status': status,
        'updated_at': '2026-10-23T00:00:00.000Z',
        'source_commit': sourceCommit,
      }),
    );
  }

  /// Writes one runtime diagnostics record below the primary Home.
  void writeRecord(
    String worktreeId, {
    required String workspaceHash,
    required int agentPort,
    required String resolvedHome,
  }) {
    final directory = Directory(
      p.join(primaryHome.path, 'dev', 'runtimes', worktreeId),
    )..createSync(recursive: true);
    File(p.join(directory.path, 'startup-attempt.json')).writeAsStringSync(
      jsonEncode({
        'version': 1,
        'attempt_id': 'attempt-$worktreeId',
        'workspace_hash': workspaceHash,
        'agent_port': agentPort,
        'resolved_home': resolvedHome,
      }),
    );
  }

  /// Writes one loopback endpoint record owned by [pid].
  void writeEndpoint(String home, {required int pid, required int port}) {
    Directory(home).createSync(recursive: true);
    File(p.join(home, '.local_gateway_endpoint.json')).writeAsStringSync(
      jsonEncode({
        'schema': 1,
        'home_id': 'home-$pid',
        'host': '127.0.0.1',
        'port': port,
        'pid': pid,
      }),
    );
  }
}

/// One fake worktree row for the porcelain listing.
class FakeWorktreeEntry {
  const FakeWorktreeEntry(
    this.path,
    this.branch,
    this.head, {
    this.locked = false,
    this.lockReason,
  });

  final String path;
  final String? branch;
  final String head;
  final bool locked;
  final String? lockReason;
}

/// Fake Git surface for the read-only inventory collector.
///
/// `worktree list --porcelain` is returned verbatim, and `status`/`rev-list`
/// answer per working directory so one fake covers every worktree.
class FakeInventoryGit {
  FakeInventoryGit({
    required this.entries,
    required this.dirty,
    required this.tracking,
  }) {
    final listing = StringBuffer();
    for (final entry in entries) {
      listing.writeln('worktree ${entry.path}');
      listing.writeln('HEAD ${entry.head}');
      if (entry.branch == null) {
        listing.writeln('detached');
      } else {
        listing.writeln('branch refs/heads/${entry.branch}');
      }
      if (entry.locked) {
        listing.writeln(
          entry.lockReason == null ? 'locked' : 'locked ${entry.lockReason}',
        );
      }
      listing.writeln();
    }
    _listing = listing.toString();
  }

  final List<FakeWorktreeEntry> entries;
  final Map<String, int> dirty;
  final Map<String, ({int behind, int ahead})> tracking;
  late final String _listing;

  Future<ProcessResult> call(String workingDirectory, List<String> args) async {
    if (args.contains('rev-parse') && args.contains('--git-common-dir')) {
      // Real Git prints an absolute common directory from a linked worktree and
      // a relative `.git` from the primary checkout; the absolute form is the
      // one the collector resolves against the caller toplevel.
      return ProcessResult(0, 0, '${p.join(entries.first.path, '.git')}\n', '');
    }
    if (args.contains('rev-parse') && args.contains('--show-toplevel')) {
      return ProcessResult(0, 0, '$workingDirectory\n', '');
    }
    if (args.contains('rev-parse') && args.contains('--abbrev-ref')) {
      return ProcessResult(0, 0, 'main\n', '');
    }
    if (args.contains('worktree') && args.contains('--porcelain')) {
      return ProcessResult(0, 0, _listing, '');
    }
    if (args.contains('status') && args.contains('--porcelain')) {
      final count = dirty[workingDirectory] ?? 0;
      return ProcessResult(0, 0, 'line\n' * count, '');
    }
    if (args.contains('rev-list')) {
      final counts = tracking[workingDirectory];
      if (counts == null) return ProcessResult(0, 128, '', 'unknown revision');
      return ProcessResult(0, 0, '${counts.behind}\t${counts.ahead}\n', '');
    }
    return ProcessResult(0, 1, '', 'unsupported fake git command: $args');
  }
}

/// One fake discovered Client with a launch profile naming its lease identity.
sanad_dev.ClientInstance fixtureInventoryClient({
  required int port,
  required int pid,
  required int gatewayPort,
  required String launcherId,
  required String nonce,
  required String home,
  bool withoutProfile = false,
}) {
  return sanad_dev.ClientInstance(
    port,
    'token-not-printed',
    p.join('fixture-source', 'client'),
    'macos',
    pid: pid,
    launchProfile: withoutProfile
        ? null
        : launch_profile.extractClientLaunchProfile([
            'flutter',
            'run',
            '--dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:$gatewayPort',
            '--dart-define=SANAD_HOME=$home',
            '--dart-define=SANAD_SHARED_PREFERENCES_PREFIX=',
            '--dart-define=SANAD_DEV_LAUNCHER_ID=$launcherId',
            '--dart-define=SANAD_DEV_RUNTIME_NONCE=$nonce',
          ]),
  );
}
