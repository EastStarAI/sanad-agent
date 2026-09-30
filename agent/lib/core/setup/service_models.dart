enum ServiceScope {
  launchdUser('launchd-user'),
  systemdUser('systemd-user'),
  systemdSystem('systemd-system'),
  openRc('openrc'),
  windowsTask('windows-task'),
  unavailable('unavailable');

  const ServiceScope(this.wireName);
  final String wireName;

  static ServiceScope? fromWireName(String? value) {
    for (final scope in values) {
      if (scope.wireName == value) return scope;
    }
    return null;
  }
}

enum ServiceState {
  missing('Missing'),
  installedStopped('InstalledStopped'),
  running('Running'),
  failed('Failed'),
  managerUnavailable('ManagerUnavailable');

  const ServiceState(this.displayName);
  final String displayName;
}

class ServiceStatus {
  const ServiceStatus({
    required this.state,
    required this.scope,
    required this.backend,
    required this.installed,
    required this.enabled,
    required this.running,
    this.error,
    this.configPath,
  });

  const ServiceStatus.missing({
    this.scope = ServiceScope.unavailable,
    this.backend = 'none',
  }) : state = ServiceState.missing,
       installed = false,
       enabled = false,
       running = false,
       error = null,
       configPath = null;

  final ServiceState state;
  final ServiceScope scope;
  final String backend;
  final bool installed;
  final bool enabled;
  final bool running;
  final String? error;
  final String? configPath;
}

class ServiceOperationResult {
  const ServiceOperationResult({
    required this.success,
    required this.status,
    this.error,
  });

  final bool success;
  final ServiceStatus status;
  final String? error;
}

class ServiceProcessResult {
  const ServiceProcessResult({
    required this.exitCode,
    this.stdout = '',
    this.stderr = '',
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get succeeded => exitCode == 0;
  String get conciseError {
    final value = stderr.trim().isNotEmpty ? stderr.trim() : stdout.trim();
    if (value.isEmpty) return 'Command exited with code $exitCode.';
    return value.split('\n').first.trim();
  }
}

typedef ServiceProcessRunner =
    Future<ServiceProcessResult> Function(
      String executable,
      List<String> arguments,
      Map<String, String>? environment,
    );
