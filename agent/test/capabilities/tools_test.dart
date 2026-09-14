import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/delegate_task_tool.dart';
import 'package:sanad_agent/capabilities/tools/list_scheduled_tasks_tool.dart';
import 'package:sanad_agent/capabilities/tools/runtime/spec_backed_tool.dart';
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

    test('missing typed implementation fails closed', () async {
      final tool = _LegacyTextTool();

      expect(
        () => tool.executeResult({}),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.message,
            'message',
            contains('must provide typed executeResult'),
          ),
        ),
      );
      expect(await tool.execute({}), 'legacy\ntext  ');
    });

    test(
      'callback normalizes string protocol output into typed text',
      () async {
        ToolContext? receivedContext;
        final tool = CallbackTool(
          toolSpec: _callbackSpec,
          onExecute: (args, {context}) async {
            receivedContext = context;
            return 'callback\ntext  ';
          },
        );
        final context = ToolContext(sessionId: 'callback-session');

        final typed = await tool.executeResult({}, context: context);
        final legacy = await tool.execute({}, context: context);

        expect(typed.displayText, 'callback\ntext  ');
        expect(legacy, typed.displayText);
        expect(typed.blocks.single, isA<ToolTextBlock>());
        expect(receivedContext, same(context));
      },
    );

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

const _callbackSpec = LocalToolSpec(
  name: 'callback_test',
  displayName: 'Callback Test',
  description: 'Test callback normalization.',
  inputSchema: {'type': 'object'},
  source: {'type': 'test', 'id': 'callback'},
  category: 'test',
  workspaceRequired: false,
  approval: {'mode': 'default', 'sensitive': false},
  execution: {'target': 'local_runtime', 'timeout_ms': 1000},
  serverName: 'test',
);

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
