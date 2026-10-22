part of '../../sanad_dev_cli.dart';

/// Bundle root of a running Client executable, or null when the executable is
/// not inside an application bundle.
String? uiDriverBundlePath(String? executable) {
  if (executable == null) return null;
  final marker = executable.indexOf('.app/Contents/MacOS/');
  if (marker < 0) return null;
  return executable.substring(0, marker + '.app'.length);
}

/// Live process ids whose executable lives inside [bundlePath].
Future<List<int>> _macOsBundleProcessIds(String bundlePath) async {
  final result = await Process.run('ps', ['-axo', 'pid=,comm=']);
  if (result.exitCode != 0) return const [];
  final prefix = '$bundlePath/Contents/MacOS/';
  final pids = <int>[];
  for (final line in result.stdout.toString().split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final space = trimmed.indexOf(' ');
    if (space <= 0) continue;
    final pid = int.tryParse(trimmed.substring(0, space));
    final command = trimmed.substring(space + 1).trim();
    if (pid == null) continue;
    if (command.startsWith(prefix)) pids.add(pid);
  }
  return pids;
}

/// Brings the owning Client window to the front before an action is dispatched.
///
/// macOS activates only the bundle of the already-running Client whose process
/// id was discovered, so no Accessibility, Automation, or Keychain prompt is
/// ever triggered. The pid must still be alive, must still belong to the same
/// bundle, and must be the only live instance of that bundle; otherwise
/// activation is skipped instead of guessing or launching a second Client.
/// Every failure is a silent no-op: the action still runs.
Future<bool> activateUiDriverOwnerWindow({
  required int? pid,
  bool? isMacOS,
  List<String> Function(int pid)? readArguments,
  Future<List<int>> Function(String bundlePath)? bundleProcessIds,
  Future<ProcessResult> Function(String, List<String>)? openApplication,
}) async {
  if (!(isMacOS ?? Platform.isMacOS) || pid == null || pid <= 0) return false;
  final readArgs = readArguments ?? readMacOsProcessArguments;
  final String? bundlePath;
  try {
    final arguments = readArgs(pid);
    // An empty argument vector means the discovered process is gone; launching
    // the bundle then would start a second Client.
    if (arguments.isEmpty) return false;
    bundlePath = uiDriverBundlePath(arguments.first);
  } catch (_) {
    return false;
  }
  if (bundlePath == null) return false;

  try {
    final pids = await (bundleProcessIds ?? _macOsBundleProcessIds)(bundlePath);
    if (pids.length != 1 || pids.single != pid) return false;
  } catch (_) {
    return false;
  }

  // Re-check after the scan so a pid that exited mid-check is never activated.
  try {
    final reread = readArgs(pid);
    if (reread.isEmpty) return false;
    if (uiDriverBundlePath(reread.first) != bundlePath) return false;
  } catch (_) {
    return false;
  }

  try {
    final run =
        openApplication ??
        (String executable, List<String> arguments) => Process.run(
          executable,
          arguments,
          stdoutEncoding: null,
          stderrEncoding: null,
        );
    await run('open', ['-a', bundlePath]).timeout(const Duration(seconds: 3));
    return true;
  } catch (_) {
    return false;
  }
}
