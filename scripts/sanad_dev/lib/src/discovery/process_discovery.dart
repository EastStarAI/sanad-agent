part of '../../sanad_dev_cli.dart';

class _ProcessSnapshot {
  const _ProcessSnapshot(this.pid, this.arguments);

  final int pid;
  final List<String> arguments;

  String get searchableCommand => arguments.join(' ');
}

bool isDartDevelopmentServiceProcess(List<String> arguments) {
  final command = arguments.join(' ').toLowerCase();
  if (command.contains('development-service')) return true;
  final launchesDdsSnapshot =
      command.contains('dds_aot.dart.snapshot') ||
      command.contains('dds.dart.snapshot');
  return launchesDdsSnapshot &&
      arguments.any((argument) => argument.startsWith('--vm-service-uri=')) &&
      arguments.any((argument) => argument.startsWith('--bind-port=')) &&
      arguments.contains('--serve-devtools');
}

String? latestVmServiceAuthCodeFromJournalLines(
  Iterable<String> lines, {
  required int vmServicePort,
}) {
  final pattern = RegExp(
    '(?:http|ws)://127\\.0\\.0\\.1:$vmServicePort/'
    r'([A-Za-z0-9_\-=]+)/?(?:ws)?',
  );
  for (final line in lines.toList(growable: false).reversed) {
    final match = pattern.firstMatch(line);
    if (match != null) return match.group(1);
  }
  return null;
}

Future<String?> managedVmServiceAuthCodeFromJournal({
  required ClientLaunchProfile profile,
  required int vmServicePort,
}) async {
  final sanadHome = profile.define('SANAD_HOME');
  final gateway = Uri.tryParse(profile.define('LOCAL_GATEWAY_URL') ?? '');
  if (sanadHome == null || sanadHome.isEmpty || gateway?.hasPort != true) {
    return null;
  }
  try {
    final lines = await readComponentJournalTail(
      sanadHome: sanadHome,
      agentPort: gateway!.port,
      key: componentJournalKey(
        component: 'client',
        vmServicePort: vmServicePort,
      ),
      lines: 80,
    );
    return latestVmServiceAuthCodeFromJournalLines(
      lines,
      vmServicePort: vmServicePort,
    );
  } on Object {
    // Journals provide only the Web VM authentication code for diagnostics;
    // process arguments and the launcher lease remain ownership evidence.
    return null;
  }
}

bool matchesFlutterRunnerToDevelopmentService(
  List<String> arguments, {
  required int? devToolsPort,
  required int? bindPort,
  required int originalPort,
}) {
  final command = arguments.join(' ');
  if (devToolsPort != null && command.contains(':$devToolsPort')) return true;
  if (bindPort != null &&
      bindPort != 0 &&
      arguments.contains('--host-vmservice-port=$bindPort')) {
    return true;
  }
  return arguments.contains('--host-vmservice-port=$originalPort');
}

Future<List<_ProcessSnapshot>> discoverProcessSnapshots({
  Iterable<int>? candidatePids,
}) {
  if (candidatePids != null && _supportsCandidateArgumentReads) {
    return _readCandidateProcessSnapshots(candidatePids);
  }
  if (Platform.isWindows) return _discoverWindowsProcessSnapshots();
  if (Platform.isMacOS) return _discoverMacOsProcessSnapshots();
  if (Platform.isLinux) return _discoverLinuxProcessSnapshots();
  return Future.value(const []);
}

/// Whether one process's argument vector can be read without listing the whole
/// process table. Windows resolves a process command line through CIM, which is
/// the same cost as the full scan, so it keeps using the full scan.
bool get _supportsCandidateArgumentReads =>
    Platform.isMacOS || Platform.isLinux;

/// Reads only the argument vectors of [candidatePids] instead of scanning the
/// whole process table.
///
/// The caller already holds those ids from an earlier full discovery, so this is
/// the same live OS evidence for a known set of processes; a pid that vanished,
/// was reused by an unrelated process, or no longer matches the expected shape
/// simply drops out of the result.
Future<List<_ProcessSnapshot>> _readCandidateProcessSnapshots(
  Iterable<int> candidatePids,
) async {
  final snapshots = <_ProcessSnapshot>[];
  for (final pid in candidatePids) {
    if (pid <= 0) continue;
    final arguments = await _readProcessArguments(pid);
    if (arguments.isEmpty) continue;
    if (_isRelevantClientProcess(arguments)) {
      snapshots.add(_ProcessSnapshot(pid, arguments));
    }
  }
  return snapshots;
}

Future<List<String>> _readProcessArguments(int pid) async {
  if (Platform.isMacOS) return readMacOsProcessArguments(pid);
  if (Platform.isLinux) {
    try {
      final bytes = await File('/proc/$pid/cmdline').readAsBytes();
      return splitNullTerminatedArguments(bytes);
    } on FileSystemException {
      return const [];
    }
  }
  return const [];
}

Future<List<_ProcessSnapshot>> _discoverLinuxProcessSnapshots() async {
  final snapshots = <_ProcessSnapshot>[];
  final proc = Directory('/proc');
  if (!await proc.exists()) return snapshots;
  await for (final entity in proc.list(followLinks: false)) {
    final pid = int.tryParse(entity.path.split(Platform.pathSeparator).last);
    if (pid == null) continue;
    try {
      final bytes = await File('${entity.path}/cmdline').readAsBytes();
      final arguments = splitNullTerminatedArguments(bytes);
      if (_isRelevantClientProcess(arguments)) {
        snapshots.add(_ProcessSnapshot(pid, arguments));
      }
    } on FileSystemException {
      // Processes can exit, or become unreadable, during discovery.
    }
  }
  return snapshots;
}

Future<List<_ProcessSnapshot>> _discoverMacOsProcessSnapshots() async {
  final listing = await Process.run('ps', ['-axo', 'pid=,comm=']);
  if (listing.exitCode != 0) return const [];
  final candidates = <int>[];
  for (final line in LineSplitter.split(listing.stdout as String)) {
    final match = RegExp(r'^\s*(\d+)\s+(.+)$').firstMatch(line);
    if (match == null) continue;
    final executable = match.group(2)!.toLowerCase();
    if (executable.contains('dart') || executable.contains('flutter')) {
      candidates.add(int.parse(match.group(1)!));
    }
  }

  final argumentsByProcess = await readMacOsCandidateArguments(
    candidates,
    (pid) async => readMacOsProcessArguments(pid),
  );
  final snapshots = <_ProcessSnapshot>[];
  for (final entry in argumentsByProcess.entries) {
    final arguments = entry.value;
    if (_isRelevantClientProcess(arguments)) {
      snapshots.add(_ProcessSnapshot(entry.key, arguments));
    }
  }
  return snapshots;
}

Future<List<_ProcessSnapshot>> _discoverWindowsProcessSnapshots() async {
  const command = r'''
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SanadCommandLine {
  [DllImport("shell32.dll", SetLastError = true)]
  static extern IntPtr CommandLineToArgvW(
    [MarshalAs(UnmanagedType.LPWStr)] string commandLine,
    out int argc);
  [DllImport("kernel32.dll")]
  static extern IntPtr LocalFree(IntPtr pointer);
  public static string[] Split(string commandLine) {
    if (String.IsNullOrEmpty(commandLine)) return new string[0];
    int argc;
    IntPtr argv = CommandLineToArgvW(commandLine, out argc);
    if (argv == IntPtr.Zero) return new string[0];
    try {
      string[] result = new string[argc];
      for (int i = 0; i < argc; i++) {
        result[i] = Marshal.PtrToStringUni(
          Marshal.ReadIntPtr(argv, i * IntPtr.Size));
      }
      return result;
    } finally {
      LocalFree(argv);
    }
  }
}
'@
Get-CimInstance Win32_Process |
  Where-Object { $_.Name -match 'dart|flutter' } |
  ForEach-Object {
    @{
      pid = [int]$_.ProcessId
      arguments = [SanadCommandLine]::Split($_.CommandLine)
    } | ConvertTo-Json -Compress
  }
''';
  final result = await Process.run('powershell', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    command,
  ]);
  if (result.exitCode != 0) return const [];
  final snapshots = <_ProcessSnapshot>[];
  for (final line in LineSplitter.split(result.stdout as String)) {
    try {
      final value = jsonDecode(line);
      if (value is! Map) continue;
      final pid = value['pid'];
      final rawArguments = value['arguments'];
      if (pid is! int || rawArguments is! List) continue;
      final arguments = rawArguments.map((value) => '$value').toList();
      if (_isRelevantClientProcess(arguments)) {
        snapshots.add(_ProcessSnapshot(pid, arguments));
      }
    } on FormatException {
      // A malformed process record is incomplete discovery and is ignored.
    }
  }
  return snapshots;
}

bool _isRelevantClientProcess(List<String> arguments) {
  final command = arguments.join(' ').toLowerCase();
  return isDartDevelopmentServiceProcess(arguments) ||
      command.contains('flutter_tools') ||
      command.contains('flutter run');
}

Future<List<ClientInstance>> discoverClientInstances({
  SanadDevRuntime? runtime,
  Iterable<int>? candidatePids,
}) async {
  final instances = <ClientInstance>[];
  try {
    final processes = await discoverProcessSnapshots(
      candidatePids: candidatePids,
    );
    final activeRuntime = runtime ?? await _currentRuntime();

    // First, find all Dart development-service processes. Native Flutter uses
    // the development-service entry point, while Flutter Web launches the DDS
    // AOT snapshot directly.
    final devServices = <Map<String, dynamic>>[];
    for (final process in processes) {
      final line = process.searchableCommand;
      if (isDartDevelopmentServiceProcess(process.arguments)) {
        final regExp = RegExp(
          r'--vm-service-uri=http://127.0.0.1:(\d+)(?:/([A-Za-z0-9_\-=]+))?/?',
        );
        final match = regExp.firstMatch(line);
        if (match != null) {
          final originalPort = int.parse(match.group(1)!);
          final token = match.group(2) ?? '';

          // Try to extract devtools server port to link to the flutter run process
          final devToolsMatch = RegExp(
            r'--devtools-server-address=http://127.0.0.1:(\d+)/?',
          ).firstMatch(line);
          final devToolsPort = devToolsMatch != null
              ? int.tryParse(devToolsMatch.group(1)!)
              : null;

          // Check if there is a non-zero --bind-port in the command line
          final bindPortMatch = RegExp(r'--bind-port=(\d+)').firstMatch(line);
          final bindPort = bindPortMatch != null
              ? int.tryParse(bindPortMatch.group(1)!)
              : null;

          final port = (bindPort != null && bindPort != 0)
              ? bindPort
              : originalPort;
          final existingIndex = devServices.indexWhere(
            (ds) => ds['port'] == port,
          );
          if (existingIndex != -1) {
            if (devToolsPort != null &&
                devServices[existingIndex]['devToolsPort'] == null) {
              devServices[existingIndex]['devToolsPort'] = devToolsPort;
            }
            continue;
          }

          devServices.add({
            'port': port,
            'token': token,
            'devToolsPort': devToolsPort,
            'bindPort': bindPort,
            'originalPort': originalPort,
            'processId': process.pid,
          });
        }
      }
    }

    // Now, find all flutter run processes to map devtools ports to target paths
    for (final ds in devServices) {
      String matchedPath = 'Unknown workspace';
      String? deviceId;
      int? clientPid;
      ClientLaunchProfile? launchProfile;
      List<String>? clientArguments;
      final devToolsPort = ds['devToolsPort'];
      final bindPort = ds['bindPort'];
      final originalPort = ds['originalPort'];
      final port = ds['port'] as int;

      for (final process in processes) {
        final line = process.searchableCommand;
        if ((line.contains('flutter_tools.snapshot') ||
                line.contains('flutter_tools') ||
                line.contains('flutter run')) &&
            line.contains('run')) {
          final isMatch = matchesFlutterRunnerToDevelopmentService(
            process.arguments,
            devToolsPort: devToolsPort as int?,
            bindPort: bindPort as int?,
            originalPort: originalPort as int,
          );

          if (isMatch) {
            clientPid = process.pid;
            clientArguments = process.arguments;
            launchProfile = extractClientLaunchProfile(process.arguments);
            matchedPath = resolveClientDirectoryForLaunchProfile(
              profile: launchProfile,
              runtimeRepositoryRoot: activeRuntime.repositoryRoot,
              runtimeIsLinkedWorktree: activeRuntime.isLinkedWorktree,
              runtimeWorktreeName: activeRuntime.worktreeDisplayName,
              separator: Platform.pathSeparator,
            );
            deviceId = launchProfile.deviceId;
            break;
          }
        }
      }
      var serviceToken = ds['token'] as String;
      if (launchProfile != null && bindPort != null && bindPort != 0) {
        // The live client records the authenticated DDS URI itself. Read that
        // before the journal and the upstream argument token, because a token
        // copied from `--vm-service-uri` belongs to a different port than the
        // DDS bind port and cannot authorize it.
        final sanadHome = launchProfile.define('SANAD_HOME');
        final recordedToken = sanadHome == null || sanadHome.isEmpty
            ? null
            : await readVmServiceAuthCodeFromOutFile(
                outFilePath: vmServiceOutFilePath(
                  sanadHome: sanadHome,
                  vmServicePort: port,
                ),
                expectedPort: port,
                liveClientArguments: clientArguments ?? const <String>[],
              );
        serviceToken =
            recordedToken ??
            await managedVmServiceAuthCodeFromJournal(
              profile: launchProfile,
              vmServicePort: port,
            ) ??
            serviceToken;
      }
      instances.add(
        ClientInstance(
          port,
          serviceToken,
          matchedPath,
          deviceId,
          pid: clientPid,
          devServicePid: ds['processId'] as int?,
          launchProfile: launchProfile,
        ),
      );
    }
  } catch (e) {
    print('Error discovering client instances: $e');
  }
  return instances;
}

/// One OS process table as `pid → parent pid`, or an empty map when the
/// platform cannot provide it.
///
/// Ownership evidence names *what* answers a port — the `/health` identity, the
/// Home holder record, the endpoint record — but it never says *which process
/// started it*. A proven reclaim needs that lineage, because the process that
/// respawns a daemon is its parent, not the daemon itself. The table is
/// read-only evidence: every pid still has to be proven before it is signalled.
Future<Map<int, int>> readProcessParentMap() async {
  if (Platform.isWindows) return _readWindowsProcessParentMap();
  final result = await Process.run('ps', ['-axo', 'pid=,ppid=']);
  if (result.exitCode != 0) return const {};
  return parseProcessParentMap(result.stdout.toString());
}

/// Parses a `pid ppid` table into a parent map.
Map<int, int> parseProcessParentMap(String listing) {
  final parents = <int, int>{};
  for (final line in LineSplitter.split(listing)) {
    final match = RegExp(r'^\s*(\d+)\s+(\d+)\s*$').firstMatch(line);
    if (match == null) continue;
    parents[int.parse(match.group(1)!)] = int.parse(match.group(2)!);
  }
  return parents;
}

Future<Map<int, int>> _readWindowsProcessParentMap() async {
  const script =
      '(Get-CimInstance Win32_Process | Select-Object ProcessId,'
      'ParentProcessId | ConvertTo-Json -Compress)';
  final result = await Process.run('powershell', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    script,
  ]);
  if (result.exitCode != 0) return const {};
  try {
    final decoded = jsonDecode(result.stdout.toString().trim());
    final entries = decoded is List ? decoded : <Object?>[decoded];
    final parents = <int, int>{};
    for (final entry in entries) {
      if (entry is! Map) continue;
      final child = int.tryParse('${entry['ProcessId']}');
      final parent = int.tryParse('${entry['ParentProcessId']}');
      if (child == null || parent == null || child <= 1) continue;
      parents[child] = parent;
    }
    return parents;
  } on Object {
    return const {};
  }
}

/// Every live descendant of [rootPid] in one parent map.
Set<int> processDescendants({
  required int rootPid,
  required Map<int, int> parentByPid,
}) {
  final children = <int, List<int>>{};
  parentByPid.forEach((child, parent) {
    if (child <= 1 || child == parent) return;
    children.putIfAbsent(parent, () => <int>[]).add(child);
  });
  final descendants = <int>{};
  final pending = <int>[rootPid];
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    for (final child in children[current] ?? const <int>[]) {
      if (!descendants.add(child)) continue;
      pending.add(child);
    }
  }
  return descendants;
}

/// Candidate lineage of [daemonPid], ordered outermost → daemon.
///
/// Bounded by [maxHops] and stopped at the first parent that is missing, `1`
/// (reparented to init/launchd), itself, or already in the chain. The result is
/// a *candidate* list: every pid still has to be proven by its own command.
List<int> agentDaemonChainCandidates({
  required int daemonPid,
  required Map<int, int> parentByPid,
  int maxHops = 4,
}) {
  if (daemonPid <= 1) return const [];
  final chain = <int>[daemonPid];
  var current = daemonPid;
  while (chain.length <= maxHops) {
    final parent = parentByPid[current];
    if (parent == null ||
        parent <= 1 ||
        parent == current ||
        chain.contains(parent)) {
      break;
    }
    chain.add(parent);
    current = parent;
  }
  return chain.reversed.toList(growable: false);
}

/// Whether one process identity (start time + command line) is an Agent runtime
/// process.
///
/// The supervisor, the source wrapper, and the supervised child all name the
/// Agent script or binary and the `daemon` role; the child additionally carries
/// `--child-process`.
bool isAgentRuntimeCommand(String? identity) {
  if (identity == null) return false;
  final text = identity.toLowerCase();
  return text.contains('sanad_agent') && text.contains('daemon');
}

/// The proven lineage of [daemonPid], ordered outermost → daemon.
///
/// Every returned pid named an Agent runtime command at proof time; the walk
/// stops at the first ancestor that is a *different* command, because that is
/// where the Agent lineage ends (a shell, an IDE, or the terminal). An ancestor
/// whose identity cannot be read is **not** a boundary: it is unproven, so the
/// whole chain is refused instead of shortened. Signalling a daemon whose
/// respawning supervisor is still alive cannot free the port, and guessing is
/// not permission to terminate a process.
Future<List<int>> proveAgentDaemonChain({
  required int daemonPid,
  Map<int, int>? parentByPid,
  Future<String?> Function(int pid) processIdentity = readProcessIdentity,
  int maxHops = 4,
}) async {
  final parents = parentByPid ?? await readProcessParentMap();
  final candidates = agentDaemonChainCandidates(
    daemonPid: daemonPid,
    parentByPid: parents,
    maxHops: maxHops,
  );
  if (candidates.isEmpty) return const [];
  final provenLeafFirst = <int>[];
  for (final pid in candidates.reversed) {
    final identity = await processIdentity(pid);
    if (identity == null) return const [];
    if (!isAgentRuntimeCommand(identity)) break;
    provenLeafFirst.add(pid);
  }
  return provenLeafFirst.reversed.toList(growable: false);
}

/// [proveAgentDaemonChain] with no optional arguments, for injection.
Future<List<int>> proveAgentDaemonChainForPid(int daemonPid) =>
    proveAgentDaemonChain(daemonPid: daemonPid);
