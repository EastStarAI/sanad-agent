import 'dart:io';
import 'package:get_it/get_it.dart';
import 'package:sanad_agent/capabilities/runtime/runtime_context_builder.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late Directory workspaceDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('runtime_time_awareness_test_');
    workspaceDir = Directory('${tempDir.path}/workspace')..createSync();
    setSanadHomeOverride(tempDir.path);
    setSanadStateHomeOverride(tempDir.path);

    if (GetIt.I.isRegistered<Config>()) {
      await GetIt.I.reset();
    }
    setupDI();
  });

  tearDown(() async {
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
    await GetIt.I.reset();
  });

  group('RuntimeContextBuilder Time Awareness (Gate B3, Decision B-D7)', () {
    test('formatTimeAwarenessLine produces expected shape with no clock time', () {
      final instant = DateTime.utc(2026, 10, 20, 14, 35, 22);

      final line = RuntimeContextBuilder.formatTimeAwarenessLine(
        now: instant,
        zoneName: 'Z',
      );

      // Shape: Today: YYYY-MM-DD (zone: Z)
      expect(line, 'Today: 2026-10-20 (zone: Z)');

      // Contains NO clock time
      expect(line, isNot(contains(':35')));
      expect(line, isNot(contains('14:')));
      expect(line, isNot(matches(r'\d{4}-\d{2}-\d{2}T')));
      expect(RegExp(r'\d{2}:\d{2}').hasMatch(line), isFalse);
    });

    test('zone label matches the resolved zone', () {
      final instant = DateTime.utc(2026, 10, 20, 22, 30);

      // UTC
      final lineUtc = RuntimeContextBuilder.formatTimeAwarenessLine(
        now: instant,
        zoneName: 'Z',
      );
      expect(lineUtc, 'Today: 2026-10-20 (zone: Z)');

      // Offset +03:00 (22:30 UTC + 3h = 01:30 on 2026-10-21)
      final linePlus3 = RuntimeContextBuilder.formatTimeAwarenessLine(
        now: instant,
        zoneName: '+03:00',
      );
      expect(linePlus3, 'Today: 2026-10-21 (zone: +03:00)');

      // Local zone
      final lineLocal = RuntimeContextBuilder.formatTimeAwarenessLine(
        now: instant,
        zoneName: 'local',
      );
      expect(lineLocal, contains('(zone: local)'));
      expect(RegExp(r'^Today: \d{4}-\d{2}-\d{2} \(zone: local\)$').hasMatch(lineLocal), isTrue);
    });

    test('runtime context includes time-awareness line and maintains byte-stability within one day', () async {
      final turn1Time = DateTime.utc(2026, 10, 20, 9, 15);
      final turn2Time = DateTime.utc(2026, 10, 20, 16, 45);
      final nextDayTime = DateTime.utc(2026, 10, 21, 2, 0);

      // Turn 1 at 09:15 UTC
      final builder1 = RuntimeContextBuilder(
        nowProvider: () => turn1Time,
        zoneName: 'Z',
      );
      final context1 = await builder1.build(
        workspacePath: workspaceDir.path,
        workspaceName: 'test_ws',
      );

      // Turn 2 at 16:45 UTC (later same day)
      final builder2 = RuntimeContextBuilder(
        nowProvider: () => turn2Time,
        zoneName: 'Z',
      );
      final context2 = await builder2.build(
        workspacePath: workspaceDir.path,
        workspaceName: 'test_ws',
      );

      // Turn 3 on next day
      final builder3 = RuntimeContextBuilder(
        nowProvider: () => nextDayTime,
        zoneName: 'Z',
      );
      final context3 = await builder3.build(
        workspacePath: workspaceDir.path,
        workspaceName: 'test_ws',
      );

      expect(context1, isNotNull);
      expect(context1, contains('Today: 2026-10-20 (zone: Z)'));

      // Assert exact line shape in real built context output (S1)
      final contextLines = context1!.split('\n');
      final timeLine = contextLines.firstWhere((l) => l.startsWith('Today:'));
      expect(timeLine, 'Today: 2026-10-20 (zone: Z)');
      expect(timeLine, isNot(matches(r'\d{2}:\d{2}')));
      expect(timeLine, isNot(matches(r'\d{4}-\d{2}-\d{2}T')));

      // Byte-identical within the same day (critical for prefix cache stability)
      expect(context1, equals(context2));

      // Updates date on the next day
      expect(context3, contains('Today: 2026-10-21 (zone: Z)'));
      expect(context3, isNot(equals(context1)));
    });

    test('exercises time-awareness line through real context build path resolving zone from Config (S1)', () async {
      // Real context build path with default parameters (reads Config.scheduleTimezone via DI)
      final defaultBuilder = const RuntimeContextBuilder();
      final defaultContext = await defaultBuilder.build(
        workspacePath: workspaceDir.path,
        workspaceName: 'test_ws',
      );

      expect(defaultContext, isNotNull);
      final defaultLines = defaultContext!.split('\n');
      final defaultTimeLine = defaultLines.firstWhere((l) => l.startsWith('Today:'));
      expect(
        RegExp(r'^Today: \d{4}-\d{2}-\d{2} \(zone: local\)$').hasMatch(defaultTimeLine),
        isTrue,
      );
      // Contains no clock time
      expect(defaultTimeLine, isNot(matches(r'\d{2}:\d{2}')));
      expect(defaultTimeLine, isNot(matches(r'\d{4}-\d{2}-\d{2}T')));

      // Test with custom Config scheduleTimezone in env
      final customConfig = Config(environment: {'SCHEDULE_TIMEZONE': '+03:00'});
      await GetIt.I.unregister<Config>();
      GetIt.I.registerSingleton<Config>(customConfig);

      final configuredBuilder = const RuntimeContextBuilder();
      final configuredContext = await configuredBuilder.build(
        workspacePath: workspaceDir.path,
        workspaceName: 'test_ws',
      );

      expect(configuredContext, isNotNull);
      final configuredLines = configuredContext!.split('\n');
      final configuredTimeLine = configuredLines.firstWhere((l) => l.startsWith('Today:'));
      expect(
        RegExp(r'^Today: \d{4}-\d{2}-\d{2} \(zone: \+03:00\)$').hasMatch(configuredTimeLine),
        isTrue,
      );
      final datePrefix = configuredTimeLine.substring(0, configuredTimeLine.indexOf('('));
      expect(datePrefix, isNot(matches(r'\d{2}:\d{2}')));
      expect(datePrefix, isNot(matches(r'\d{4}-\d{2}-\d{2}T')));
    });
  });
}
