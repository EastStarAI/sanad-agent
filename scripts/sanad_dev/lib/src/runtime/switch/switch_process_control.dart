part of '../../../sanad_dev_cli.dart';

Future<bool> waitForClientResourcesUnavailable({
  required Map<int, int?> clientPidsByVmPort,
  Duration timeout = const Duration(seconds: 15),
  Duration pollInterval = const Duration(milliseconds: 100),
  Future<bool> Function(int pid)? processRunning,
  Future<bool> Function(int port)? vmServiceAvailable,
}) async {
  final isRunning = processRunning ?? isProcessRunning;
  final vmAvailable = vmServiceAvailable ?? _vmServiceIsAvailable;
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    var unavailable = true;
    for (final client in clientPidsByVmPort.entries) {
      if ((client.value != null && await isRunning(client.value!)) ||
          await vmAvailable(client.key)) {
        unavailable = false;
        break;
      }
    }
    if (unavailable) return true;
    await Future<void>.delayed(pollInterval);
  }
  return false;
}

Future<void> terminateSanadDevProcessTree(int processId) async {
  if (Platform.isWindows) {
    await Process.run('taskkill', ['/PID', '$processId', '/T', '/F']);
    return;
  }
  final result = await Process.run('ps', ['-axo', 'pid=,ppid=']);
  final processIds = result.exitCode == 0
      ? orderUnixProcessTree(result.stdout.toString(), processId)
      : [processId];
  for (final childPid in processIds.reversed) {
    try {
      Process.killPid(childPid, ProcessSignal.sigterm);
    } on Object {}
  }
  await Future<void>.delayed(const Duration(milliseconds: 500));
  for (final childPid in processIds.reversed) {
    if (await isProcessRunning(childPid)) {
      try {
        Process.killPid(childPid, ProcessSignal.sigkill);
      } on Object {}
    }
  }
}
