import 'dart:convert';
import 'dart:io';

import 'secure_runtime_file.dart';

class SanadDevRuntime {
  final String workspaceRoot;
  final String repositoryRoot;
  final String worktreeId;
  final bool isLinkedWorktree;
  final bool usesPrimaryResources;
  final int agentPort;
  final int vmServicePort;
  final String sanadHome;
  final String runtimeDirectory;
  final String branch;

  const SanadDevRuntime({
    required this.workspaceRoot,
    required this.repositoryRoot,
    required this.worktreeId,
    required this.isLinkedWorktree,
    required this.usesPrimaryResources,
    required this.agentPort,
    required this.vmServicePort,
    required this.sanadHome,
    required this.runtimeDirectory,
    required this.branch,
  });

  String get metadataPath => _join(runtimeDirectory, 'runtime.json');
  String get agentLogPath => _join(runtimeDirectory, 'agent.log');
  String get worktreeDisplayName => workspaceRoot
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty)
      .last;

  Map<String, dynamic> toJson({
    int? agentPid,
    int? clientPid,
    String status = 'starting',
    bool driverMode = false,
    bool cloudEnabled = false,
  }) => {
    'workspace_root': workspaceRoot,
    'repository_root': repositoryRoot,
    'worktree_id': worktreeId,
    'branch': branch,
    'is_linked_worktree': isLinkedWorktree,
    'uses_primary_resources': usesPrimaryResources,
    'agent_port': agentPort,
    'vm_service_port': vmServicePort,
    'sanad_home': sanadHome,
    'runtime_directory': runtimeDirectory,
    'agent_pid': agentPid,
    'client_pid': clientPid,
    'status': status,
    'driver_mode': driverMode,
    'cloud_enabled': cloudEnabled,
    'updated_at': DateTime.now().toUtc().toIso8601String(),
  };
}

class SanadDevRuntimeRecord {
  final Map<String, dynamic> data;

  const SanadDevRuntimeRecord(this.data);

  int? get agentPid => _asInt(data['agent_pid']);
  int? get clientPid => _asInt(data['client_pid']);
  int? get agentPort => _asInt(data['agent_port']);
  int? get vmServicePort => _asInt(data['vm_service_port']);
  String? get workspaceRoot => data['workspace_root']?.toString();
  String get status => data['status']?.toString() ?? 'unknown';

  static int? _asInt(Object? value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '');
  }
}

Future<SanadDevRuntime> discoverSanadDevRuntime({
  required String callerDirectory,
  Map<String, String>? environment,
  String? sanadHomeOverride,
}) async {
  final env = environment ?? Platform.environment;
  final workspaceRoot = await _gitOutput(callerDirectory, [
    'rev-parse',
    '--show-toplevel',
  ]);
  final branch = await _gitOutput(workspaceRoot, [
    'rev-parse',
    '--abbrev-ref',
    'HEAD',
  ]);
  final gitDirectory = await _gitOutput(workspaceRoot, [
    'rev-parse',
    '--absolute-git-dir',
  ]);
  final commonDirectoryRaw = await _gitOutput(workspaceRoot, [
    'rev-parse',
    '--git-common-dir',
  ]);
  final commonDirectory = _absolutePath(commonDirectoryRaw, workspaceRoot);
  final isLinkedWorktree =
      _canonicalPath(gitDirectory) != _canonicalPath(commonDirectory);

  final repositoryRoot = resolveRepositoryRoot(workspaceRoot);
  final worktreeId = deriveWorktreeId(workspaceRoot, branch);
  final home = _userHome(env);
  final runtimeRoot = env['SANAD_DEV_RUNTIME_ROOT']?.trim().isNotEmpty == true
      ? env['SANAD_DEV_RUNTIME_ROOT']!.trim()
      : _join(home, '.sanad', 'dev', 'runtimes');
  final sanadHome = resolveSanadDevHome(
    isLinkedWorktree: isLinkedWorktree,
    userHome: home,
    worktreeId: worktreeId,
    configuredSanadHome: env['SANAD_HOME'],
    sanadHomeOverride: sanadHomeOverride,
  );

  final usesPrimaryResources = resolveUsesPrimarySanadDevResources(
    isLinkedWorktree: isLinkedWorktree,
    sanadHomeOverride: sanadHomeOverride,
  );
  final agentStart = resolveSanadDevAgentPortStart(
    workspaceRoot: workspaceRoot,
    usesPrimaryResources: usesPrimaryResources,
  );
  final vmStart = 51000 + stableHash('$workspaceRoot:vm') % 1000;

  return SanadDevRuntime(
    workspaceRoot: workspaceRoot,
    repositoryRoot: repositoryRoot,
    worktreeId: worktreeId,
    isLinkedWorktree: isLinkedWorktree,
    usesPrimaryResources: usesPrimaryResources,
    agentPort: await findAvailablePort(
      start: agentStart,
      minimum: 58085,
      maximum: 58185,
    ),
    vmServicePort: await findAvailablePort(
      start: vmStart,
      minimum: 51000,
      maximum: 51999,
    ),
    sanadHome: sanadHome,
    runtimeDirectory: _join(runtimeRoot, worktreeId),
    branch: branch,
  );
}

bool resolveUsesPrimarySanadDevResources({
  required bool isLinkedWorktree,
  String? sanadHomeOverride,
}) {
  if (isLinkedWorktree) return false;
  final selector = sanadHomeOverride?.trim();
  return selector == null || selector.isEmpty || selector == 'user';
}

int resolveSanadDevAgentPortStart({
  required String workspaceRoot,
  required bool usesPrimaryResources,
}) {
  return usesPrimaryResources
      ? canonicalPrimaryAgentPort
      : 58086 + stableHash(workspaceRoot) % 100;
}

const int canonicalPrimaryAgentPort = 58085;

String resolveRepositoryRoot(String workspaceRoot) {
  final nested = Directory(_join(workspaceRoot, 'sanad-agent'));
  if (File(_join(nested.path, 'agent', 'pubspec.yaml')).existsSync() &&
      File(_join(nested.path, 'client', 'pubspec.yaml')).existsSync()) {
    return nested.path;
  }
  if (File(_join(workspaceRoot, 'agent', 'pubspec.yaml')).existsSync() &&
      File(_join(workspaceRoot, 'client', 'pubspec.yaml')).existsSync()) {
    return workspaceRoot;
  }
  throw StateError(
    'Could not locate sanad-agent/agent and sanad-agent/client under $workspaceRoot.',
  );
}

String deriveWorktreeId(String workspaceRoot, String branch) {
  final leaf = workspaceRoot
      .replaceAll('\\', '/')
      .split('/')
      .where((part) => part.isNotEmpty)
      .last;
  final readable = sanitizeRuntimeId(branch == 'HEAD' ? leaf : branch);
  final suffix = stableHash(
    _canonicalPath(workspaceRoot),
  ).toRadixString(16).padLeft(8, '0').substring(0, 8);
  return '$readable-$suffix';
}

String sanitizeRuntimeId(String value) {
  final normalized = value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (normalized.isEmpty) return 'worktree';
  return normalized.length <= 48 ? normalized : normalized.substring(0, 48);
}

bool resolveSanadDevCloudEnabled(Iterable<String> arguments) {
  var enabled = true;
  for (final argument in arguments) {
    if (argument == '--cloud') enabled = true;
    if (argument == '--no-cloud') enabled = false;
  }
  return enabled;
}

bool isSanadDevHomeSelector(String value) {
  return value.trim() == 'user' || isAbsoluteFileSystemPath(value);
}

String resolveSanadDevPreferencesPrefix({
  required bool isLinkedWorktree,
  required String sanadHome,
  String? sanadHomeSelector,
}) {
  final usesPrimaryUserPreferences =
      sanadHomeSelector == 'user' ||
      (!isLinkedWorktree && sanadHomeSelector == null);
  return usesPrimaryUserPreferences
      ? ''
      : deriveSanadDevPreferencesPrefix(sanadHome);
}

String resolveDefaultUserSanadHome(Map<String, String> environment) {
  return _join(_userHome(environment), '.sanad');
}

String deriveSanadDevPreferencesPrefix(String sanadHome) {
  final hash = stableHash(
    _canonicalPath(sanadHome),
  ).toRadixString(16).padLeft(8, '0');
  return 'sanad.$hash.';
}

Map<String, String> buildUnifiedSanadHomeEnvironment(
  Map<String, String> baseEnvironment, {
  required String sanadHome,
}) {
  return Map<String, String>.from(baseEnvironment)
    ..remove('SANAD_STATE_HOME')
    ..['SANAD_HOME'] = sanadHome;
}

String resolveSanadDevHome({
  required bool isLinkedWorktree,
  required String userHome,
  required String worktreeId,
  String? configuredSanadHome,
  String? sanadHomeOverride,
}) {
  final explicitSanadHome = sanadHomeOverride?.trim();
  if (explicitSanadHome != null && explicitSanadHome.isNotEmpty) {
    final configured = configuredSanadHome?.trim();
    if (explicitSanadHome == 'user') {
      return configured != null && configured.isNotEmpty
          ? configured
          : _join(userHome, '.sanad');
    }
    if (!isAbsoluteFileSystemPath(explicitSanadHome)) {
      throw const FormatException(
        'Sanad home must be "user" or an absolute path.',
      );
    }
    return explicitSanadHome;
  }
  if (isLinkedWorktree) {
    return _join(_join(userHome, '.sanad', 'dev', 'homes'), worktreeId);
  }
  final configured = configuredSanadHome?.trim();
  return configured != null && configured.isNotEmpty
      ? configured
      : _join(userHome, '.sanad');
}

bool isAbsoluteFileSystemPath(String value) {
  final path = value.trim();
  if (path.isEmpty) return false;
  if (Platform.isWindows) {
    return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path) || path.startsWith(r'\\');
  }
  return path.startsWith(Platform.pathSeparator);
}

int stableHash(String value) {
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0x7fffffff;
  }
  return hash;
}

Future<int> findAvailablePort({
  required int start,
  required int minimum,
  required int maximum,
}) async {
  if (minimum > maximum || start < minimum || start > maximum) {
    throw ArgumentError(
      'Invalid port range $minimum..$maximum (start: $start).',
    );
  }
  final count = maximum - minimum + 1;
  for (var offset = 0; offset < count; offset++) {
    final port = minimum + ((start - minimum + offset) % count);
    ServerSocket? socket;
    try {
      socket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
      return port;
    } on SocketException {
      // Probe the next deterministic candidate.
    } finally {
      await socket?.close();
    }
  }
  throw StateError('No available port in range $minimum..$maximum.');
}

Future<void> writeRuntimeRecord(
  SanadDevRuntime runtime,
  Map<String, dynamic> data,
) async {
  await secureRuntimeAtomicWrite(
    runtime.runtimeDirectory,
    runtime.metadataPath,
    '${const JsonEncoder.withIndent('  ').convert(data)}\n',
  );
}

Future<SanadDevRuntimeRecord?> readRuntimeRecord(
  SanadDevRuntime runtime,
) async {
  final file = File(runtime.metadataPath);
  if (!await file.exists()) return null;
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is Map<String, dynamic>) {
      return SanadDevRuntimeRecord(decoded);
    }
  } catch (_) {}
  return null;
}

Future<bool> isProcessRunning(int? pid) async {
  if (pid == null || pid <= 0) return false;
  if (Platform.isWindows) {
    final result = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/NH']);
    return result.exitCode == 0 && result.stdout.toString().contains('$pid');
  }
  final result = await Process.run('kill', ['-0', '$pid']);
  return result.exitCode == 0;
}

Future<String> _gitOutput(String workingDirectory, List<String> args) async {
  ProcessResult result;
  try {
    result = await Process.run('git', ['-C', workingDirectory, ...args]);
  } on ProcessException catch (_) {
    stderr.writeln(
      'Error: Git is not installed or could not be found in your PATH.',
    );
    stderr.writeln('Please install Git to use the sanad-dev CLI.');
    exit(1);
  } catch (e) {
    stderr.writeln('Error: Failed to execute Git command: $e');
    exit(1);
  }

  if (result.exitCode != 0) {
    final errorMsg = result.stderr.toString().trim();
    if (errorMsg.contains('not a git repository')) {
      stderr.writeln(
        'Error: The directory "$workingDirectory" is not a Git repository.',
      );
      stderr.writeln(
        'sanad-dev requires a Git repository to manage worktree environments.',
      );
    } else {
      stderr.writeln('Error: Git command failed in "$workingDirectory".');
      stderr.writeln('Command: git -C $workingDirectory ${args.join(' ')}');
      stderr.writeln('Details: $errorMsg');
    }
    exit(1);
  }
  return result.stdout.toString().trim();
}

String _userHome(Map<String, String> environment) {
  final home = Platform.isWindows
      ? environment['USERPROFILE']
      : environment['HOME'];
  if (home == null || home.trim().isEmpty) {
    throw StateError('Could not determine the user home directory.');
  }
  return home.trim();
}

String _absolutePath(String path, String base) {
  if (path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path)) {
    return path;
  }
  return _join(base, path);
}

String _canonicalPath(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } catch (_) {
    return Directory(path).absolute.path;
  }
}

String _join(String first, [String? second, String? third, String? fourth]) {
  final separator = Platform.pathSeparator;
  return [first, second, third, fourth]
      .whereType<String>()
      .where((part) => part.isNotEmpty)
      .map((part) => part.replaceAll(RegExp(r'[\\/]+$'), ''))
      .join(separator);
}
