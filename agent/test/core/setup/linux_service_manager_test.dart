import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/setup/linux_service_manager.dart';
import 'package:sanad_agent/core/setup/service_models.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory loginHome;
  late Directory sanadHome;
  late LinuxServicePaths paths;
  late _FakeServiceHost host;

  setUp(() {
    root = Directory.systemTemp.createTempSync('sanad-linux-service-');
    loginHome = Directory(p.join(root.path, 'home'))
      ..createSync(recursive: true);
    sanadHome = Directory(p.join(loginHome.path, '.sanad'))
      ..createSync(recursive: true);
    paths = LinuxServicePaths(
      systemUnitDirectory: p.join(root.path, 'systemd-system'),
      openRcInitDirectory: p.join(root.path, 'init.d'),
      systemdRuntimeDirectory: p.join(root.path, 'run-systemd'),
      userRuntimeDirectory: p.join(root.path, 'run-user'),
    );
    host = _FakeServiceHost();
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('systemd unit carries durable service safety contract', () {
    final unit = LinuxServiceManager.buildSystemdUnit(
      executable: '/opt/Sanad Agent/sanad',
      arguments: const ['daemon'],
      sanadHome: '/var/lib/Sanad Agent',
      systemScope: true,
      user: 'sanad-agent',
      group: 'sanad-agent',
      home: '/var/lib/sanad-agent',
    );

    expect(unit, contains('User=sanad-agent'));
    expect(unit, contains('Group=sanad-agent'));
    expect(unit, contains('UMask=0077'));
    expect(unit, contains('Restart=on-failure'));
    expect(unit, contains('KillMode=control-group'));
    expect(unit, contains('TimeoutStopSec=90'));
    expect(unit, contains('WantedBy=multi-user.target'));
    expect(unit, contains(r'WorkingDirectory=/var/lib/Sanad\x20Agent'));
    expect(unit, isNot(contains('WorkingDirectory="')));
    expect(unit, contains('ExecStart="/opt/Sanad Agent/sanad" "daemon"'));
  });

  test(
    'selects user systemd only after bus linger and manager probes',
    () async {
      Directory(paths.systemdRuntimeDirectory).createSync(recursive: true);
      final runtime = Directory(p.join(paths.userRuntimeDirectory, '1000'))
        ..createSync(recursive: true);
      File(p.join(runtime.path, 'bus')).createSync();
      host.linger = false;
      final manager = _manager(
        host: host,
        paths: paths,
        loginHome: loginHome.path,
        sanadHome: sanadHome.path,
        identity: _user(loginHome.path),
      );

      final result = await manager.install();

      expect(result.success, isTrue, reason: result.error);
      expect(result.status.scope, ServiceScope.systemdUser);
      expect(result.status.state, ServiceState.running);
      expect(host.linger, isTrue);
      expect(host.commands, contains('loginctl enable-linger developer'));
      final unit = File(
        p.join(loginHome.path, '.config/systemd/user/sanad-agent.service'),
      ).readAsStringSync();
      expect(unit, isNot(contains('User=')));
      expect(File(p.join(sanadHome.path, 'service.json')).existsSync(), isTrue);
    },
  );

  test(
    'falls back to system systemd under the non-root invoking user',
    () async {
      Directory(paths.systemdRuntimeDirectory).createSync(recursive: true);
      final manager = _manager(
        host: host,
        paths: paths,
        loginHome: loginHome.path,
        sanadHome: sanadHome.path,
        identity: _user(loginHome.path),
      );

      final result = await manager.install();

      expect(result.success, isTrue, reason: result.error);
      expect(result.status.scope, ServiceScope.systemdSystem);
      expect(host.commands, contains(startsWith('sudo -- install -m 0644')));
      final unit = File(
        p.join(paths.systemUnitDirectory, 'sanad-agent.service'),
      ).readAsStringSync();
      expect(unit, contains('User=developer'));
      expect(unit, contains('Group=developers'));
      expect(unit, contains('WantedBy=multi-user.target'));
    },
  );

  test(
    'migrates a legacy user unit after system fallback is healthy',
    () async {
      Directory(paths.systemdRuntimeDirectory).createSync(recursive: true);
      final legacy =
          File(
              p.join(
                loginHome.path,
                '.config/systemd/user/sanad-agent.service',
              ),
            )
            ..createSync(recursive: true)
            ..writeAsStringSync('legacy-user-unit');
      host.active = true;
      host.enabled = true;
      final manager = _manager(
        host: host,
        paths: paths,
        loginHome: loginHome.path,
        sanadHome: sanadHome.path,
        identity: _user(loginHome.path),
      );

      final result = await manager.install();

      expect(result.success, isTrue, reason: result.error);
      expect(result.status.scope, ServiceScope.systemdSystem);
      expect(legacy.existsSync(), isFalse);
      expect(
        File(
          p.join(paths.systemUnitDirectory, 'sanad-agent.service'),
        ).existsSync(),
        isTrue,
      );
      expect(
        host.commands,
        contains('systemctl --user disable --now sanad-agent.service'),
      );
    },
  );

  test(
    'direct root install creates and runs a dedicated unprivileged identity',
    () async {
      Directory(paths.systemdRuntimeDirectory).createSync(recursive: true);
      final dedicatedHome = p.join(root.path, 'dedicated-home');
      host.accountExists = false;
      final manager = _manager(
        host: host,
        paths: paths,
        loginHome: '/root',
        sanadHome: sanadHome.path,
        dedicatedHome: dedicatedHome,
        identity: const LinuxServiceIdentity(
          userName: 'root',
          groupName: 'root',
          uid: 0,
          home: '/root',
          isRoot: true,
        ),
      );

      final result = await manager.install();

      expect(result.success, isTrue, reason: result.error);
      expect(
        host.commands,
        contains(startsWith('useradd --system --user-group')),
      );
      final unit = File(
        p.join(paths.systemUnitDirectory, 'sanad-agent.service'),
      ).readAsStringSync();
      expect(unit, contains('User=sanad-agent'));
      expect(unit, contains('Environment="HOME=$dedicatedHome"'));
      expect(Directory(dedicatedHome).existsSync(), isTrue);
    },
  );

  test('uses native OpenRC lifecycle when systemd is unavailable', () async {
    host.openRcAvailable = true;
    Directory(paths.openRcInitDirectory).createSync(recursive: true);
    final manager = _manager(
      host: host,
      paths: paths,
      loginHome: loginHome.path,
      sanadHome: sanadHome.path,
      identity: _user(loginHome.path),
    );

    final installed = await manager.install();
    final stopped = await manager.stop();
    final started = await manager.start();
    final removed = await manager.uninstall();

    expect(installed.success, isTrue, reason: installed.error);
    expect(installed.status.scope, ServiceScope.openRc);
    expect(stopped.success, isTrue);
    expect(started.success, isTrue);
    expect(removed.success, isTrue);
    expect(
      File(p.join(paths.openRcInitDirectory, 'sanad-agent')).existsSync(),
      isFalse,
    );
    expect(
      host.commands,
      contains('sudo -- rc-update add sanad-agent default'),
    );
  });

  test(
    'failed activation restores the previous unit transactionally',
    () async {
      Directory(paths.systemdRuntimeDirectory).createSync(recursive: true);
      final previous = File(
        p.join(paths.systemUnitDirectory, 'sanad-agent.service'),
      )..createSync(recursive: true);
      previous.writeAsStringSync('previous-unit');
      host.activationFails = true;
      final manager = _manager(
        host: host,
        paths: paths,
        loginHome: loginHome.path,
        sanadHome: sanadHome.path,
        identity: _user(loginHome.path),
      );

      final result = await manager.install();

      expect(result.success, isFalse);
      expect(previous.readAsStringSync(), 'previous-unit');
      expect(File('${previous.path}.sanad-backup').existsSync(), isFalse);
      expect(
        File(p.join(sanadHome.path, 'service.json')).existsSync(),
        isFalse,
      );
      expect(
        host.commands,
        contains('sudo -- systemctl disable --now sanad-agent.service'),
      );
    },
  );

  test('failed post-activation health restores the previous unit', () async {
    Directory(paths.systemdRuntimeDirectory).createSync(recursive: true);
    final previous =
        File(p.join(paths.systemUnitDirectory, 'sanad-agent.service'))
          ..createSync(recursive: true)
          ..writeAsStringSync('previous-unit');
    final manager = LinuxServiceManager(
      serviceName: 'sanad-agent.service',
      executable: '/opt/sanad/bin/sanad',
      arguments: const ['daemon'],
      sanadHome: sanadHome.path,
      loginHome: loginHome.path,
      environment: const {},
      runner: host.run,
      paths: paths,
      identity: _user(loginHome.path),
      postActivationVerification: () async => 'cloud registration timed out',
    );

    final result = await manager.install();

    expect(result.success, isFalse);
    expect(result.error, contains('cloud registration'));
    expect(previous.readAsStringSync(), 'previous-unit');
    expect(host.active, isFalse);
  });

  test('typed status distinguishes an unavailable user manager', () async {
    Directory(paths.systemdRuntimeDirectory).createSync(recursive: true);
    final runtime = Directory(p.join(paths.userRuntimeDirectory, '1000'))
      ..createSync(recursive: true);
    File(p.join(runtime.path, 'bus')).createSync();
    final manager = _manager(
      host: host,
      paths: paths,
      loginHome: loginHome.path,
      sanadHome: sanadHome.path,
      identity: _user(loginHome.path),
    );
    expect((await manager.install()).success, isTrue);
    host.managerUnavailable = true;

    final status = await manager.status();

    expect(status.state, ServiceState.managerUnavailable);
    expect(status.installed, isTrue);
    expect(status.running, isFalse);
    expect(status.error, contains('connect'));
  });

  test('uninstall refuses an unowned service definition', () async {
    Directory(paths.systemdRuntimeDirectory).createSync(recursive: true);
    final unit = File(p.join(paths.systemUnitDirectory, 'sanad-agent.service'))
      ..createSync(recursive: true)
      ..writeAsStringSync('external');
    final manager = _manager(
      host: host,
      paths: paths,
      loginHome: loginHome.path,
      sanadHome: sanadHome.path,
      identity: _user(loginHome.path),
    );

    final result = await manager.uninstall();

    expect(result.success, isFalse);
    expect(result.error, contains('not owned'));
    expect(unit.existsSync(), isTrue);
  });
}

LinuxServiceManager _manager({
  required _FakeServiceHost host,
  required LinuxServicePaths paths,
  required String loginHome,
  required String sanadHome,
  required LinuxServiceIdentity identity,
  String? dedicatedHome,
}) => LinuxServiceManager(
  serviceName: 'sanad-agent.service',
  executable: '/opt/sanad/bin/sanad',
  arguments: const ['daemon'],
  sanadHome: sanadHome,
  loginHome: loginHome,
  environment: const {},
  runner: host.run,
  paths: paths,
  identity: identity,
  dedicatedHomePath: dedicatedHome ?? '/var/lib/sanad-agent',
);

LinuxServiceIdentity _user(String home) => LinuxServiceIdentity(
  userName: 'developer',
  groupName: 'developers',
  uid: 1000,
  home: home,
  isRoot: false,
);

class _FakeServiceHost {
  bool openRcAvailable = false;
  bool linger = true;
  bool active = false;
  bool enabled = false;
  bool activationFails = false;
  bool managerUnavailable = false;
  bool accountExists = true;
  final List<String> commands = [];

  Future<ServiceProcessResult> run(
    String executable,
    List<String> arguments,
    Map<String, String>? environment,
  ) async {
    commands.add([executable, ...arguments].join(' '));
    if (executable == 'sudo') {
      final nested = arguments.sublist(arguments.indexOf('--') + 1);
      return run(nested.first, nested.sublist(1), environment);
    }
    if (executable == 'loginctl') {
      if (arguments.first == 'enable-linger') {
        linger = true;
        return _result(true);
      }
      return _result(true, stdout: linger ? 'yes\n' : 'no\n');
    }
    if (executable == 'install') {
      final source = arguments[2];
      final target = arguments[3];
      File(target).parent.createSync(recursive: true);
      File(source).copySync(target);
      return _result(true);
    }
    if (executable == 'cp') {
      File(arguments[1]).copySync(arguments[2]);
      return _result(true);
    }
    if (executable == 'mv') {
      File(arguments[1]).renameSync(arguments[2]);
      return _result(true);
    }
    if (executable == 'rm') {
      final file = File(arguments.last);
      if (file.existsSync()) file.deleteSync();
      return _result(true);
    }
    if (executable == 'getent') {
      return _result(
        accountExists,
        stdout: accountExists
            ? 'sanad-agent:x:995:995::/var/lib/sanad-agent:/usr/sbin/nologin'
            : '',
      );
    }
    if (executable == 'useradd') {
      accountExists = true;
      return _result(true);
    }
    if (executable == 'rc-service' && arguments.contains('--version')) {
      return _result(openRcAvailable);
    }
    if (executable == 'rc-update') {
      if (arguments.first == 'add') enabled = true;
      if (arguments.first == 'del') enabled = false;
      if (arguments.first == 'show') {
        return _result(true, stdout: enabled ? 'sanad-agent | default' : '');
      }
      return _result(true);
    }
    if (executable == 'rc-service') {
      switch (arguments.last) {
        case 'start':
        case 'restart':
          active = true;
        case 'stop':
          active = false;
        case 'status':
          return ServiceProcessResult(exitCode: active ? 0 : 3);
      }
      return _result(true);
    }
    if (executable == 'systemctl') {
      if (arguments.contains('show-environment')) return _result(true);
      if (arguments.contains('daemon-reload')) return _result(true);
      if (arguments.contains('enable')) {
        if (activationFails) {
          return const ServiceProcessResult(
            exitCode: 1,
            stderr: 'activation failed',
          );
        }
        enabled = true;
        active = true;
        return _result(true);
      }
      if (arguments.contains('disable')) {
        enabled = false;
        active = false;
        return _result(true);
      }
      if (arguments.contains('start') || arguments.contains('restart')) {
        active = true;
        return _result(true);
      }
      if (arguments.contains('stop')) {
        active = false;
        return _result(true);
      }
      if (arguments.contains('is-active')) {
        if (managerUnavailable) {
          return const ServiceProcessResult(
            exitCode: 1,
            stderr: 'Failed to connect to bus',
          );
        }
        return ServiceProcessResult(
          exitCode: active ? 0 : 3,
          stdout: active ? 'active\n' : 'inactive\n',
        );
      }
      if (arguments.contains('is-enabled')) {
        return ServiceProcessResult(
          exitCode: enabled ? 0 : 1,
          stdout: enabled ? 'enabled\n' : 'disabled\n',
        );
      }
    }
    return _result(true);
  }

  ServiceProcessResult _result(bool success, {String stdout = ''}) =>
      ServiceProcessResult(exitCode: success ? 0 : 1, stdout: stdout);
}
