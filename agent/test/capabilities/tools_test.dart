import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/delegate_task_tool.dart';
import 'package:sanad_agent/capabilities/tools/list_scheduled_tasks_tool.dart';
import 'package:sanad_agent/capabilities/tools/schedule_task_tool.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/evolution/cron_scheduler.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:test/test.dart';

void main() {
  group('Capabilities Tests', () {
    late ToolsRegistry registry;
    late Directory tempDir;
    late CronScheduler scheduler;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('typed-tools-test-');
      setSanadHomeOverride(tempDir.path);
      setSanadStateHomeOverride(tempDir.path);
      registry = ToolsRegistry();
      scheduler = CronScheduler();
      getIt.registerSingleton<CronScheduler>(scheduler);
    });

    tearDown(() async {
      await scheduler.dispose();
      await GetIt.I.reset();
      SessionManager.resetForTesting();
      setSanadHomeOverride(null);
      setSanadStateHomeOverride(null);
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('Register and retrieve tool', () {
      final tool = DelegateTaskTool();
      registry.registerTool(tool);

      final retrieved = registry.getTool('delegate_task');
      expect(retrieved, isNotNull);
      expect(retrieved?.schema.name, 'delegate_task');
    });

    test('DelegateTaskTool typed validation preserves legacy text', () async {
      final tool = DelegateTaskTool();

      final typed = await tool.executeResult({});
      final legacy = await tool.execute({});

      expect(typed.displayText, legacy);
      expect(typed.isError, isTrue);
      expect(typed.errorCode, ToolResultErrorCode.invalidInput);
    });

    test('default typed bridge preserves legacy text byte-for-byte', () async {
      final tool = _LegacyTextTool();

      final result = await tool.executeResult({});

      expect(result.displayText, 'legacy\ntext  ');
      expect(result.isError, isFalse);
    });

    test(
      'schedule and list typed results preserve legacy projections',
      () async {
        final schedule = ScheduleTaskTool();
        final list = ListScheduledTasksTool();

        final invalidTyped = await schedule.executeResult({
          'task': 'task',
          'time': 'invalid',
        });
        final invalidLegacy = await schedule.execute({
          'task': 'task',
          'time': 'invalid',
        });
        expect(invalidTyped.displayText, invalidLegacy);
        expect(invalidTyped.isError, isTrue);
        expect(invalidTyped.errorCode, ToolResultErrorCode.invalidInput);

        final scheduled = await schedule.executeResult({
          'task': 'typed task',
          'time': 'in 1 hours',
        });
        expect(scheduled.isError, isFalse);
        expect(
          scheduled.displayText,
          startsWith('Task scheduled successfully'),
        );

        final listed = await list.executeResult({});
        final legacyListed = await list.execute({});
        expect(listed.displayText, legacyListed);
        expect(listed.displayText, contains('typed task'));
        expect(listed.isError, isFalse);
      },
    );
  });
}

class _LegacyTextTool extends BaseTool {
  @override
  ToolSchema get schema => ToolSchema(
    name: 'legacy',
    description: 'test',
    parameters: const {'type': 'object'},
  );

  @override
  Future<String> execute(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async => 'legacy\ntext  ';
}
