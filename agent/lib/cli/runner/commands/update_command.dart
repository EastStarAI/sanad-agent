import 'dart:async';
import 'dart:io';
import '../../../core/app_config.dart';
import '../../../core/constants.dart';
import '../../../core/update/agent_update_service.dart';
import '../sanad_command.dart';

/// Command to check and download the latest native release.
class UpdateCommand extends SanadCommand {
  UpdateCommand({super.customAction});

  @override
  String get name => 'update';

  @override
  String get description => 'Check and download the latest native release';

  @override
  String get invocation => 'sanad update';

  @override
  Future<int> execute() async {
    print('=== Sanad CLI Updater ===');
    final version = loadAgentVersion();
    final service = AgentUpdateService(
      currentVersion: version,
      executablePath: Platform.resolvedExecutable,
      isSourceManaged: AppConfig.isSourceRun,
    );
    final result = await service.update();
    print(result.message ?? result.status.wireName);
    if (result.availableVersion != null) {
      print('Available Version: ${result.availableVersion}');
    }
    if (Platform.isWindows && result.stagedPath != null) {
      await service.scheduleWindowsReplacement(result);
      await Process.run(Platform.resolvedExecutable, ['service', 'stop']);
      print('The verified update will be applied after Sanad exits.');
    }
    return result.isSuccess ? 0 : 1;
  }
}
