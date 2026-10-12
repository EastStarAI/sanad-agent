part of '../../sanad_dev_cli.dart';

String _defaultDesktopDevice() {
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  if (Platform.isLinux) return 'linux';
  return 'macos';
}

String get _callerDirectory =>
    Platform.environment['SANAD_DEV_CALLER_DIR'] ?? Directory.current.path;

Future<SanadDevRuntime> _currentRuntime({String? sanadHomePath}) =>
    discoverSanadDevRuntime(
      callerDirectory: _callerDirectory,
      sanadHomeOverride: sanadHomePath,
    );

Future<String?> _inferredPostLaunchSanadHome() async {
  try {
    return await inferPostLaunchSanadHome(await _currentRuntime());
  } on Object {
    return null;
  }
}

Future<int?> _recordedPortForTarget(
  String target, {
  String? sanadHomePath,
}) async {
  try {
    final runtime = await discoverSanadDevRuntime(
      callerDirectory: _callerDirectory,
      sanadHomeOverride: sanadHomePath,
    );
    final state = selectRuntimeProcessState(
      activeAgents: await discoverAgentInstances(
        sanadHomeOverride: sanadHomePath,
      ),
      activeClients: await discoverClientInstances(),
      runtime: runtime,
    );
    if (target == 'agent') return state.agent?.port;
    if (state.ownedClients.length == 1) {
      return state.ownedClients.single.port;
    }
    return null;
  } catch (_) {
    return null;
  }
}
