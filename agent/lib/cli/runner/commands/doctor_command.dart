import 'dart:async';
import 'dart:io';
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

    // 4. Local Gateway Daemon Status
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
