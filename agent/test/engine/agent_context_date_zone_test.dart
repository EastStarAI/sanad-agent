import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/engine/agent_context_assembler.dart';
import 'package:test/test.dart';

/// Task 112b Gate B3 (Decision B-D7): one per-turn date line in the schedule
/// timezone, labelled with the zone and carrying no clock time.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('agent_context_date_zone_');
    setSanadHomeOverride(tempDir.path);
    setSanadStateHomeOverride(tempDir.path);
    await GetIt.I.reset();
  });

  tearDown(() async {
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
    await GetIt.I.reset();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  final datePattern = RegExp(r'^Date: \d{4}-\d{2}-\d{2} \(zone: [^)]+\)$');

  group('AgentContextAssembler date line (Task 112b B3)', () {
    test('has the date-and-zone shape with no clock time', () {
      final line = AgentContextAssembler.formatDateLine(
        now: DateTime.utc(2026, 10, 21, 13, 45),
        zoneName: 'Z',
      );
      expect(line, 'Date: 2026-10-21 (zone: Z)');
      expect(line, isNot(contains('13:45')));
      expect(line, isNot(contains('T')));
    });

    test('takes the date in the schedule zone and labels that zone', () {
      final now = DateTime.utc(2026, 10, 21, 22, 30);
      expect(
        AgentContextAssembler.formatDateLine(now: now, zoneName: 'Z'),
        'Date: 2026-10-21 (zone: Z)',
      );
      expect(
        AgentContextAssembler.formatDateLine(now: now, zoneName: '+03:00'),
        'Date: 2026-10-22 (zone: +03:00)',
      );
      expect(
        AgentContextAssembler.formatDateLine(now: now, zoneName: '-05:00'),
        'Date: 2026-10-21 (zone: -05:00)',
      );
      expect(
        AgentContextAssembler.formatDateLine(now: now, zoneName: 'local'),
        endsWith('(zone: local)'),
      );
    });

    test('is byte-stable within one day and changes on the next day', () {
      final morning = AgentContextAssembler.formatDateLine(
        now: DateTime.utc(2026, 10, 21, 0, 1),
        zoneName: 'Z',
      );
      final evening = AgentContextAssembler.formatDateLine(
        now: DateTime.utc(2026, 10, 21, 23, 59),
        zoneName: 'Z',
      );
      final nextDay = AgentContextAssembler.formatDateLine(
        now: DateTime.utc(2026, 10, 22, 0, 1),
        zoneName: 'Z',
      );
      expect(morning, evening);
      expect(nextDay, isNot(morning));
    });

    test('assembled context has exactly one date line, from Config', () {
      GetIt.I.registerSingleton<Config>(
        Config(environment: {'SCHEDULE_TIMEZONE': '+03:00'}),
      );
      final assembler = AgentContextAssembler(identity: 'ID')..setVolatile();
      final dateLines = assembler
          .assemble()!
          .split('\n')
          .where(
            (line) => line.startsWith('Date:') || line.startsWith('Today:'),
          )
          .toList();
      expect(dateLines, hasLength(1));
      expect(datePattern.hasMatch(dateLines.single), isTrue);
      expect(dateLines.single, endsWith('(zone: +03:00)'));
    });

    test('defaults to local without Config and survives an IANA value', () {
      expect(AgentContextAssembler.formatDateLine(), endsWith('(zone: local)'));
      GetIt.I.registerSingleton<Config>(
        Config(environment: {'SCHEDULE_TIMEZONE': 'Africa/Cairo'}),
      );
      final assembler = AgentContextAssembler(identity: 'ID')..setVolatile();
      final result = assembler.assemble()!;
      expect(result, contains('(zone: local)'));
    });
  });
}
