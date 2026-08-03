import 'dart:convert';
import 'dart:io';

import 'secure_runtime_file.dart';

const runtimeLauncherRecordVersion = 1;

enum RuntimeOwnershipClass {
  managed,
  manual,
  orphaned,
  crossOwned,
  unverifiable,
  ambiguous,
  stopped,
}

class RuntimeLauncherRecord {
  const RuntimeLauncherRecord({
    required this.launcherId,
    required this.runtimeNonce,
    required this.launcherPid,
    required this.launcherProcessIdentity,
    required this.workspaceHash,
    required this.sourceRoot,
    required this.agentPort,
    required this.sanadHome,
    required this.preferencesPrefix,
    required this.clientPids,
    required this.vmServicePorts,
    required this.status,
    required this.updatedAt,
  });

  final String launcherId;
  final String runtimeNonce;
  final int launcherPid;
  final String launcherProcessIdentity;
  final String workspaceHash;
  final String sourceRoot;
  final int agentPort;
  final String sanadHome;
  final String preferencesPrefix;
  final List<int> clientPids;
  final List<int> vmServicePorts;
  final String status;
  final DateTime updatedAt;

  RuntimeLauncherRecord copyWith({
    String? workspaceHash,
    String? sourceRoot,
    List<int>? clientPids,
    List<int>? vmServicePorts,
    String? status,
  }) {
    return RuntimeLauncherRecord(
      launcherId: launcherId,
      runtimeNonce: runtimeNonce,
      launcherPid: launcherPid,
      launcherProcessIdentity: launcherProcessIdentity,
      workspaceHash: workspaceHash ?? this.workspaceHash,
      sourceRoot: sourceRoot ?? this.sourceRoot,
      agentPort: agentPort,
      sanadHome: sanadHome,
      preferencesPrefix: preferencesPrefix,
      clientPids: clientPids ?? this.clientPids,
      vmServicePorts: vmServicePorts ?? this.vmServicePorts,
      status: status ?? this.status,
      updatedAt: DateTime.now().toUtc(),
    );
  }

  Map<String, Object?> toJson() => {
    'version': runtimeLauncherRecordVersion,
    'launcher_id': launcherId,
    'runtime_nonce': runtimeNonce,
    'launcher_pid': launcherPid,
    'launcher_process_identity': launcherProcessIdentity,
    'workspace_hash': workspaceHash,
    'source_root': sourceRoot,
    'agent_port': agentPort,
    'sanad_home': sanadHome,
    'preferences_prefix': preferencesPrefix,
    'client_pids': clientPids,
    'vm_service_ports': vmServicePorts,
    'status': status,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  static RuntimeLauncherRecord fromJson(Map<String, dynamic> json) {
    if (json['version'] != runtimeLauncherRecordVersion) {
      throw const FormatException('Unsupported runtime launcher record.');
    }
    return RuntimeLauncherRecord(
      launcherId: _requiredString(json, 'launcher_id'),
      runtimeNonce: _requiredString(json, 'runtime_nonce'),
      launcherPid: _requiredInt(json, 'launcher_pid'),
      launcherProcessIdentity: _requiredString(
        json,
        'launcher_process_identity',
      ),
      workspaceHash: _requiredString(json, 'workspace_hash'),
      sourceRoot: _requiredString(json, 'source_root'),
      agentPort: _requiredInt(json, 'agent_port'),
      sanadHome: _requiredString(json, 'sanad_home'),
      preferencesPrefix: json['preferences_prefix']?.toString() ?? '',
      clientPids: _intList(json['client_pids']),
      vmServicePorts: _intList(json['vm_service_ports']),
      status: _requiredString(json, 'status'),
      updatedAt: DateTime.parse(_requiredString(json, 'updated_at')).toUtc(),
    );
  }
}

String runtimeLauncherRecordPath(String sanadHome, int agentPort) {
  return [
    sanadHome.replaceAll(RegExp(r'[\\/]+$'), ''),
    'dev',
    'runtime-launcher-$agentPort.json',
  ].join(Platform.pathSeparator);
}

String runtimeLauncherStopRequestPath(String sanadHome, int agentPort) {
  return [
    sanadHome.replaceAll(RegExp(r'[\\/]+$'), ''),
    'dev',
    'runtime-launcher-stop-$agentPort.json',
  ].join(Platform.pathSeparator);
}

Future<void> writeRuntimeLauncherRecord(RuntimeLauncherRecord record) async {
  final path = runtimeLauncherRecordPath(record.sanadHome, record.agentPort);
  await secureRuntimeAtomicWrite(
    record.sanadHome,
    path,
    '${jsonEncode(record.toJson())}\n',
  );
}

Future<RuntimeLauncherRecord?> readRuntimeLauncherRecord(
  String sanadHome,
  int agentPort,
) async {
  final file = File(runtimeLauncherRecordPath(sanadHome, agentPort));
  if (!await file.exists()) return null;
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map) {
    throw const FormatException('Runtime launcher record must be an object.');
  }
  return RuntimeLauncherRecord.fromJson(Map<String, dynamic>.from(decoded));
}

Future<void> deleteRuntimeLauncherRecord(
  String sanadHome,
  int agentPort,
) async {
  final file = File(runtimeLauncherRecordPath(sanadHome, agentPort));
  if (await file.exists()) await file.delete();
}

Future<void> writeRuntimeLauncherStopRequest(
  RuntimeLauncherRecord record,
) async {
  final path = runtimeLauncherStopRequestPath(
    record.sanadHome,
    record.agentPort,
  );
  await secureRuntimeAtomicWrite(
    record.sanadHome,
    path,
    '${jsonEncode({'launcher_id': record.launcherId, 'runtime_nonce': record.runtimeNonce, 'requested_at': DateTime.now().toUtc().toIso8601String()})}\n',
  );
}

Future<bool> consumeRuntimeLauncherStopRequest(
  RuntimeLauncherRecord record,
) async {
  final file = File(
    runtimeLauncherStopRequestPath(record.sanadHome, record.agentPort),
  );
  if (!await file.exists()) return false;
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map ||
        decoded['launcher_id'] != record.launcherId ||
        decoded['runtime_nonce'] != record.runtimeNonce) {
      return false;
    }
    await file.delete();
    return true;
  } on Object {
    return false;
  }
}

String? validateManagedRuntimeRecord({
  required RuntimeLauncherRecord? record,
  required int agentPort,
  required String sanadHome,
  String? workspaceHash,
  required bool launcherRunning,
  required String? launcherProcessIdentity,
  required Iterable<Map<String, String>> clientDefines,
  required Iterable<int?> clientPids,
  required Iterable<int> vmServicePorts,
}) {
  if (record == null) return 'launcher record is missing';
  if (!launcherRunning) return 'launcher lease is stale';
  if (launcherProcessIdentity != record.launcherProcessIdentity) {
    return 'launcher PID was reused or its process identity changed';
  }
  if (!const {
    'running',
    'agent-only',
    'client-only',
    'switching',
  }.contains(record.status)) {
    return 'launcher record status is ${record.status}';
  }
  if (record.agentPort != agentPort) return 'Agent port does not match lease';
  if (!_sameOwnershipPath(record.sanadHome, sanadHome)) {
    return 'Sanad Home does not match lease';
  }
  if (workspaceHash != null && record.workspaceHash != workspaceHash) {
    return 'workspace hash does not match lease';
  }
  final profiles = clientDefines.toList(growable: false);
  final actualPids = clientPids.whereType<int>().toSet();
  final actualVmPorts = vmServicePorts.toSet();
  if (actualPids.length != profiles.length ||
      actualPids.difference(record.clientPids.toSet()).isNotEmpty ||
      record.clientPids.toSet().difference(actualPids).isNotEmpty) {
    return 'client PIDs do not match lease';
  }
  if (actualVmPorts.length != profiles.length ||
      actualVmPorts.difference(record.vmServicePorts.toSet()).isNotEmpty ||
      record.vmServicePorts.toSet().difference(actualVmPorts).isNotEmpty) {
    return 'client VM-service ports do not match lease';
  }
  for (final defines in profiles) {
    final gateway = Uri.tryParse(defines['LOCAL_GATEWAY_URL'] ?? '');
    final clientHome = defines['SANAD_HOME'];
    if (defines['SANAD_DEV_LAUNCHER_ID'] != record.launcherId ||
        defines['SANAD_DEV_RUNTIME_NONCE'] != record.runtimeNonce) {
      return 'client launcher identity or nonce does not match lease';
    }
    if (gateway?.hasPort != true || gateway!.port != record.agentPort) {
      return 'client gateway does not match lease';
    }
    if (clientHome == null ||
        !_sameOwnershipPath(clientHome, record.sanadHome)) {
      return 'client Sanad Home does not match lease';
    }
    if (defines['SANAD_SHARED_PREFERENCES_PREFIX'] !=
        record.preferencesPrefix) {
      return 'client preferences namespace does not match lease';
    }
  }
  return null;
}

Future<String?> readProcessIdentity(int pid) async {
  if (pid <= 0) return null;
  if (Platform.isWindows) {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      '(Get-CimInstance Win32_Process -Filter "ProcessId = $pid" | '
          'Select-Object CreationDate,CommandLine | ConvertTo-Json -Compress)',
    ]);
    final value = result.stdout.toString().trim();
    return result.exitCode == 0 && value.isNotEmpty ? value : null;
  }
  final result = await Process.run('ps', [
    '-p',
    '$pid',
    '-o',
    'lstart=',
    '-o',
    'command=',
  ]);
  final value = result.stdout.toString().trim();
  return result.exitCode == 0 && value.isNotEmpty ? value : null;
}

bool _sameOwnershipPath(String first, String second) {
  String canonical(String value) {
    try {
      return Directory(value).resolveSymbolicLinksSync();
    } on FileSystemException {
      return Directory(value).absolute.path;
    }
  }

  final left = canonical(first);
  final right = canonical(second);
  return Platform.isWindows
      ? left.toLowerCase() == right.toLowerCase()
      : left == right;
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key]?.toString().trim();
  if (value == null || value.isEmpty) {
    throw FormatException('Missing runtime launcher field: $key');
  }
  return value;
}

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is int) return value;
  final parsed = int.tryParse(value?.toString() ?? '');
  if (parsed == null) {
    throw FormatException('Invalid runtime launcher field: $key');
  }
  return parsed;
}

List<int> _intList(Object? raw) {
  if (raw is! List) return const [];
  return raw
      .map((value) => value is int ? value : int.tryParse('$value'))
      .whereType<int>()
      .toList(growable: false);
}
