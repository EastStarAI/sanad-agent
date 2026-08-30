import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'service_models.dart';

class LinuxServiceIdentity {
  const LinuxServiceIdentity({
    required this.userName,
    required this.groupName,
    required this.uid,
    required this.home,
    required this.isRoot,
    this.dedicated = false,
  });

  final String userName;
  final String groupName;
  final int uid;
  final String home;
  final bool isRoot;
  final bool dedicated;
}

class LinuxServicePaths {
  const LinuxServicePaths({
    this.systemUnitDirectory = '/etc/systemd/system',
    this.openRcInitDirectory = '/etc/init.d',
    this.systemdRuntimeDirectory = '/run/systemd/system',
    this.userRuntimeDirectory = '/run/user',
  });

  final String systemUnitDirectory;
  final String openRcInitDirectory;
  final String systemdRuntimeDirectory;
  final String userRuntimeDirectory;
}

class LinuxServiceManager {
  LinuxServiceManager({
    required this.serviceName,
    required this.executable,
    required this.arguments,
    required this.sanadHome,
    required this.loginHome,
    required this.environment,
    required this.runner,
    LinuxServicePaths paths = const LinuxServicePaths(),
    LinuxServiceIdentity? identity,
    this.dedicatedHomePath = dedicatedHome,
    this.postActivationVerification,
  }) : _paths = paths,
       _identityOverride = identity;

  static const String dedicatedUser = 'sanad-agent';
  static const String dedicatedHome = '/var/lib/sanad-agent';

  final String serviceName;
  final String executable;
  final List<String> arguments;
  final String sanadHome;
  final String loginHome;
  final Map<String, String> environment;
  final ServiceProcessRunner runner;
  final String dedicatedHomePath;
  final Future<String?> Function()? postActivationVerification;
  final LinuxServicePaths _paths;
  final LinuxServiceIdentity? _identityOverride;

  String get _metadataPath => p.join(sanadHome, 'service.json');
  String get _userUnitPath =>
      p.join(loginHome, '.config', 'systemd', 'user', serviceName);
  String get _systemUnitPath => p.join(_paths.systemUnitDirectory, serviceName);
  String get _openRcName => serviceName.replaceFirst(RegExp(r'\.service$'), '');
  String get _openRcPath => p.join(_paths.openRcInitDirectory, _openRcName);

  Future<ServiceOperationResult> install() async {
    try {
      final current = await _currentIdentity();
      final selection = await _selectBackend(current);
      if (selection == null) {
        return _failure(
          const ServiceStatus(
            state: ServiceState.managerUnavailable,
            scope: ServiceScope.unavailable,
            backend: 'none',
            installed: false,
            enabled: false,
            running: false,
            error: 'No supported Linux init manager is available.',
          ),
          'No supported Linux init manager is available.',
        );
      }

      final targetHome = selection.identity.dedicated
          ? dedicatedHomePath
          : sanadHome;
      await Directory(targetHome).create(recursive: true);
      await Directory(p.join(targetHome, 'logs')).create(recursive: true);
      final legacyUser =
          selection.scope != ServiceScope.systemdUser &&
              File(_userUnitPath).existsSync()
          ? await _prepareLegacyUserMigration(current)
          : null;
      if (legacyUser != null && !legacyUser.ready) {
        return _failure(await status(), legacyUser.error!);
      }
      final conflicts = _conflictingPaths(selection.scope)
          .where((path) => path != _userUnitPath || legacyUser == null)
          .where((path) => File(path).existsSync())
          .toList();
      if (conflicts.isNotEmpty) {
        return _failure(
          await status(),
          'A conflicting Sanad service is already installed at ${conflicts.first}.',
        );
      }

      if (selection.identity.dedicated) {
        final account = await _ensureDedicatedIdentity();
        if (!account.succeeded) {
          return _failure(await status(), account.conciseError);
        }
        final ownership = await _secureDedicatedHome(
          targetHome,
          selection.identity,
        );
        if (!ownership.succeeded) {
          return _failure(await status(), ownership.conciseError);
        }
      }

      final content = selection.scope == ServiceScope.openRc
          ? buildOpenRcScript(
              executable: executable,
              arguments: arguments,
              sanadHome: targetHome,
              user: selection.identity.userName,
              group: selection.identity.groupName,
            )
          : buildSystemdUnit(
              executable: executable,
              arguments: arguments,
              sanadHome: targetHome,
              systemScope: selection.scope == ServiceScope.systemdSystem,
              user: selection.identity.userName,
              group: selection.identity.groupName,
              home: selection.identity.home,
            );
      final targetPath = _pathFor(selection.scope);
      if (FileSystemEntity.typeSync(targetPath, followLinks: false) ==
          FileSystemEntityType.link) {
        return _failure(
          await status(),
          'Refusing to replace a symlinked service definition.',
        );
      }
      final transaction = await _replaceConfig(
        targetPath: targetPath,
        content: content,
        privileged: selection.scope != ServiceScope.systemdUser,
        executableMode: selection.scope == ServiceScope.openRc,
      );
      if (!transaction.ready) {
        return _failure(await status(), transaction.error!);
      }

      final activated = await _activate(selection.scope, selection.identity);
      if (!activated.succeeded) {
        await _deactivate(selection.scope, selection.identity);
        await transaction.rollback();
        await _reload(selection.scope, selection.identity);
        await legacyUser?.restore();
        return _failure(await status(), activated.conciseError);
      }

      final live = await _statusFor(
        selection.scope,
        selection.identity,
        configPath: targetPath,
      );
      if (!live.running || !live.enabled) {
        await _deactivate(selection.scope, selection.identity);
        await transaction.rollback();
        await _reload(selection.scope, selection.identity);
        await legacyUser?.restore();
        return _failure(
          live,
          live.error ?? 'The service did not become enabled and running.',
        );
      }

      final verificationError = await postActivationVerification?.call();
      if (verificationError != null) {
        await _deactivate(selection.scope, selection.identity);
        await transaction.rollback();
        await _reload(selection.scope, selection.identity);
        await legacyUser?.restore();
        return _failure(await status(), verificationError);
      }

      if (legacyUser != null) {
        final migrated = await legacyUser.commit();
        if (!migrated.succeeded) {
          await _deactivate(selection.scope, selection.identity);
          await transaction.rollback();
          await _reload(selection.scope, selection.identity);
          await legacyUser.restore();
          return _failure(await status(), migrated.conciseError);
        }
      }
      await transaction.commit();
      await _writeMetadata(
        scope: selection.scope,
        configPath: targetPath,
        sanadHome: targetHome,
        identity: selection.identity,
      );
      return ServiceOperationResult(success: true, status: live);
    } catch (error) {
      return _failure(await status(), _concise(error));
    }
  }

  Future<ServiceOperationResult> uninstall() async {
    final metadata = await _readMetadata();
    if (metadata == null) {
      final current = await status();
      if (!current.installed) {
        return const ServiceOperationResult(
          success: true,
          status: ServiceStatus.missing(),
        );
      }
      return _failure(
        current,
        'Refusing to remove a service that is not owned by this installation.',
      );
    }
    final scope = ServiceScope.fromWireName(metadata['scope'] as String?);
    final configPath = metadata['config_path'] as String?;
    if (scope == null || configPath == null || configPath != _pathFor(scope)) {
      return _failure(
        await status(),
        'Service ownership metadata is invalid; no files were removed.',
      );
    }
    final identity = await _identityFromMetadata(metadata);
    final stopped = await _deactivate(scope, identity);
    if (!stopped.succeeded && (await status()).running) {
      return _failure(await status(), stopped.conciseError);
    }
    final removed = await _removeConfig(
      configPath,
      privileged: scope != ServiceScope.systemdUser,
    );
    if (!removed.succeeded) {
      return _failure(await status(), removed.conciseError);
    }
    await _reload(scope, identity);
    final metadataFile = File(_metadataPath);
    if (metadataFile.existsSync()) await metadataFile.delete();
    return const ServiceOperationResult(
      success: true,
      status: ServiceStatus.missing(),
    );
  }

  Future<ServiceOperationResult> start() => _lifecycle(starting: true);
  Future<ServiceOperationResult> stop() => _lifecycle(starting: false);

  Future<ServiceOperationResult> restart() async {
    final metadata = await _readMetadata();
    if (metadata == null) {
      return _failure(await status(), 'The Sanad service is not installed.');
    }
    final scope = ServiceScope.fromWireName(metadata['scope'] as String?)!;
    final identity = await _identityFromMetadata(metadata);
    final result = await _commandFor(scope, identity, 'restart');
    final current = await _statusFor(scope, identity);
    return ServiceOperationResult(
      success: result.succeeded && current.running,
      status: current,
      error: result.succeeded ? current.error : result.conciseError,
    );
  }

  Future<ServiceOperationResult> _lifecycle({required bool starting}) async {
    final metadata = await _readMetadata();
    if (metadata == null) {
      return _failure(await status(), 'The Sanad service is not installed.');
    }
    final scope = ServiceScope.fromWireName(metadata['scope'] as String?)!;
    final identity = await _identityFromMetadata(metadata);
    final result = await _commandFor(
      scope,
      identity,
      starting ? 'start' : 'stop',
    );
    final current = await _statusFor(scope, identity);
    final expected = starting ? current.running : !current.running;
    return ServiceOperationResult(
      success: result.succeeded && expected,
      status: current,
      error: result.succeeded ? current.error : result.conciseError,
    );
  }

  Future<ServiceStatus> status() async {
    final metadata = await _readMetadata();
    if (metadata != null) {
      final scope = ServiceScope.fromWireName(metadata['scope'] as String?);
      if (scope == null) {
        return const ServiceStatus(
          state: ServiceState.failed,
          scope: ServiceScope.unavailable,
          backend: 'unknown',
          installed: true,
          enabled: false,
          running: false,
          error: 'Service ownership metadata has an unknown backend.',
        );
      }
      return _statusFor(
        scope,
        await _identityFromMetadata(metadata),
        configPath: metadata['config_path'] as String?,
      );
    }

    for (final entry in <MapEntry<ServiceScope, String>>[
      MapEntry(ServiceScope.systemdUser, _userUnitPath),
      MapEntry(ServiceScope.systemdSystem, _systemUnitPath),
      MapEntry(ServiceScope.openRc, _openRcPath),
    ]) {
      if (File(entry.value).existsSync()) {
        return ServiceStatus(
          state: ServiceState.failed,
          scope: entry.key,
          backend: entry.key.wireName,
          installed: true,
          enabled: false,
          running: false,
          error: 'Service exists without Sanad ownership metadata.',
          configPath: entry.value,
        );
      }
    }
    return const ServiceStatus.missing();
  }

  Future<_LegacyUserMigration> _prepareLegacyUserMigration(
    LinuxServiceIdentity identity,
  ) async {
    final unit = File(_userUnitPath);
    final bytes = await unit.readAsBytes();
    final previous = await _statusFor(
      ServiceScope.systemdUser,
      identity,
      configPath: unit.path,
    );
    if (previous.state == ServiceState.managerUnavailable) {
      return _LegacyUserMigration.failed(
        previous.error ?? 'The legacy user service manager is unavailable.',
      );
    }
    if (previous.running || previous.enabled) {
      final stopped = await _deactivate(ServiceScope.systemdUser, identity);
      if (!stopped.succeeded) {
        return _LegacyUserMigration.failed(stopped.conciseError);
      }
    }
    return _LegacyUserMigration(
      commit: () async {
        try {
          if (unit.existsSync()) {
            await unit.delete();
          }
          return await _reload(ServiceScope.systemdUser, identity);
        } catch (error) {
          return ServiceProcessResult(exitCode: 1, stderr: _concise(error));
        }
      },
      restore: () async {
        await unit.parent.create(recursive: true);
        await unit.writeAsBytes(bytes, flush: true);
        await _reload(ServiceScope.systemdUser, identity);
        if (previous.enabled || previous.running) {
          await _activate(ServiceScope.systemdUser, identity);
        }
      },
    );
  }

  Future<_BackendSelection?> _selectBackend(
    LinuxServiceIdentity current,
  ) async {
    if (Directory(_paths.systemdRuntimeDirectory).existsSync()) {
      if (!current.isRoot && await _prepareUserManager(current)) {
        return _BackendSelection(ServiceScope.systemdUser, current);
      }
      return _BackendSelection(
        ServiceScope.systemdSystem,
        await _systemIdentity(current),
      );
    }
    final openRc = await runner('rc-service', const ['--version'], null);
    if (openRc.succeeded ||
        File(p.join(_paths.openRcInitDirectory, 'openrc-run')).existsSync()) {
      return _BackendSelection(
        ServiceScope.openRc,
        await _systemIdentity(current),
      );
    }
    return null;
  }

  Future<bool> _prepareUserManager(LinuxServiceIdentity identity) async {
    final runtime = p.join(_paths.userRuntimeDirectory, '${identity.uid}');
    if (!File(p.join(runtime, 'bus')).existsSync()) return false;
    final linger = await runner('loginctl', [
      'show-user',
      identity.userName,
      '-p',
      'Linger',
      '--value',
    ], null);
    if (!linger.succeeded) return false;
    if (linger.stdout.trim() != 'yes') {
      final enabled = await _runPrivileged('loginctl', [
        'enable-linger',
        identity.userName,
      ], currentIsRoot: identity.isRoot);
      if (!enabled.succeeded) return false;
      final verified = await runner('loginctl', [
        'show-user',
        identity.userName,
        '-p',
        'Linger',
        '--value',
      ], null);
      if (!verified.succeeded || verified.stdout.trim() != 'yes') return false;
    }
    final probe = await runner('systemctl', const [
      '--user',
      'show-environment',
    ], _userManagerEnvironment(identity));
    return probe.succeeded;
  }

  Future<LinuxServiceIdentity> _systemIdentity(
    LinuxServiceIdentity current,
  ) async {
    if (!current.isRoot) return current;
    final sudoUser = environment['SUDO_USER']?.trim() ?? '';
    if (sudoUser.isNotEmpty && sudoUser != 'root') {
      return _lookupIdentity(sudoUser);
    }
    return LinuxServiceIdentity(
      userName: dedicatedUser,
      groupName: dedicatedUser,
      uid: -1,
      home: dedicatedHomePath,
      isRoot: false,
      dedicated: true,
    );
  }

  Future<LinuxServiceIdentity> _currentIdentity() async {
    if (_identityOverride case final identity?) {
      return identity;
    }
    final uidResult = await runner('id', const ['-u'], null);
    final userResult = await runner('id', const ['-un'], null);
    if (!uidResult.succeeded || !userResult.succeeded) {
      throw StateError('Unable to determine the current Linux identity.');
    }
    final uid = int.parse(uidResult.stdout.trim());
    return _lookupIdentity(userResult.stdout.trim(), knownUid: uid);
  }

  Future<LinuxServiceIdentity> _lookupIdentity(
    String user, {
    int? knownUid,
  }) async {
    final result = await runner('getent', ['passwd', user], null);
    if (!result.succeeded) {
      throw StateError('Linux user "$user" does not exist.');
    }
    final fields = result.stdout.trim().split(':');
    if (fields.length < 7) {
      throw StateError('Invalid account record for "$user".');
    }
    final uid = knownUid ?? int.parse(fields[2]);
    if (uid == 0 && user != 'root') {
      throw StateError('Refusing an invalid privileged original user.');
    }
    final groupResult = await runner('id', ['-gn', user], null);
    if (!groupResult.succeeded) {
      throw StateError('Unable to resolve group for "$user".');
    }
    return LinuxServiceIdentity(
      userName: user,
      groupName: groupResult.stdout.trim(),
      uid: uid,
      home: fields[5],
      isRoot: uid == 0,
    );
  }

  Future<ServiceProcessResult> _ensureDedicatedIdentity() async {
    final existing = await runner('getent', const [
      'passwd',
      dedicatedUser,
    ], null);
    if (existing.succeeded) return existing;
    return runner('useradd', [
      '--system',
      '--user-group',
      '--home-dir',
      dedicatedHomePath,
      '--create-home',
      '--shell',
      '/usr/sbin/nologin',
      dedicatedUser,
    ], null);
  }

  Future<ServiceProcessResult> _secureDedicatedHome(
    String targetHome,
    LinuxServiceIdentity identity,
  ) async {
    final owner = '${identity.userName}:${identity.groupName}';
    final ownership = await _runPrivileged('chown', [
      '-R',
      owner,
      targetHome,
    ], currentIsRoot: true);
    if (!ownership.succeeded) {
      return ownership;
    }
    return _runPrivileged('chmod', [
      '0700',
      targetHome,
      p.join(targetHome, 'logs'),
    ], currentIsRoot: true);
  }

  Future<ServiceStatus> _statusFor(
    ServiceScope scope,
    LinuxServiceIdentity identity, {
    String? configPath,
  }) async {
    final path = configPath ?? _pathFor(scope);
    if (!File(path).existsSync()) {
      return ServiceStatus(
        state: ServiceState.missing,
        scope: scope,
        backend: scope.wireName,
        installed: false,
        enabled: false,
        running: false,
        configPath: path,
      );
    }
    if (scope == ServiceScope.openRc) {
      final running = await runner('rc-service', [_openRcName, 'status'], null);
      final enabled = await runner('rc-update', ['show', 'default'], null);
      final isEnabled =
          enabled.succeeded && enabled.stdout.contains(_openRcName);
      return ServiceStatus(
        state: running.succeeded
            ? ServiceState.running
            : ServiceState.installedStopped,
        scope: scope,
        backend: scope.wireName,
        installed: true,
        enabled: isEnabled,
        running: running.succeeded,
        error: running.exitCode == 3
            ? null
            : (running.succeeded ? null : running.conciseError),
        configPath: path,
      );
    }
    final prefix = scope == ServiceScope.systemdUser
        ? const ['--user']
        : const <String>[];
    final env = scope == ServiceScope.systemdUser
        ? _userManagerEnvironment(identity)
        : null;
    final active = await runner('systemctl', [
      ...prefix,
      'is-active',
      serviceName,
    ], env);
    final enabled = await runner('systemctl', [
      ...prefix,
      'is-enabled',
      serviceName,
    ], env);
    final managerUnavailable =
        active.exitCode == 1 &&
        active.conciseError.toLowerCase().contains('connect');
    final running = active.stdout.trim() == 'active';
    final failed = active.stdout.trim() == 'failed';
    return ServiceStatus(
      state: managerUnavailable
          ? ServiceState.managerUnavailable
          : running
          ? ServiceState.running
          : failed
          ? ServiceState.failed
          : ServiceState.installedStopped,
      scope: scope,
      backend: scope.wireName,
      installed: true,
      enabled: enabled.stdout.trim() == 'enabled',
      running: running,
      error: managerUnavailable || failed ? active.conciseError : null,
      configPath: path,
    );
  }

  Future<ServiceProcessResult> _activate(
    ServiceScope scope,
    LinuxServiceIdentity identity,
  ) async {
    final reload = await _reload(scope, identity);
    if (!reload.succeeded) return reload;
    if (scope == ServiceScope.openRc) {
      final enable = await _runPrivileged('rc-update', [
        'add',
        _openRcName,
        'default',
      ], currentIsRoot: (await _currentIdentity()).isRoot);
      if (!enable.succeeded) return enable;
      return _runPrivileged('rc-service', [
        _openRcName,
        'start',
      ], currentIsRoot: (await _currentIdentity()).isRoot);
    }
    return _systemctl(scope, identity, ['enable', '--now', serviceName]);
  }

  Future<ServiceProcessResult> _deactivate(
    ServiceScope scope,
    LinuxServiceIdentity identity,
  ) async {
    if (scope == ServiceScope.openRc) {
      await _runPrivileged('rc-service', [
        _openRcName,
        'stop',
      ], currentIsRoot: (await _currentIdentity()).isRoot);
      return _runPrivileged('rc-update', [
        'del',
        _openRcName,
        'default',
      ], currentIsRoot: (await _currentIdentity()).isRoot);
    }
    return _systemctl(scope, identity, ['disable', '--now', serviceName]);
  }

  Future<ServiceProcessResult> _commandFor(
    ServiceScope scope,
    LinuxServiceIdentity identity,
    String command,
  ) {
    if (scope == ServiceScope.openRc) {
      return _runPrivileged('rc-service', [
        _openRcName,
        command,
      ], currentIsRoot: false);
    }
    return _systemctl(scope, identity, [command, serviceName]);
  }

  Future<ServiceProcessResult> _reload(
    ServiceScope scope,
    LinuxServiceIdentity identity,
  ) {
    if (scope == ServiceScope.openRc) {
      return Future.value(const ServiceProcessResult(exitCode: 0));
    }
    return _systemctl(scope, identity, const ['daemon-reload']);
  }

  Future<ServiceProcessResult> _systemctl(
    ServiceScope scope,
    LinuxServiceIdentity identity,
    List<String> arguments,
  ) {
    if (scope == ServiceScope.systemdUser) {
      return runner('systemctl', [
        '--user',
        ...arguments,
      ], _userManagerEnvironment(identity));
    }
    return _runPrivileged('systemctl', arguments, currentIsRoot: false);
  }

  Map<String, String> _userManagerEnvironment(LinuxServiceIdentity identity) {
    final runtime = p.join(_paths.userRuntimeDirectory, '${identity.uid}');
    return {
      ...environment,
      'HOME': identity.home,
      'XDG_RUNTIME_DIR': runtime,
      'DBUS_SESSION_BUS_ADDRESS': 'unix:path=$runtime/bus',
    };
  }

  Future<ServiceProcessResult> _runPrivileged(
    String executable,
    List<String> arguments, {
    required bool currentIsRoot,
  }) async {
    final root = currentIsRoot || (await _currentIdentity()).isRoot;
    return root
        ? runner(executable, arguments, null)
        : runner('sudo', ['--', executable, ...arguments], null);
  }

  Future<_ConfigTransaction> _replaceConfig({
    required String targetPath,
    required String content,
    required bool privileged,
    required bool executableMode,
  }) async {
    final stage = File(p.join(sanadHome, '.service-unit-${pid.toString()}'));
    await stage.parent.create(recursive: true);
    final sink = stage.openWrite(mode: FileMode.writeOnly);
    sink.write(content);
    await sink.flush();
    await sink.close();
    final backup = '$targetPath.sanad-backup';
    final existed = File(targetPath).existsSync();
    ServiceProcessResult result;
    if (privileged) {
      if (existed) {
        result = await _runPrivileged('cp', [
          '--preserve=mode,ownership',
          targetPath,
          backup,
        ], currentIsRoot: false);
        if (!result.succeeded) {
          return _ConfigTransaction.failed(result.conciseError);
        }
      }
      result = await _runPrivileged('install', [
        '-m',
        executableMode ? '0755' : '0644',
        stage.path,
        targetPath,
      ], currentIsRoot: false);
    } else {
      final target = File(targetPath);
      await target.parent.create(recursive: true);
      if (existed) await target.copy(backup);
      await stage.rename(targetPath);
      result = const ServiceProcessResult(exitCode: 0);
    }
    if (stage.existsSync()) {
      await stage.delete();
    }
    if (!result.succeeded) {
      return _ConfigTransaction.failed(result.conciseError);
    }
    return _ConfigTransaction(
      commit: () async {
        if (privileged) {
          if (existed) {
            await _runPrivileged('rm', ['-f', backup], currentIsRoot: false);
          }
        } else if (File(backup).existsSync()) {
          await File(backup).delete();
        }
      },
      rollback: () async {
        if (privileged) {
          if (existed) {
            await _runPrivileged('mv', [
              '-f',
              backup,
              targetPath,
            ], currentIsRoot: false);
          } else {
            await _runPrivileged('rm', [
              '-f',
              targetPath,
            ], currentIsRoot: false);
          }
        } else if (existed) {
          await File(backup).rename(targetPath);
        } else if (File(targetPath).existsSync()) {
          await File(targetPath).delete();
        }
      },
    );
  }

  Future<ServiceProcessResult> _removeConfig(
    String path, {
    required bool privileged,
  }) async {
    if (!File(path).existsSync()) {
      return const ServiceProcessResult(exitCode: 0);
    }
    if (privileged) {
      return _runPrivileged('rm', ['-f', path], currentIsRoot: false);
    }
    await File(path).delete();
    return const ServiceProcessResult(exitCode: 0);
  }

  Future<void> _writeMetadata({
    required ServiceScope scope,
    required String configPath,
    required String sanadHome,
    required LinuxServiceIdentity identity,
  }) async {
    final file = File(_metadataPath);
    await file.parent.create(recursive: true);
    if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('Refusing symlinked service ownership metadata.');
    }
    final temporary = File('${file.path}.tmp-$pid');
    final sink = temporary.openWrite(mode: FileMode.writeOnly);
    sink.write(
      jsonEncode({
        'version': 1,
        'scope': scope.wireName,
        'config_path': configPath,
        'sanad_home': sanadHome,
        'user': identity.userName,
        'group': identity.groupName,
        'uid': identity.uid,
        'home': identity.home,
        'dedicated': identity.dedicated,
      }),
    );
    await sink.flush();
    await sink.close();
    await temporary.rename(file.path);
  }

  Future<Map<String, Object?>?> _readMetadata() async {
    final file = File(_metadataPath);
    if (!file.existsSync()) return null;
    if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      return null;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map<String, Object?> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<LinuxServiceIdentity> _identityFromMetadata(
    Map<String, Object?> metadata,
  ) async => LinuxServiceIdentity(
    userName: metadata['user'] as String,
    groupName: metadata['group'] as String,
    uid: metadata['uid'] as int,
    home: metadata['home'] as String,
    isRoot: false,
    dedicated: metadata['dedicated'] as bool? ?? false,
  );

  String _pathFor(ServiceScope scope) => switch (scope) {
    ServiceScope.systemdUser => _userUnitPath,
    ServiceScope.systemdSystem => _systemUnitPath,
    ServiceScope.openRc => _openRcPath,
    _ => throw StateError('Unsupported Linux service scope ${scope.wireName}.'),
  };

  Iterable<String> _conflictingPaths(ServiceScope selected) =>
      <MapEntry<ServiceScope, String>>[
        MapEntry(ServiceScope.systemdUser, _userUnitPath),
        MapEntry(ServiceScope.systemdSystem, _systemUnitPath),
        MapEntry(ServiceScope.openRc, _openRcPath),
      ].where((entry) => entry.key != selected).map((entry) => entry.value);

  ServiceOperationResult _failure(ServiceStatus status, String error) =>
      ServiceOperationResult(success: false, status: status, error: error);

  String _concise(Object error) =>
      error.toString().replaceFirst(RegExp(r'^[^:]+: '), '').split('\n').first;

  static String buildSystemdUnit({
    required String executable,
    required List<String> arguments,
    required String sanadHome,
    required bool systemScope,
    required String user,
    required String group,
    required String home,
  }) {
    final command = [executable, ...arguments].map(_systemdQuote).join(' ');
    return '''[Unit]
Description=Sanad Local Agent Daemon
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
${systemScope ? 'User=$user\nGroup=$group\n' : ''}ExecStart=$command
WorkingDirectory=${_systemdPath(sanadHome)}
Environment="HOME=${_systemdEscape(home)}"
Environment="SANAD_HOME=${_systemdEscape(sanadHome)}"
Restart=on-failure
RestartSec=10
KillMode=control-group
TimeoutStopSec=90
UMask=0077
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=${systemScope ? 'multi-user.target' : 'default.target'}
''';
  }

  static String buildOpenRcScript({
    required String executable,
    required List<String> arguments,
    required String sanadHome,
    required String user,
    required String group,
  }) =>
      '''#!/sbin/openrc-run
name="Sanad Local Agent Daemon"
description="Sanad Local Agent Daemon"
command=${_shellQuote(executable)}
command_args=${_shellQuote(arguments.map(_shellQuote).join(' '))}
command_user=${_shellQuote('$user:$group')}
directory=${_shellQuote(sanadHome)}
umask=0077
supervisor=supervise-daemon
respawn_delay=10
respawn_max=5
output_log=${_shellQuote(p.join(sanadHome, 'logs', 'daemon.log'))}
error_log=${_shellQuote(p.join(sanadHome, 'logs', 'daemon.error.log'))}
export HOME=${_shellQuote(p.dirname(sanadHome))}
export SANAD_HOME=${_shellQuote(sanadHome)}

depend() {
  need net
}
''';

  static String _systemdPath(String value) => value
      .replaceAll('\\', r'\x5c')
      .replaceAll(' ', r'\x20')
      .replaceAll('\t', r'\x09')
      .replaceAll('\n', r'\x0a')
      .replaceAll('"', r'\x22')
      .replaceAll('%', '%%');

  static String _systemdQuote(String value) => '"${_systemdEscape(value)}"';
  static String _systemdEscape(String value) => value
      .replaceAll('\\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('%', '%%')
      .replaceAll('\n', ' ');
  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";
}

class _BackendSelection {
  const _BackendSelection(this.scope, this.identity);
  final ServiceScope scope;
  final LinuxServiceIdentity identity;
}

class _LegacyUserMigration {
  _LegacyUserMigration({
    required Future<ServiceProcessResult> Function() commit,
    required Future<void> Function() restore,
  }) : _commit = commit,
       _restore = restore,
       error = null;

  _LegacyUserMigration.failed(this.error)
    : _commit = _failedCommit,
      _restore = _noop;

  final String? error;
  final Future<ServiceProcessResult> Function() _commit;
  final Future<void> Function() _restore;
  bool get ready => error == null;
  Future<ServiceProcessResult> commit() => _commit();
  Future<void> restore() => _restore();

  static Future<ServiceProcessResult> _failedCommit() async =>
      const ServiceProcessResult(exitCode: 1);
  static Future<void> _noop() async {}
}

class _ConfigTransaction {
  _ConfigTransaction({
    required Future<void> Function() commit,
    required Future<void> Function() rollback,
  }) : _commit = commit,
       _rollback = rollback,
       error = null;

  _ConfigTransaction.failed(this.error) : _commit = _noop, _rollback = _noop;

  final String? error;
  final Future<void> Function() _commit;
  final Future<void> Function() _rollback;
  bool get ready => error == null;
  Future<void> commit() => _commit();
  Future<void> rollback() => _rollback();
  static Future<void> _noop() async {}
}
