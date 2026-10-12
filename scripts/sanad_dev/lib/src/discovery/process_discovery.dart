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

Future<List<_ProcessSnapshot>> _discoverProcessSnapshots() {
  if (Platform.isWindows) return _discoverWindowsProcessSnapshots();
  if (Platform.isMacOS) return _discoverMacOsProcessSnapshots();
  if (Platform.isLinux) return _discoverLinuxProcessSnapshots();
  return Future.value(const []);
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
}) async {
  final instances = <ClientInstance>[];
  try {
    final processes = await _discoverProcessSnapshots();
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
        serviceToken =
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
          launchProfile: launchProfile,
        ),
      );
    }
  } catch (e) {
    print('Error discovering client instances: $e');
  }
  return instances;
}
