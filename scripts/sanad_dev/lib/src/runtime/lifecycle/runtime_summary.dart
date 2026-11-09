part of '../../../sanad_dev_cli.dart';

void _printRuntimeSummary(
  SanadDevRuntime runtime, {
  required bool driverMode,
  required bool cloudEnabled,
  int? agentPort,
  int? vmServicePort,
  String? sanadHomePath,
}) {
  print('Worktree: ${runtime.worktreeId}');
  print('Branch: ${runtime.branch}');
  print('Mode: ${driverMode ? 'interactive-driver' : 'interactive'}');
  print('Cloud gateway: ${cloudEnabled ? 'enabled' : 'disabled'}');
  print('Agent gateway: http://127.0.0.1:${agentPort ?? runtime.agentPort}');
  print(
    'Client VM service: http://127.0.0.1:${vmServicePort ?? runtime.vmServicePort}/',
  );
  print('Sanad home: ${sanadHomePath ?? runtime.sanadHome}');
}
