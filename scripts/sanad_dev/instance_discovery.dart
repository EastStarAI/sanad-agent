part of '../sanad_dev.dart';

class _ProcessSnapshot {
  const _ProcessSnapshot(this.pid, this.arguments);

  final int pid;
  final List<String> arguments;

  String get searchableCommand => arguments.join(' ');
}

class ClientInstance {
  final int port;
  final String token;
  final String path;
  final String? deviceId;
  final int? pid;
  final ClientLaunchProfile? launchProfile;
  ClientInstance(
    this.port,
    this.token,
    this.path,
    this.deviceId, {
    this.pid,
    this.launchProfile,
  });
}

enum ClientSelectionKind { exact, missing, ambiguous }

class ClientSelectionResult {
  const ClientSelectionResult(this.kind, this.matches);

  final ClientSelectionKind kind;
  final List<ClientInstance> matches;

  ClientInstance? get selected =>
      kind == ClientSelectionKind.exact ? matches.single : null;
}

ClientSelectionResult selectClientByDevice({
  required Iterable<ClientInstance> clients,
  String? deviceId,
  int? vmServicePort,
}) {
  final matches = clients.where((client) {
    if (deviceId != null && client.deviceId != deviceId) return false;
    if (vmServicePort != null && client.port != vmServicePort) return false;
    return true;
  }).toList()..sort((left, right) => left.port.compareTo(right.port));
  return ClientSelectionResult(
    matches.isEmpty
        ? ClientSelectionKind.missing
        : matches.length == 1
        ? ClientSelectionKind.exact
        : ClientSelectionKind.ambiguous,
    List.unmodifiable(matches),
  );
}

int? clientAgentPort(ClientInstance client) {
  final gateway = Uri.tryParse(
    client.launchProfile?.define('LOCAL_GATEWAY_URL') ?? '',
  );
  return gateway?.hasPort == true ? gateway!.port : null;
}

List<ClientInstance> clientsForAgentPort(
  Iterable<ClientInstance> clients,
  int agentPort,
) {
  final matches = clients
      .where((client) => clientAgentPort(client) == agentPort)
      .toList();
  matches.sort((left, right) {
    final byDevice = (left.deviceId ?? '').compareTo(right.deviceId ?? '');
    return byDevice != 0 ? byDevice : left.port.compareTo(right.port);
  });
  return matches;
}

Future<List<ClientInstance>> discoverClientInstances() async {
  final instances = <ClientInstance>[];
  try {
    final processes = await _discoverProcessSnapshots();
    final runtime = await _currentRuntime();

    // First, find all development-service processes
    final devServices = <Map<String, dynamic>>[];
    for (final process in processes) {
      final line = process.searchableCommand;
      if (line.contains('development-service')) {
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
              runtimeRepositoryRoot: runtime.repositoryRoot,
              runtimeIsLinkedWorktree: runtime.isLinkedWorktree,
              runtimeWorktreeName: runtime.worktreeDisplayName,
              separator: Platform.pathSeparator,
            );
            deviceId = launchProfile.deviceId;
            break;
          }
        }
      }
      instances.add(
        ClientInstance(
          port,
          ds['token'] as String,
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
  return command.contains('development-service') ||
      command.contains('flutter_tools') ||
      command.contains('flutter run');
}

class AgentInstance {
  final int port;
  final String workspaceHash;
  final String stateMode;
  final bool gatewayEnabled;
  final String? launcherId;
  final String? runtimeNonce;
  final String? sanadHome;
  AgentInstance(
    this.port,
    this.workspaceHash,
    this.stateMode, {
    this.gatewayEnabled = false,
    this.launcherId,
    this.runtimeNonce,
    this.sanadHome,
  });
}

Future<List<AgentInstance>> discoverAgentInstances() async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(milliseconds: 150);
  final instances = <AgentInstance>[];
  final runtime = await _currentRuntime();
  final candidateHomes = await discoverLocalGatewayCandidateHomes(runtime);
  final credentials = <({String home, String value})>[];
  for (final home in candidateHomes) {
    try {
      credentials.add((
        home: home,
        value: await readLocalGatewayCredential(home),
      ));
    } on LocalGatewayCredentialUnavailable {
      // A runtime without a started daemon may not have generated a token yet.
    }
  }
  final credentialCounts = <String, int>{};
  for (final credential in credentials) {
    credentialCounts.update(
      credential.value,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }
  credentials.removeWhere(
    (credential) => credentialCounts[credential.value] != 1,
  );

  final futures = <Future>[];
  // Scan the default and worktree allocation range.
  for (int port = 58085; port <= 58185; port++) {
    futures.add(() async {
      for (final credential in credentials) {
        try {
          final request = await client.getUrl(
            Uri.parse('http://localhost:$port/health'),
          );
          request.headers.set(localGatewayCredentialHeader, credential.value);
          final response = await request.close().timeout(
            const Duration(milliseconds: 150),
          );
          if (response.statusCode == 200) {
            final body = await response.transform(utf8.decoder).join();
            final data = json.decode(body);
            if (data['status'] == 'ok') {
              final workspaceHash =
                  data['workspace_hash'] as String? ?? 'unknown';
              final stateMode = data['state_mode'] as String? ?? 'default';
              final gatewayEnabled = data['gateway_enabled'] == true;
              instances.add(
                AgentInstance(
                  port,
                  workspaceHash,
                  stateMode,
                  gatewayEnabled: gatewayEnabled,
                  launcherId: data['dev_launcher_id'] as String?,
                  runtimeNonce: data['dev_runtime_nonce'] as String?,
                  sanadHome: credential.home,
                ),
              );
              return;
            }
          } else {
            await response.drain();
          }
        } catch (_) {}
      }
    }());
  }
  await Future.wait(futures);
  client.close(force: true);
  return instances;
}

Future<Set<String>> discoverLocalGatewayCandidateHomes(
  SanadDevRuntime runtime,
) async {
  final primaryHome = resolveDefaultUserSanadHome(Platform.environment);
  final homes = <String>{runtime.sanadHome, primaryHome};

  final linkedHomes = Directory(
    '$primaryHome${Platform.pathSeparator}dev${Platform.pathSeparator}homes',
  );
  if (await linkedHomes.exists()) {
    await for (final entity in linkedHomes.list(followLinks: false)) {
      if (await FileSystemEntity.type(entity.path, followLinks: false) ==
          FileSystemEntityType.directory) {
        homes.add(entity.path);
      }
    }
  }

  final runtimeRoot = Directory(runtime.runtimeDirectory).parent;
  if (await runtimeRoot.exists()) {
    await for (final entity in runtimeRoot.list(followLinks: false)) {
      if (await FileSystemEntity.type(entity.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      final metadata = File(
        '${entity.path}${Platform.pathSeparator}runtime.json',
      );
      try {
        final decoded = jsonDecode(
          await secureRuntimeReadText(entity.path, metadata.path),
        );
        if (decoded is Map) {
          final home = decoded['sanad_home']?.toString().trim();
          if (home != null && home.isNotEmpty) homes.add(home);
        }
      } on Object {
        // Stale, missing, or unsafe metadata cannot grant discovery access.
      }
    }
  }
  return homes;
}

Future<ClientInstance?> selectClientInstance(int? portOverride) async {
  final instances = await discoverClientInstances();
  if (instances.isEmpty) {
    print(
      'Error: No running client instances found. Make sure the client app is running in debug mode.',
    );
    exit(1);
  }

  if (portOverride != null) {
    for (final inst in instances) {
      if (inst.port == portOverride) {
        return inst;
      }
    }
    final recorded = await _recordedClientInstance(portOverride);
    if (recorded != null) return recorded;
    print('Error: No running client instance found on port $portOverride.');
    print('Active instances:');
    for (final inst in instances) {
      print('  Port: ${inst.port} | Path: ${inst.path}');
    }
    exit(1);
  }

  final runtime = await _currentRuntime();
  final state = selectRuntimeProcessState(
    activeAgents: await discoverAgentInstances(),
    activeClients: instances,
    runtime: runtime,
  );
  final matchingInstances = state.ownedClients;
  final launcherMatchedInstances = matchingInstances
      .where((client) {
        final profile = client.launchProfile;
        return state.agent?.launcherId != null &&
            state.agent?.runtimeNonce != null &&
            profile?.define('SANAD_DEV_LAUNCHER_ID') ==
                state.agent!.launcherId &&
            profile?.define('SANAD_DEV_RUNTIME_NONCE') ==
                state.agent!.runtimeNonce;
      })
      .toList(growable: false);

  if (launcherMatchedInstances.length == 1) {
    return launcherMatchedInstances.single;
  }

  if (matchingInstances.length == 1) {
    return matchingInstances.first;
  }

  if (matchingInstances.isEmpty) {
    print(
      'Error: No running client instances found for the current worktree (${runtime.worktreeId}).',
    );
    print('Active instances in other worktrees:');
    for (final inst in instances) {
      print('  Port: ${inst.port} | Path: ${inst.path}');
    }
    exit(1);
  }

  print(
    'Error: Multiple running client instances found for the current worktree. Please specify which instance to target using the -p/--port option:',
  );
  for (final inst in matchingInstances) {
    print('  Port: ${inst.port} | Path: ${inst.path}');
  }
  exit(1);
}

Future<ClientInstance?> _recordedClientInstance(int port) async {
  try {
    final runtime = await _currentRuntime();
    final record = await readRuntimeRecord(runtime);
    if (record?.vmServicePort != port ||
        !await isProcessRunning(record?.clientPid)) {
      return null;
    }

    final socket = await WebSocket.connect(
      'ws://127.0.0.1:$port/ws',
    ).timeout(const Duration(milliseconds: 500));
    await socket.close();
    return ClientInstance(
      port,
      '',
      '${runtime.repositoryRoot}${Platform.pathSeparator}client',
      _defaultDesktopDevice(),
    );
  } catch (_) {
    return null;
  }
}

Future<AgentInstance?> selectAgentInstance(int? portOverride) async {
  final instances = await discoverAgentInstances();
  if (instances.isEmpty) {
    print(
      'Error: No running agent instances found. Make sure the agent daemon is running.',
    );
    exit(1);
  }

  if (portOverride != null) {
    for (final inst in instances) {
      if (inst.port == portOverride) {
        return inst;
      }
    }
    print('Error: No running agent instance found on port $portOverride.');
    print('Active instances:');
    for (final inst in instances) {
      print('  Port: ${inst.port} (Workspace Hash: ${inst.workspaceHash})');
    }
    exit(1);
  }

  // Filter instances matching the current worktree's workspace root hash
  final runtime = await _currentRuntime();
  final currentWorkspaceHash = runtime.worktreeId.split('-').last;
  final matchingInstances = instances
      .where((inst) => inst.workspaceHash == currentWorkspaceHash)
      .toList();

  if (matchingInstances.length == 1) {
    return matchingInstances.first;
  }

  if (matchingInstances.isEmpty) {
    print(
      'Error: No running agent instances found for the current worktree (${runtime.worktreeId}).',
    );
    print('Active instances in other worktrees:');
    for (final inst in instances) {
      print('  Port: ${inst.port} (Workspace Hash: ${inst.workspaceHash})');
    }
    exit(1);
  }

  print(
    'Error: Multiple running agent instances found for the current worktree. Please specify which instance to target using the -p/--port option:',
  );
  for (final inst in matchingInstances) {
    print('  Port: ${inst.port} (Workspace Hash: ${inst.workspaceHash})');
  }
  exit(1);
}
