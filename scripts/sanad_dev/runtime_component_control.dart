import 'dart:convert';
import 'dart:io';

import 'secure_runtime_file.dart';

const runtimeComponentControlVersion = 1;

enum RuntimeComponentAction {
  start,
  stop,
  reload,
  restart,
  help,
  detach,
  clear,
  quit,
}

enum RuntimeComponentTarget { agent, client, all }

RuntimeComponentAction? runtimeClientActionForInteractiveKey(String key) =>
    switch (key) {
      'r' => RuntimeComponentAction.reload,
      'R' => RuntimeComponentAction.restart,
      'h' => RuntimeComponentAction.help,
      'd' => RuntimeComponentAction.detach,
      'c' => RuntimeComponentAction.clear,
      'q' => RuntimeComponentAction.quit,
      _ => null,
    };

String? runtimeClientInteractiveKeyForAction(RuntimeComponentAction action) =>
    switch (action) {
      RuntimeComponentAction.reload => 'r',
      RuntimeComponentAction.restart => 'R',
      RuntimeComponentAction.help => 'h',
      RuntimeComponentAction.detach => 'd',
      RuntimeComponentAction.clear => 'c',
      RuntimeComponentAction.quit => 'q',
      _ => null,
    };

bool isRuntimeAgentInteractiveKey(String key) =>
    const {'r', 'R', 's', 'q'}.contains(key);

class RuntimeComponentControlRequest {
  const RuntimeComponentControlRequest({
    required this.requestId,
    required this.launcherId,
    required this.runtimeNonce,
    required this.action,
    required this.target,
    required this.status,
    required this.requestedAt,
    this.deviceId,
    this.clientPid,
    this.vmServicePort,
    this.force = false,
    this.openClientTerminal = true,
    this.message,
  });

  final String requestId;
  final String launcherId;
  final String runtimeNonce;
  final RuntimeComponentAction action;
  final RuntimeComponentTarget target;
  final String status;
  final DateTime requestedAt;
  final String? deviceId;
  final int? clientPid;
  final int? vmServicePort;
  final bool force;
  final bool openClientTerminal;
  final String? message;

  bool get isTerminal => const {'complete', 'failed'}.contains(status);

  RuntimeComponentControlRequest copyWith({String? status, String? message}) {
    return RuntimeComponentControlRequest(
      requestId: requestId,
      launcherId: launcherId,
      runtimeNonce: runtimeNonce,
      action: action,
      target: target,
      status: status ?? this.status,
      requestedAt: requestedAt,
      deviceId: deviceId,
      clientPid: clientPid,
      vmServicePort: vmServicePort,
      force: force,
      openClientTerminal: openClientTerminal,
      message: message ?? this.message,
    );
  }

  Map<String, Object?> toJson() => {
    'version': runtimeComponentControlVersion,
    'request_id': requestId,
    'launcher_id': launcherId,
    'runtime_nonce': runtimeNonce,
    'action': action.name,
    'target': target.name,
    'status': status,
    'requested_at': requestedAt.toUtc().toIso8601String(),
    if (deviceId != null) 'device_id': deviceId,
    if (clientPid != null) 'client_pid': clientPid,
    if (vmServicePort != null) 'vm_service_port': vmServicePort,
    'force': force,
    'open_client_terminal': openClientTerminal,
    if (message != null) 'message': message,
  };

  static RuntimeComponentControlRequest fromJson(Map<String, dynamic> json) {
    if (json['version'] != runtimeComponentControlVersion) {
      throw const FormatException('Unsupported component control request.');
    }
    T parseEnum<T extends Enum>(List<T> values, String key) {
      final value = json[key]?.toString();
      return values.firstWhere(
        (candidate) => candidate.name == value,
        orElse: () => throw FormatException('Invalid component field: $key'),
      );
    }

    return RuntimeComponentControlRequest(
      requestId: _requiredControlString(json, 'request_id'),
      launcherId: _requiredControlString(json, 'launcher_id'),
      runtimeNonce: _requiredControlString(json, 'runtime_nonce'),
      action: parseEnum(RuntimeComponentAction.values, 'action'),
      target: parseEnum(RuntimeComponentTarget.values, 'target'),
      status: _requiredControlString(json, 'status'),
      requestedAt: DateTime.parse(
        _requiredControlString(json, 'requested_at'),
      ).toUtc(),
      deviceId: json['device_id']?.toString(),
      clientPid: _optionalControlInt(json['client_pid']),
      vmServicePort: _optionalControlInt(json['vm_service_port']),
      force: json['force'] == true,
      openClientTerminal: json['open_client_terminal'] != false,
      message: json['message']?.toString(),
    );
  }
}

String runtimeComponentControlPath(String sanadHome, int agentPort) => [
  sanadHome.replaceAll(RegExp(r'[\\/]+$'), ''),
  'dev',
  'runtime-component-control-$agentPort.json',
].join(Platform.pathSeparator);

Future<void> writeRuntimeComponentControl(
  String path,
  RuntimeComponentControlRequest request,
) async {
  final sanadHome = File(path).parent.parent.path;
  await secureRuntimeAtomicWrite(
    sanadHome,
    path,
    '${jsonEncode(request.toJson())}\n',
  );
}

Future<RuntimeComponentControlRequest?> readRuntimeComponentControl(
  String path,
) async {
  final file = File(path);
  if (!await file.exists()) return null;
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map) {
    throw const FormatException('Component control request must be an object.');
  }
  return RuntimeComponentControlRequest.fromJson(
    Map<String, dynamic>.from(decoded),
  );
}

String _requiredControlString(Map<String, dynamic> json, String key) {
  final value = json[key]?.toString().trim();
  if (value == null || value.isEmpty) {
    throw FormatException('Missing component field: $key');
  }
  return value;
}

int? _optionalControlInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  return int.tryParse(value.toString());
}
