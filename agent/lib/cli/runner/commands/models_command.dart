import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';

import '../sanad_command.dart';

/// Command to list and inspect available AI models across configured providers.
class ModelsCommand extends SanadCommand {
  final ProviderInstanceRepository? repositoryOverride;

  ModelsCommand({super.customAction, this.repositoryOverride}) {
    addCommonOptions(argParser);
  }

  @override
  String get name => 'models';

  @override
  String get description => 'List and inspect available AI models';

  @override
  String get invocation => 'sanad models [options]';

  @override
  Future<int> execute() async {
    final stateHome = getSanadStateHome();
    final dbFile = File(p.join(stateHome, 'state.db'));

    AgentStateDatabase? db;
    try {
      final ProviderInstanceRepository repo;
      if (repositoryOverride != null) {
        repo = repositoryOverride!;
      } else if (dbFile.existsSync()) {
        db = AgentStateDatabase.atPath(stateHome);
        repo = ProviderInstanceRepository(db);
      } else {
        stdoutSink.writeln(
          'No local state database found. Run "sanad setup" to configure providers.',
        );
        return 0;
      }

      final instances = repo.findAll();
      if (instances.isEmpty) {
        stdoutSink.writeln('No AI providers configured.');
        stdoutSink.writeln(
          'Run "sanad setup" to add and configure an AI provider.',
        );
        return 0;
      }

      stdoutSink.writeln('Configured Providers & Available Models:');
      for (final inst in instances) {
        final defaultBadge = inst.isDefault ? ' [DEFAULT]' : '';
        stdoutSink.writeln(
          '\n• Provider: ${inst.displayName} (${inst.templateId})$defaultBadge',
        );
        if (inst.defaultModel != null && inst.defaultModel!.isNotEmpty) {
          stdoutSink.writeln('  Default Model: ${inst.defaultModel}');
        }

        final cache =
            repo.readModelCache(inst.id, 'models') ??
            repo.readModelCache(inst.id, 'all') ??
            repo.readModelCache(inst.id, 'default');

        if (cache != null && cache['models'] is List) {
          final models = cache['models'] as List;
          stdoutSink.writeln('  Available Models (${models.length}):');
          for (final m in models) {
            if (m is Map) {
              final val = m['value'] ?? m['id'] ?? m['name'] ?? '';
              final label = m['label'] ?? m['display_name'] ?? '';
              final isDef = val == inst.defaultModel ? ' (active default)' : '';
              final reason = m['supports_reasoning'] == true
                  ? ' [reasoning]'
                  : '';
              if (label.isNotEmpty && label != val) {
                stdoutSink.writeln('    - $val ($label)$reason$isDef');
              } else {
                stdoutSink.writeln('    - $val$reason$isDef');
              }
            } else {
              final isDef = m == inst.defaultModel ? ' (active default)' : '';
              stdoutSink.writeln('    - $m$isDef');
            }
          }
        } else if (inst.defaultModel != null) {
          stdoutSink.writeln('  Available Models:');
          stdoutSink.writeln('    - ${inst.defaultModel} (active default)');
        }
      }
      return 0;
    } catch (e) {
      stderrSink.writeln('Failed to read model catalog: $e');
      return 1;
    } finally {
      db?.dispose();
    }
  }
}
