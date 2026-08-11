import 'dart:convert';
import 'dart:io';

import 'client_launch_profile.dart';
import 'secure_runtime_file.dart';

const runtimeSwitchManifestVersion = 2;
const activeRuntimeSwitchStatuses = {'requested', 'draining', 'starting'};

bool isActiveRuntimeSwitch(RuntimeSwitchRequest request) =>
    activeRuntimeSwitchStatuses.contains(request.status);

bool isRuntimeSwitchOwnedByLauncher(
  RuntimeSwitchRequest request, {
  required String launcherId,
  required String runtimeNonce,
}) =>
    request.launcherId == launcherId && request.runtimeNonce == runtimeNonce;

class RuntimeSwitchRequest {
  const RuntimeSwitchRequest({
    required this.id,
    required this.agentPort,
    required this.targetRepositoryRoot,
    required this.targetWorkspaceHash,
    required this.targetWorktreeName,
    required this.targetBranch,
    required this.targetIsLinkedWorktree,
    required this.requestedAt,
    required this.launcherId,
    required this.runtimeNonce,
    this.requesterSessionId,
    this.requesterToolCallId,
    this.status = 'requested',
    this.message,
  });

  final String id;
  final int agentPort;
  final String targetRepositoryRoot;
  final String targetWorkspaceHash;
  final String targetWorktreeName;
  final String targetBranch;
  final bool targetIsLinkedWorktree;
  final DateTime requestedAt;
  final String launcherId;
  final String runtimeNonce;
  final String? requesterSessionId;
  final String? requesterToolCallId;
  final String status;
  final String? message;

  RuntimeSwitchRequest copyWith({String? status, String? message}) {
    return RuntimeSwitchRequest(
      id: id,
      agentPort: agentPort,
      targetRepositoryRoot: targetRepositoryRoot,
      targetWorkspaceHash: targetWorkspaceHash,
      targetWorktreeName: targetWorktreeName,
      targetBranch: targetBranch,
      targetIsLinkedWorktree: targetIsLinkedWorktree,
      requestedAt: requestedAt,
      launcherId: launcherId,
      runtimeNonce: runtimeNonce,
      requesterSessionId: requesterSessionId,
      requesterToolCallId: requesterToolCallId,
      status: status ?? this.status,
      message: message ?? this.message,
    );
  }

  Map<String, Object?> toJson() => {
    'version': runtimeSwitchManifestVersion,
    'id': id,
    'agent_port': agentPort,
    'target_repository_root': targetRepositoryRoot,
    'target_workspace_hash': targetWorkspaceHash,
    'target_worktree_name': targetWorktreeName,
    'target_branch': targetBranch,
    'target_is_linked_worktree': targetIsLinkedWorktree,
    'requested_at': requestedAt.toUtc().toIso8601String(),
    'launcher_id': launcherId,
    'runtime_nonce': runtimeNonce,
    'requester_session_id': requesterSessionId,
    'requester_tool_call_id': requesterToolCallId,
    'status': status,
    'message': message,
  };

  static RuntimeSwitchRequest fromJson(Map<String, dynamic> json) {
    if (json['version'] != runtimeSwitchManifestVersion) {
      throw const FormatException(
        'Unsupported runtime switch manifest version.',
      );
    }
    final request = RuntimeSwitchRequest(
      id: _requiredString(json, 'id'),
      agentPort: _requiredInt(json, 'agent_port'),
      targetRepositoryRoot: _requiredString(json, 'target_repository_root'),
      targetWorkspaceHash: _requiredString(json, 'target_workspace_hash'),
      targetWorktreeName: _requiredString(json, 'target_worktree_name'),
      targetBranch: _requiredString(json, 'target_branch'),
      targetIsLinkedWorktree: _requiredBool(json, 'target_is_linked_worktree'),
      requestedAt: DateTime.parse(_requiredString(json, 'requested_at')),
      launcherId: _requiredString(json, 'launcher_id'),
      runtimeNonce: _requiredString(json, 'runtime_nonce'),
      requesterSessionId: _optionalString(json['requester_session_id']),
      requesterToolCallId: _optionalString(json['requester_tool_call_id']),
      status: _optionalString(json['status']) ?? 'requested',
      message: _optionalString(json['message']),
    );
    if (request.status == 'requested') {
      validateRuntimeSwitchTarget(request);
    }
    return request;
  }
}

String runtimeSwitchManifestPath(String sanadHome, int agentPort) {
  return _join(sanadHome, 'dev', 'runtime-switch-$agentPort.json');
}

Future<void> writeRuntimeSwitchRequest(
  String path,
  RuntimeSwitchRequest request,
) async {
  final sanadHome = File(path).parent.parent.path;
  await secureRuntimeAtomicWrite(
    sanadHome,
    path,
    '${jsonEncode(request.toJson())}\n',
  );
}

Future<RuntimeSwitchRequest?> readRuntimeSwitchRequest(String path) async {
  final file = File(path);
  if (!await file.exists()) return null;
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map) {
    throw const FormatException('Runtime switch manifest must be an object.');
  }
  return RuntimeSwitchRequest.fromJson(Map<String, dynamic>.from(decoded));
}

class RuntimeSwitchManifestWarningGate {
  String? _lastInvalidRevision;

  Future<bool> shouldReport(String path, Object error) async {
    final file = File(path);
    String revision;
    try {
      final stat = await file.stat();
      revision = '${stat.modified.microsecondsSinceEpoch}:${stat.size}:$error';
    } on FileSystemException {
      revision = 'unavailable:$error';
    }
    if (_lastInvalidRevision == revision) return false;
    _lastInvalidRevision = revision;
    return true;
  }

  void reset() => _lastInvalidRevision = null;
}

void validateRuntimeSwitchTarget(RuntimeSwitchRequest request) {
  if (!isAbsoluteSwitchPath(request.targetRepositoryRoot)) {
    throw const FormatException('Runtime switch target must be absolute.');
  }
  final root = Directory(request.targetRepositoryRoot);
  final agentEntry = File(_join(root.path, 'agent', 'bin', 'sanad_agent.dart'));
  final clientPackage = File(_join(root.path, 'client', 'pubspec.yaml'));
  if (!agentEntry.existsSync() || !clientPackage.existsSync()) {
    throw const FormatException(
      'Runtime switch target is not a Sanad source checkout.',
    );
  }
}

List<List<String>> buildSwitchedClientGroupArguments({
  required List<ClientLaunchProfile> profiles,
  required List<int> vmServicePorts,
  required List<String> deviceIds,
  required String targetWorktreeName,
  required String targetBranch,
  required bool targetIsLinkedWorktree,
}) {
  if (profiles.length != vmServicePorts.length ||
      profiles.length != deviceIds.length) {
    throw const FormatException(
      'Runtime client profiles, VM ports, and devices must have equal lengths.',
    );
  }
  return List.generate(
    profiles.length,
    (index) => buildSwitchedClientRunArguments(
      currentProfile: profiles[index],
      targetWorktreeName: targetWorktreeName,
      targetBranch: targetBranch,
      targetIsLinkedWorktree: targetIsLinkedWorktree,
      vmServicePort: vmServicePorts[index],
      deviceId: deviceIds[index],
    ),
    growable: false,
  );
}

List<String> buildSwitchedClientRunArguments({
  required ClientLaunchProfile currentProfile,
  required String targetWorktreeName,
  required String targetBranch,
  String? targetWorkspaceHash,
  required bool targetIsLinkedWorktree,
  required int vmServicePort,
  required String deviceId,
}) {
  final compileArguments = <String>[];
  for (final argument in currentProfile.compileArguments) {
    if (argument.startsWith('--dart-define=SANAD_DEV_WORKTREE_NAME=') ||
        argument.startsWith('--dart-define=SANAD_DEV_WORKTREE_BRANCH=') ||
        (targetWorkspaceHash != null &&
            argument.startsWith('--dart-define=SANAD_DEV_WORKSPACE_HASH='))) {
      continue;
    }
    compileArguments.add(argument);
  }
  if (targetWorkspaceHash != null) {
    compileArguments.add(
      '--dart-define=SANAD_DEV_WORKSPACE_HASH=$targetWorkspaceHash',
    );
  }
  if (targetIsLinkedWorktree) {
    compileArguments.add(
      '--dart-define=SANAD_DEV_WORKTREE_NAME=$targetWorktreeName',
    );
    compileArguments.add(
      '--dart-define=SANAD_DEV_WORKTREE_BRANCH=$targetBranch',
    );
  }

  return [
    'flutter',
    'run',
    '-d',
    deviceId,
    ...compileArguments,
    '--host-vmservice-port=$vmServicePort',
    '--disable-service-auth-codes',
    if (currentProfile.target != null && currentProfile.target!.isNotEmpty) ...[
      '-t',
      currentProfile.target!,
    ],
  ];
}

List<int> orderUnixProcessTree(String processListing, int rootPid) {
  final children = <int, List<int>>{};
  for (final line in LineSplitter.split(processListing)) {
    final match = RegExp(r'^\s*(\d+)\s+(\d+)\s*$').firstMatch(line);
    if (match == null) continue;
    final processId = int.parse(match.group(1)!);
    final parentId = int.parse(match.group(2)!);
    children.putIfAbsent(parentId, () => <int>[]).add(processId);
  }
  final ordered = <int>[];
  void visit(int processId) {
    ordered.add(processId);
    for (final child in children[processId] ?? const <int>[]) {
      visit(child);
    }
  }

  visit(rootPid);
  return ordered;
}

bool isAbsoluteSwitchPath(String value) {
  if (Platform.isWindows) {
    return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) ||
        value.startsWith(r'\\');
  }
  return value.startsWith('/');
}

String? _optionalString(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = _optionalString(json[key]);
  if (value == null)
    throw FormatException('Missing runtime switch field: $key');
  return value;
}

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is int) return value;
  final parsed = int.tryParse('$value');
  if (parsed == null)
    throw FormatException('Invalid runtime switch field: $key');
  return parsed;
}

bool _requiredBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  throw FormatException('Invalid runtime switch field: $key');
}

String _join(String first, String second, [String? third, String? fourth]) {
  return [first, second, third, fourth]
      .whereType<String>()
      .map((part) => part.replaceAll(RegExp(r'[\\/]+$'), ''))
      .join(Platform.pathSeparator);
}
