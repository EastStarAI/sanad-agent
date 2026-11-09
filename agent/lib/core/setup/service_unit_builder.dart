import 'package:path/path.dart' as p;

/// Generation of the Linux service definitions this Agent registers.
///
/// Kept apart from `LinuxServiceManager` because the definition text is pure
/// formatting: it decides what the manager will run, and nothing about how the
/// manager writes, activates, or rolls it back.
abstract final class ServiceUnitBuilder {
  /// The systemd unit this Agent registers for a Home.
  ///
  /// `Restart=on-failure` keeps a crashed daemon supervised, and
  /// `SuccessExitStatus=130 143` records the daemon's signal exit statuses
  /// (`SIGINT` 130, `SIGTERM` 143) as successful termination. The daemon
  /// catches both signals and exits with a code instead of dying from them, so
  /// without that line a requested `systemctl stop` would leave the unit in the
  /// `failed` state that `sanad service status` reports as `Failed`.
  static String systemdUnit({
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
SuccessExitStatus=130 143
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

  static String openRcScript({
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

  /// The Sanad Home a definition's own text declares, or null when it declares
  /// none.
  ///
  /// `service status` reads it so a definition that belongs to another Home on
  /// the same host is never reported as the queried Home's unowned service, and
  /// the definition inspector reads it instead of re-deriving the Home from the
  /// rest of the unit body.
  static String? declaredSanadHome(String content) {
    final systemd = RegExp(
      r'^Environment="SANAD_HOME=(.*)"\s*$',
      multiLine: true,
    ).firstMatch(content);
    if (systemd != null) return _systemdUnescape(systemd.group(1)!);
    final openRc = RegExp(
      r"^export SANAD_HOME='(.*)'\s*$",
      multiLine: true,
    ).firstMatch(content);
    if (openRc != null) return openRc.group(1)!.replaceAll("'\\''", "'");
    return null;
  }

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
  static String _systemdUnescape(String value) => value
      .replaceAll(r'\"', '"')
      .replaceAll(r'\\', r'\')
      .replaceAll('%%', '%');
  static String _shellQuote(String value) =>
      "'${value.replaceAll("'", "'\\''")}'";
}
