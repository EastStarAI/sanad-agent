import 'dart:io';

/// Process-wide resolver shared by production consumers in one Dart isolate.
///
/// Consumers may inject their own [WindowsSystemPath] in tests. Sharing the
/// production instance prevents independent shell and MCP launch sites from
/// starting duplicate PowerShell reads.
final WindowsSystemPath sharedWindowsSystemPathResolver = WindowsSystemPath();

/// Rebuilds the effective Windows PATH from the Machine and User registry
/// values so newly installed OS-level tools are visible to child processes.
///
/// Non-Windows callers receive the inherited PATH unchanged. Successful reads
/// and fallbacks are cached briefly, and concurrent asynchronous reads share
/// one in-flight operation.
class WindowsSystemPath {
  static const Duration defaultCacheTtl = Duration(minutes: 5);

  WindowsSystemPath({
    Future<String?> Function()? runPowerShell,
    String? Function()? runPowerShellSync,
    bool? isWindows,
    DateTime Function()? now,
    this.cacheTtl = defaultCacheTtl,
  }) : _runPowerShell = runPowerShell ?? _defaultPowerShellRunner,
       _runPowerShellSync = runPowerShellSync ?? _defaultPowerShellSyncRunner,
       isWindows = isWindows ?? Platform.isWindows,
       _now = now ?? DateTime.now;

  final Future<String?> Function() _runPowerShell;
  final String? Function() _runPowerShellSync;
  final DateTime Function() _now;
  final bool isWindows;
  final Duration cacheTtl;

  String? _cachedPath;
  DateTime? _cachedAt;
  Future<String>? _inFlight;

  static const List<String> _powerShellArguments = [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    r"$m = [Environment]::GetEnvironmentVariable('Path','Machine'); $u = [Environment]::GetEnvironmentVariable('Path','User'); if ($m -and $u) { [Console]::Out.Write($m + ';' + $u) } elseif ($m) { [Console]::Out.Write($m) } elseif ($u) { [Console]::Out.Write($u) }",
  ];

  static Future<String?> _defaultPowerShellRunner() async {
    if (!Platform.isWindows) return null;
    try {
      final result = await Process.run('powershell.exe', _powerShellArguments);
      if (result.exitCode != 0) return null;
      return result.stdout.toString();
    } catch (_) {
      return null;
    }
  }

  static String? _defaultPowerShellSyncRunner() {
    if (!Platform.isWindows) return null;
    try {
      final result = Process.runSync('powershell.exe', _powerShellArguments);
      if (result.exitCode != 0) return null;
      return result.stdout.toString();
    } catch (_) {
      return null;
    }
  }

  /// Resolves PATH asynchronously, sharing a concurrent registry read.
  Future<String> resolve(String inheritedPath, {bool forceRefresh = false}) {
    if (!isWindows) return Future.value(inheritedPath);
    if (!forceRefresh && _isFresh) return Future.value(_cachedPath!);
    if (!forceRefresh && _inFlight != null) return _inFlight!;

    final pending = _resolveAndCache(inheritedPath);
    _inFlight = pending;
    return pending.whenComplete(() {
      if (identical(_inFlight, pending)) _inFlight = null;
    });
  }

  /// Resolves PATH synchronously for synchronous environment composition.
  String resolveSync(String inheritedPath, {bool forceRefresh = false}) {
    if (!isWindows) return inheritedPath;
    if (!forceRefresh && _isFresh) return _cachedPath!;

    String? resolved;
    try {
      resolved = _runPowerShellSync();
    } catch (_) {
      resolved = null;
    }
    return _cacheResolvedOrFallback(resolved, inheritedPath);
  }

  Future<String> _resolveAndCache(String inheritedPath) async {
    String? resolved;
    try {
      resolved = await _runPowerShell();
    } catch (_) {
      resolved = null;
    }
    return _cacheResolvedOrFallback(resolved, inheritedPath);
  }

  String _cacheResolvedOrFallback(String? resolved, String inheritedPath) {
    final normalized = resolved?.trim() ?? '';
    _cachedPath = normalized.isEmpty ? inheritedPath : normalized;
    _cachedAt = _now();
    return _cachedPath!;
  }

  bool get _isFresh {
    final cachedAt = _cachedAt;
    return _cachedPath != null &&
        cachedAt != null &&
        _now().difference(cachedAt) < cacheTtl;
  }

  void clearCache() {
    _cachedPath = null;
    _cachedAt = null;
    _inFlight = null;
  }
}

/// Reads PATH without assuming a particular key casing.
String inheritedPathFromEnvironment(Map<String, String> environment) {
  for (final entry in environment.entries) {
    if (entry.key.toLowerCase() == 'path') return entry.value;
  }
  return '';
}

/// Replaces any case variant of PATH with one canonical child-process entry.
Map<String, String> replaceEnvironmentPath(
  Map<String, String> environment,
  String path,
) {
  final result = Map<String, String>.from(environment)
    ..removeWhere((key, _) => key.toLowerCase() == 'path')
    ..['PATH'] = path;
  return result;
}
