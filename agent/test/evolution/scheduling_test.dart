import 'package:sanad_agent/evolution/scheduling/schedule_model.dart';
import 'package:test/test.dart';

void main() {
  group('Scheduling Module Tests (Gate A1)', () {
    group('Vocabulary Parsing and Validation (Decision D2)', () {
      test('parses valid once schedules', () {
        // Absolute
        final abs = ScheduleDefinition.parse({
          'kind': 'once',
          'at': '2026-10-20T15:30:00Z',
        });
        expect(abs.kind, ScheduleKind.once);
        expect(abs.onceAt, DateTime.utc(2026, 10, 20, 15, 30));
        expect(abs.humanRecurrenceSummary, contains('once at'));

        // Relative "in 15 minutes"
        final rel = ScheduleDefinition.parse({
          'kind': 'once',
          'in': '15 minutes',
        }, now: DateTime.utc(2026, 10, 18, 12, 0));
        expect(rel.kind, ScheduleKind.once);
        expect(rel.onceIn, const Duration(minutes: 15));
        expect(rel.humanRecurrenceSummary, 'once in 15 minutes');

        // Relative with "in 2 hours"
        final relH = ScheduleDefinition.parse({
          'kind': 'once',
          'in': '2 hours',
        }, now: DateTime.utc(2026, 10, 18, 12, 0));
        expect(relH.onceIn, const Duration(hours: 2));

        // Legacy "time" parameter with relative format
        final legRel = ScheduleDefinition.parse({
          'time': 'in 3 days',
        }, now: DateTime.utc(2026, 10, 18, 12, 0));
        expect(legRel.kind, ScheduleKind.once);
        expect(legRel.onceIn, const Duration(days: 3));

        // Legacy "time" parameter with ISO-8601 format
        final legAbs = ScheduleDefinition.parse({
          'time': '2026-11-01T08:00:00Z',
        });
        expect(legAbs.kind, ScheduleKind.once);
        expect(legAbs.onceAt, DateTime.utc(2026, 11, 1, 8, 0));
      });

      test('parses valid interval schedules', () {
        final intv = ScheduleDefinition.parse({
          'kind': 'interval',
          'every': 'every 30 minutes',
        });
        expect(intv.kind, ScheduleKind.interval);
        expect(intv.intervalMinutes, 30);
        expect(intv.humanRecurrenceSummary, 'every 30 minutes');

        final intvHours = ScheduleDefinition.parse({
          'every': '2 hours',
        });
        expect(intvHours.kind, ScheduleKind.interval);
        expect(intvHours.intervalMinutes, 120);
        expect(intvHours.humanRecurrenceSummary, 'every 2 hours');

        final intvDays = ScheduleDefinition.parse({
          'every': 'every 1 days',
        });
        expect(intvDays.intervalMinutes, 1440);
        expect(intvDays.humanRecurrenceSummary, 'every 1 day');

        final intvExplicit = ScheduleDefinition.parse({
          'interval_minutes': 45,
        });
        expect(intvExplicit.intervalMinutes, 45);
        expect(intvExplicit.humanRecurrenceSummary, 'every 45 minutes');
      });

      test('parses valid daily schedules', () {
        final daily = ScheduleDefinition.parse({
          'kind': 'daily',
          'time': '05:00',
        });
        expect(daily.kind, ScheduleKind.daily);
        expect(daily.atTime, '05:00');
        expect(daily.humanRecurrenceSummary, 'daily at 05:00');
      });

      test('parses valid weekly schedules', () {
        final weeklyList = ScheduleDefinition.parse({
          'kind': 'weekly',
          'weekdays': ['mon', 'wed', 'fri'],
          'time': '09:30',
        });
        expect(weeklyList.kind, ScheduleKind.weekly);
        expect(weeklyList.atTime, '09:30');
        expect(weeklyList.weekdays, ['mon', 'wed', 'fri']);
        expect(
          weeklyList.humanRecurrenceSummary,
          'weekly on mon, wed, fri at 09:30',
        );

        // String with mixed casing and order
        final weeklyStr = ScheduleDefinition.parse({
          'weekdays': 'Sun, Tue, Thu',
          'time': '18:00',
        });
        expect(weeklyStr.kind, ScheduleKind.weekly);
        expect(weeklyStr.weekdays, ['tue', 'thu', 'sun']);
      });

      test('parses valid monthly schedules', () {
        final monthly = ScheduleDefinition.parse({
          'kind': 'monthly',
          'day_of_month': 31,
          'time': '14:00',
        });
        expect(monthly.kind, ScheduleKind.monthly);
        expect(monthly.monthDay, 31);
        expect(monthly.atTime, '14:00');
        expect(monthly.humanRecurrenceSummary, 'monthly on day 31 at 14:00');
      });

      test('rejects unknown kind', () {
        expect(
          () => ScheduleDefinition.parse({'kind': 'yearly', 'time': '12:00'}),
          throwsA(
            isA<ScheduleValidationException>().having(
              (e) => e.message,
              'message',
              contains('Unknown schedule kind "yearly"'),
            ),
          ),
        );
      });

      test('rejects malformed HH:MM time', () {
        for (final bad in ['25:00', '12:60', '8:00', 'noon', '12:00:00']) {
          expect(
            () => ScheduleDefinition.parse({'kind': 'daily', 'time': bad}),
            throwsA(
              isA<ScheduleValidationException>().having(
                (e) => e.message,
                'message',
                contains('Invalid time "$bad"'),
              ),
            ),
          );
        }
      });

      test('rejects out-of-range weekday', () {
        expect(
          () => ScheduleDefinition.parse({
            'kind': 'weekly',
            'weekdays': ['mon', 'funday'],
            'time': '10:00',
          }),
          throwsA(
            isA<ScheduleValidationException>().having(
              (e) => e.message,
              'message',
              contains('Invalid weekday "funday"'),
            ),
          ),
        );
      });

      test('rejects day_of_month outside 1..31', () {
        for (final bad in [0, 32, -5]) {
          expect(
            () => ScheduleDefinition.parse({
              'kind': 'monthly',
              'day_of_month': bad,
              'time': '10:00',
            }),
            throwsA(
              isA<ScheduleValidationException>().having(
                (e) => e.message,
                'message',
                contains('Invalid day_of_month "$bad"'),
              ),
            ),
          );
        }
      });

      test('rejects non-positive interval', () {
        expect(
          () => ScheduleDefinition.parse({
            'kind': 'interval',
            'interval_minutes': 0,
          }),
          throwsA(isA<ScheduleValidationException>()),
        );
        expect(
          () => ScheduleDefinition.parse({
            'kind': 'interval',
            'every': 'every 0 minutes',
          }),
          throwsA(isA<ScheduleValidationException>()),
        );
      });

      test('rejects interval mixed with calendar fields', () {
        expect(
          () => ScheduleDefinition.parse({
            'kind': 'interval',
            'every': '15 minutes',
            'time': '05:00',
          }),
          throwsA(
            isA<ScheduleValidationException>().having(
              (e) => e.message,
              'message',
              contains('Interval schedule cannot be combined with calendar fields'),
            ),
          ),
        );
      });

      test('rejects calendar shapes mixed with interval/once fields', () {
        expect(
          () => ScheduleDefinition.parse({
            'kind': 'daily',
            'time': '05:00',
            'every': '10 minutes',
          }),
          throwsA(
            isA<ScheduleValidationException>().having(
              (e) => e.message,
              'message',
              contains('Calendar schedule cannot be combined with interval or once fields'),
            ),
          ),
        );
      });
    });

    group('Timezone Validation and Interpretation (Decision D3)', () {
      test('accepts local and fixed UTC offsets', () {
        final zLocal = ScheduleZone.parse('local');
        expect(zLocal.isLocal, isTrue);

        final zUtc = ScheduleZone.parse('Z');
        expect(zUtc.isLocal, isFalse);
        expect(zUtc.offset, Duration.zero);

        final zPlus = ScheduleZone.parse('+02:00');
        expect(zPlus.offset, const Duration(hours: 2));

        final zMinus = ScheduleZone.parse('-05:30');
        expect(zMinus.offset, const Duration(hours: -5, minutes: -30));
      });

      test('rejects IANA timezone names with clear message', () {
        for (final iana in [
          'America/New_York',
          'Europe/London',
          'UTC',
          'Asia/Tokyo',
          'PST',
          'EST',
        ]) {
          expect(
            () => ScheduleZone.parse(iana),
            throwsA(
              isA<ScheduleValidationException>().having(
                (e) => e.message,
                'message',
                allOf(
                  contains('Invalid timezone "$iana"'),
                  contains('IANA timezone identifiers are not supported in this release'),
                ),
              ),
            ),
          );
        }
      });
    });

    group('Occurrence Computation (OccurrenceCalculator)', () {
      test('computes once in the future, relative, and in the past', () {
        final now = DateTime.utc(2026, 10, 18, 10, 0);

        // Future absolute
        final futureAbs = ScheduleDefinition(
          kind: ScheduleKind.once,
          zone: 'Z',
          onceAt: DateTime.utc(2026, 10, 18, 12, 0),
        );
        expect(
          OccurrenceCalculator.computeNextOccurrence(futureAbs, from: now),
          DateTime.utc(2026, 10, 18, 12, 0),
        );

        // Past absolute: preserved as parsed instant
        final pastAbs = ScheduleDefinition(
          kind: ScheduleKind.once,
          zone: 'Z',
          onceAt: DateTime.utc(2026, 10, 18, 8, 0),
        );
        expect(
          OccurrenceCalculator.computeNextOccurrence(pastAbs, from: now),
          DateTime.utc(2026, 10, 18, 8, 0),
        );

        // Relative
        final rel = ScheduleDefinition(
          kind: ScheduleKind.once,
          zone: 'Z',
          onceIn: const Duration(minutes: 45),
        );
        expect(
          OccurrenceCalculator.computeNextOccurrence(rel, from: now),
          DateTime.utc(2026, 10, 18, 10, 45),
        );
      });

      test('computes interval anchored on previous run', () {
        final now = DateTime.utc(2026, 10, 18, 12, 0);
        final intv = ScheduleDefinition(
          kind: ScheduleKind.interval,
          intervalMinutes: 15,
          zone: 'local',
        );

        // No previous run: now + 15 min
        final next1 = OccurrenceCalculator.computeNextOccurrence(intv, from: now);
        expect(next1, DateTime.utc(2026, 10, 18, 12, 15));

        // Previous run at 11:50: anchor + 15 min = 12:05
        final next2 = OccurrenceCalculator.computeNextOccurrence(
          intv,
          from: now,
          previousRunAt: DateTime.utc(2026, 10, 18, 11, 50),
        );
        expect(next2, DateTime.utc(2026, 10, 18, 12, 5));

        // Stale previous run at 11:00: advances in 15 min steps until strictly after now
        final next3 = OccurrenceCalculator.computeNextOccurrence(
          intv,
          from: now,
          previousRunAt: DateTime.utc(2026, 10, 18, 11, 0),
        );
        expect(next3, DateTime.utc(2026, 10, 18, 12, 15));
      });

      test('computes daily across spring-forward and fall-back (pinning gap/fold)', () {
        // Simulated timezone: UTC+1 standard, UTC+2 daylight saving.
        // Spring forward: 2026-03-29 01:00 UTC (02:00 local -> 03:00 local)
        // Fall back: 2026-10-25 01:00 UTC (03:00 local -> 02:00 local)
        final dstZone = ScheduleZone.simulatedDst(
          raw: '+01:00',
          standardOffset: const Duration(hours: 1),
          daylightOffset: const Duration(hours: 2),
          springForwardUtc: DateTime.utc(2026, 3, 29, 1, 0),
          fallBackUtc: DateTime.utc(2026, 10, 25, 1, 0),
        );

        final dailySchedule = ScheduleDefinition(
          kind: ScheduleKind.daily,
          atTime: '05:00',
          zone: '+01:00',
        );

        // 1. Day before spring forward (standard time: 05:00 local = 04:00 UTC)
        final beforeSpring = DateTime.utc(2026, 3, 28, 6, 0);
        final nextSpring1 = OccurrenceCalculator.computeNextOccurrence(
          dailySchedule,
          from: beforeSpring,
          zoneOverride: dstZone,
        );
        // Next run is March 29 05:00 local = 03:00 UTC (since offset is now +2)
        expect(nextSpring1, DateTime.utc(2026, 3, 29, 3, 0));
        expect(dstZone.toZoned(nextSpring1).hour, 5);
        expect(dstZone.toZoned(nextSpring1).minute, 0);

        // 2. Day of spring forward: next day is March 30
        final nextSpring2 = OccurrenceCalculator.computeNextOccurrence(
          dailySchedule,
          from: nextSpring1,
          zoneOverride: dstZone,
        );
        expect(nextSpring2, DateTime.utc(2026, 3, 30, 3, 0));
        expect(dstZone.toZoned(nextSpring2).hour, 5);

        // 3. Gap instant test: daily at 02:30 local during spring forward
        // 02:30 local does not exist in standard time; resolves deterministically
        final gapSchedule = ScheduleDefinition(
          kind: ScheduleKind.daily,
          atTime: '02:30',
          zone: '+01:00',
        );
        final gapInstant = OccurrenceCalculator.computeNextOccurrence(
          gapSchedule,
          from: DateTime.utc(2026, 3, 28, 6, 0),
          zoneOverride: dstZone,
        );
        expect(gapInstant, DateTime.utc(2026, 3, 29, 0, 30));

        // 4. Fall back transition: October 24 -> October 25
        // Before fall back: daylight time (+2), 05:00 local = 03:00 UTC
        final beforeFall = DateTime.utc(2026, 10, 24, 6, 0);
        final nextFall1 = OccurrenceCalculator.computeNextOccurrence(
          dailySchedule,
          from: beforeFall,
          zoneOverride: dstZone,
        );
        // October 25 05:00 local is after 01:00 UTC, so offset is standard (+1), 05:00 local = 04:00 UTC
        expect(nextFall1, DateTime.utc(2026, 10, 25, 4, 0));
        expect(dstZone.toZoned(nextFall1).hour, 5);

        // 5. Fold instant test: daily at 01:30 local during fall back (repeating hour)
        final foldSchedule = ScheduleDefinition(
          kind: ScheduleKind.daily,
          atTime: '01:30',
          zone: '+01:00',
        );
        final foldInstant = OccurrenceCalculator.computeNextOccurrence(
          foldSchedule,
          from: DateTime.utc(2026, 10, 24, 6, 0),
          zoneOverride: dstZone,
        );
        // Resolves deterministically to the first (daylight) fold occurrence
        expect(foldInstant, DateTime.utc(2026, 10, 24, 23, 30));
      });

      test('exercises local zone across host daylight transitions if host observes DST', () {
        // Check if the host operating system zone observes daylight transitions in 2026
        final janOffset = DateTime(2026, 1, 1).timeZoneOffset;
        final julOffset = DateTime(2026, 7, 1).timeZoneOffset;
        if (janOffset == julOffset) {
          markTestSkipped(
            'Host timezone (${DateTime.now().timeZoneName}) does not observe DST transitions; skipping host-local transition test.',
          );
          return;
        }

        // Host observes DST. Find a day with transition.
        DateTime? transitionDay;
        for (int m = 1; m <= 12; m++) {
          for (int d = 1; d <= 27; d++) {
            final dt1 = DateTime(2026, m, d, 12);
            final dt2 = DateTime(2026, m, d + 1, 12);
            if (dt1.timeZoneOffset != dt2.timeZoneOffset) {
              transitionDay = dt1;
              break;
            }
          }
          if (transitionDay != null) break;
        }

        if (transitionDay == null) {
          markTestSkipped('Host observes DST but transition day could not be bounded.');
          return;
        }

        final dailySchedule = ScheduleDefinition(
          kind: ScheduleKind.daily,
          atTime: '15:00',
          zone: 'local',
        );

        // Occurrence computed strictly across the transition boundary
        final fromUtc = transitionDay.toUtc();
        final nextOccurrence = OccurrenceCalculator.computeNextOccurrence(
          dailySchedule,
          from: fromUtc,
        );

        final localDt = nextOccurrence.toLocal();
        expect(localDt.hour, 15);
        expect(localDt.minute, 0);
        expect(nextOccurrence.isAfter(fromUtc), isTrue);
      });

      test('computes weekly with multiple weekdays', () {
        // Monday 2026-10-19 10:00 UTC
        final mondayMorning = DateTime.utc(2026, 10, 19, 10, 0);

        final weekly = ScheduleDefinition(
          kind: ScheduleKind.weekly,
          weekdays: ['tue', 'thu'],
          atTime: '09:00',
          zone: 'Z',
        );

        // Next is Tuesday 2026-10-20 09:00 UTC
        final next1 = OccurrenceCalculator.computeNextOccurrence(
          weekly,
          from: mondayMorning,
        );
        expect(next1, DateTime.utc(2026, 10, 20, 9, 0));

        // From Tuesday 10:00 UTC, next is Thursday 2026-10-22 09:00 UTC
        final next2 = OccurrenceCalculator.computeNextOccurrence(
          weekly,
          from: DateTime.utc(2026, 10, 20, 10, 0),
        );
        expect(next2, DateTime.utc(2026, 10, 22, 9, 0));

        // From Thursday 10:00 UTC, wraps to next Tuesday 2026-10-27 09:00 UTC
        final next3 = OccurrenceCalculator.computeNextOccurrence(
          weekly,
          from: DateTime.utc(2026, 10, 22, 10, 0),
        );
        expect(next3, DateTime.utc(2026, 10, 27, 9, 0));
      });

      test('computes monthly on day 31 skipping months that lack it', () {
        final monthly31 = ScheduleDefinition(
          kind: ScheduleKind.monthly,
          monthDay: 31,
          atTime: '10:00',
          zone: 'Z',
        );

        // January 31 at 12:00 -> February has only 28 days -> April has 30 days
        // Next month with 31 days after Jan 31 is March 31!
        final afterJan31 = DateTime.utc(2026, 1, 31, 12, 0);
        final next1 = OccurrenceCalculator.computeNextOccurrence(
          monthly31,
          from: afterJan31,
        );
        expect(next1, DateTime.utc(2026, 3, 31, 10, 0));

        // After March 31: April has 30 days -> skips April to May 31!
        final afterMar31 = DateTime.utc(2026, 3, 31, 12, 0);
        final next2 = OccurrenceCalculator.computeNextOccurrence(
          monthly31,
          from: afterMar31,
        );
        expect(next2, DateTime.utc(2026, 5, 31, 10, 0));
      });
    });
  });
}
