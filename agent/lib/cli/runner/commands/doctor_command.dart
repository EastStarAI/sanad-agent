import 'dart:async';
import 'dart:io';
import '../../../core/auth/secret_vault.dart';
import '../../../core/constants.dart';
import '../../../core/sanad_home/sanad_home_bootstrap.dart';
import '../../discovery/local_gateway_discovery.dart';
import '../sanad_command.dart';

/// Command to inspect environment health, daemon connectivity, and system diagnostics.
class DoctorCommand extends SanadCommand {
  final LocalGatewayDiscovery discovery;

  DoctorCommand({LocalGatewayDiscovery? discovery, super.customAction})
    : discovery = discovery ?? const LocalGatewayDiscovery();

  @override
  String get name => 'doctor';

  @override
  String get description =>
      'Inspect environment health, daemon connectivity, and system diagnostics';

  @override
  String get invocation => 'sanad doctor [options]';

  @override
  Future<int> execute() async {
    stdoutSink.writeln('=== ⚕ Sanad Agent Doctor ===\n');

    // 1. Platform & Dart Runtime
    stdoutSink.writeln(
      '[✓] Platform: ${Platform.operatingSystem} (${Platform.operatingSystemVersion})',
    );
    stdoutSink.writeln('[✓] Agent Version: ${loadAgentVersion()}');

    // 2. Sanad Home Directory
    final homePath = getSanadHome();
    final homeDir = Directory(homePath);
    if (homeDir.existsSync()) {
      stdoutSink.writeln('[✓] Sanad Home: $homePath (exists)');
    } else {
      stdoutSink.writeln('[!] Sanad Home: $homePath (not yet created)');
    }

    // 3. Environment & Configuration
    final envExists = SanadHomeBootstrap.identity().fileExists('.env');
    if (envExists) {
      stdoutSink.writeln('[✓] Configuration: .env initialized');
    } else {
      stdoutSink.writeln(
        '[!] Configuration: .env not found (run "sanad setup")',
      );
    }

    // 4. Agent vault. A closed vault silently costs every provider key, MCP
    // secret, user secret and the Device Credential, so doctor reports it with
    // the reason code, the recovery steps, and whether this process was even
    // allowed to show the macOS authorization dialog.
    final vault = SecretVaults.current;
    final interaction = SecretVaultPolicy.interactionAllowed
        ? 'this process may show the macOS approval dialog'
        : 'this process cannot show a prompt (${SecretVaultPolicy.interactionCode})';
    if (vault == null) {
      stdoutSink.writeln(
        '[!] Agent Vault: not opened by this command ($interaction)',
      );
    } else if (vault.available) {
      stdoutSink.writeln('[✓] Agent Vault: available ($interaction)');
    } else {
      stdoutSink.writeln(
        '[✗] Agent Vault: unavailable '
        '(${vault.unavailableReason ?? 'unavailable'}; $interaction)',
      );
      stdoutSink.writeln(
        '    Provider keys, MCP secrets, user secrets and the Device Credential '
        'cannot be read until it reopens; no secret was deleted.',
      );
      final diagnostic = vault.unavailableMessage;
      if (diagnostic != null && diagnostic.isNotEmpty) {
        stdoutSink.writeln('    $diagnostic');
      }
      stdoutSink.writeln(
        '    Recovery: rerun this command in an interactive terminal so macOS '
        'can ask once, then approve it; if no dialog appears, open Keychain '
        'Access > Access Control and add the Agent binary you run.',
      );
    }

    // 5. Local Gateway Daemon Status
    try {
      final discoveryResult = await discovery.discover(
        probeTimeout: const Duration(milliseconds: 500),
      );
      if (discoveryResult.isDaemonRunning) {
        stdoutSink.writeln(
          '[✓] Daemon Status: Connected on port ${discoveryResult.port}',
        );
      } else {
        stdoutSink.writeln(
          '[!] Daemon Status: Not running (standalone fallback active)',
        );
      }
    } catch (_) {
      stdoutSink.writeln(
        '[!] Daemon Status: Discovery skipped or daemon unreachable',
      );
    }

    stdoutSink.writeln('\nDoctor inspection completed.');
    return 0;
  }
}
