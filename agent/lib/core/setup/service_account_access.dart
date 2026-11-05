import 'service_models.dart';

/// Proof that the account a system-scope unit runs as can reach the paths that
/// unit names.
///
/// A system unit that runs as a dedicated account fails at activation when the
/// service account cannot traverse `WorkingDirectory` or execute `ExecStart` —
/// systemd reports `203/EXEC` and the service never starts, after the caller has
/// already downloaded the artifact and completed device pairing. This probe
/// asks the kernel the same question before the unit is written: `test -x`
/// needs search permission on every parent directory, so it fails exactly when
/// the unit would fail.
///
/// Returns null when [userName] can run [executable] and enter
/// [workingDirectory]; otherwise an actionable message for the operator.
Future<String?> serviceAccountAccessFailure({
  required ServiceProcessRunner runner,
  required String currentUserName,
  required bool currentIsRoot,
  required String userName,
  required String executable,
  required String workingDirectory,
}) async {
  // The install already runs as that account, so the paths the unit names are
  // reachable by the same identity that will run them.
  if (userName == currentUserName) return null;
  if (!await _canExecute(runner, currentIsRoot, userName, executable)) {
    return 'The service account "$userName" cannot execute "$executable". '
        'Install the Agent into a path that account can reach, for example '
        'SANAD_HOME=/var/lib/sanad-agent, then retry the installation.';
  }
  if (!await _canExecute(runner, currentIsRoot, userName, workingDirectory)) {
    return 'The service account "$userName" cannot enter "$workingDirectory". '
        'Move the Sanad Home to a path that account can reach, for example '
        'SANAD_HOME=/var/lib/sanad-agent, then retry the installation.';
  }
  return null;
}

Future<bool> _canExecute(
  ServiceProcessRunner runner,
  bool currentIsRoot,
  String userName,
  String path,
) async {
  final result = await runner(
    // Only root may enter another account, and `runuser` is what util-linux
    // ships for it; a non-root install can only ask through `sudo`.
    currentIsRoot ? 'runuser' : 'sudo',
    ['-u', userName, '--', 'test', '-x', path],
    null,
  );
  // A host without the probing tool cannot answer the question. Reporting a
  // failure would block an install that systemd may well accept, so this stays
  // a guard: the activation health transaction still has to prove the service
  // is running.
  if (_isProbeUnavailable(result)) return true;
  return result.succeeded;
}

bool _isProbeUnavailable(ServiceProcessResult result) =>
    result.exitCode == 127 ||
    result.stderr.contains('command not found') ||
    result.stderr.contains('No such file or directory');
