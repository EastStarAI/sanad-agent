import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/composer_model_chip.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/composer_workspace_chip.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/model_picker_dialog.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_usage_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_cubit.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_error.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_preview.dart';
import 'package:sanad_client/features/schedules/presentation/bloc/schedules_cubit.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_editor_sheet.dart';

import '../../helpers/pump_app.dart';
import 'schedules_test_harness.dart';

const _providerId = 'provider-1';
const _modelId = 'gpt-4o';

/// A minimal provider client: the catalog the model picker lists, the recent
/// write it performs, and the usage answers the shared usage owner asks for.
class _FakeProviderClient extends Fake implements ProviderSetupClient {
  final List<(String, String)> recentRecords = <(String, String)>[];

  @override
  Future<ModelCacheSnapshotDto> modelSnapshot({DeviceConfig? agent}) async {
    return const ModelCacheSnapshotDto(
      instances: [
        ModelCacheInstanceDto(
          id: _providerId,
          displayName: 'Provider One',
          status: 'ready',
          isDefault: true,
          cacheStatus: 'fetched',
          models: [ModelCacheModelDto(id: _modelId), ModelCacheModelDto(id: 'o3-mini')],
        ),
      ],
      recent: [],
    );
  }

  @override
  Stream<ModelCacheUpdateEvent> get modelUpdates => const Stream<ModelCacheUpdateEvent>.empty();

  @override
  Future<List<RecentModelDto>> modelRecentList({DeviceConfig? agent}) async => const [];

  @override
  Future<void> modelRecentRecord({
    required String providerInstanceId,
    required String modelId,
    DeviceConfig? agent,
  }) async {
    recentRecords.add((providerInstanceId, modelId));
  }

  @override
  Future<ProviderUsageSupportDto> usageSupport({
    required List<String> providerInstanceIds,
    DeviceConfig? agent,
  }) async => const ProviderUsageSupportDto(support: {});

  @override
  Future<ProviderUsageResultDto> usageGet({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async => const ProviderUsageResultDto(status: 'unavailable');
}

void main() {
  late SchedulesTestEnvironment environment;
  late FakeSchedulesClient client;
  late ProviderUsageCubit usageCubit;

  setUp(() async {
    environment = SchedulesTestEnvironment();
    client = environment.client;
    await environment.install();
    getIt.registerSingleton<ProviderSetupClient>(_FakeProviderClient());
    usageCubit = ProviderUsageCubit(
      localDeviceId: 'hardware-device-1',
      client: getIt<ProviderSetupClient>(),
    );
    getIt.registerSingleton<ProviderUsageCubit>(usageCubit);
  });

  tearDown(() async {
    await usageCubit.close();
    if (getIt.isRegistered<ProviderUsageCubit>()) await getIt.unregister<ProviderUsageCubit>();
    if (getIt.isRegistered<ProviderSetupClient>()) await getIt.unregister<ProviderSetupClient>();
    await environment.dispose();
  });

  SchedulesCubit newCubit() => SchedulesCubit(
    client: client,
    device: () => deviceFixture(),
  );

  Future<void> openEditor(
    WidgetTester tester, {
    Schedule? schedule,
    SchedulesCubit? cubit,
    Locale locale = const Locale('en'),
  }) async {
    final editorCubit = cubit ?? newCubit();
    await pumpTestApp(
      tester,
      locale: locale,
      conversationCacheRepository: environment.cacheRepository,
      conversationRepository: environment.conversationRepository,
      child: BlocProvider<SchedulesCubit>.value(
        value: editorCubit,
        child: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              key: const Key('open_editor'),
              onPressed: () => ScheduleEditorSheet.show(
                context,
                cubit: editorCubit,
                device: deviceFixture(),
                schedule: schedule,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open_editor')));
    await tester.pumpAndSettle();
    // Past the preview debounce, so no timer outlives the test body.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  /// Taps [finder] after bringing it into the visible part of the sheet's body.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// Types into [finder] after bringing it into the visible part of the body.
  Future<void> enterVisible(WidgetTester tester, Finder finder, String text) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.enterText(finder, text);
    await tester.pumpAndSettle();
  }

  group('validation', () {
    testWidgets('the task is required and no request is sent until it is present', (tester) async {
      await openEditor(tester);
      final l10n = await l10nFor('en');

      expect(find.byKey(const Key('schedule_editor_sheet')), findsOneWidget);
      // The preview is only the Agent's definition answer; creating needs a task.
      await tester.tap(find.byKey(const Key('schedule_editor_submit_btn')));
      await tester.pumpAndSettle();

      expect(find.text(l10n.scheduleTaskRequired), findsOneWidget);
      expect(client.createCalls, isEmpty);

      await tester.enterText(find.byKey(const Key('schedule_editor_task_field')), 'Summarise open items');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('schedule_editor_submit_btn')));
      await tester.pumpAndSettle();

      expect(client.createCalls, hasLength(1));
      final draft = client.createCalls.single;
      expect(draft.task, 'Summarise open items');
      expect(draft.definition.kind, ScheduleKind.daily);
      expect(draft.definition.atTime, '09:00');
      expect(draft.conversationMode, ScheduleConversationMode.continuous);
    });

    testWidgets('an unreadable clock time is refused before the request', (tester) async {
      await openEditor(tester);
      final l10n = await l10nFor('en');

      await enterVisible(tester, find.byKey(const Key('schedule_editor_task_field')), 'Do the thing');
      await enterVisible(tester, find.byKey(const Key('schedule_editor_time_field')), '25:99');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('schedule_editor_submit_btn')));
      await tester.pumpAndSettle();

      expect(find.text(l10n.scheduleInvalidTime), findsOneWidget);
      expect(client.createCalls, isEmpty);
    });
  });

  group('preview', () {
    testWidgets('the preview asks the Agent and shows the next run in the schedule zone', (tester) async {
      client.previewResult = SchedulePreview(
        valid: true,
        nextRunAt: DateTime.utc(2026, 10, 25, 6),
        zone: '+03:00',
      );
      await openEditor(tester);
      final l10n = await l10nFor('en');

      expect(client.previewCalls, isNotEmpty);
      expect(find.byKey(const Key('schedule_editor_preview')), findsOneWidget);
      // 06:00 UTC is 09:00 in the schedule's own zone.
      expect(
        find.textContaining('${l10n.scheduleNextRunPreview}: '),
        findsOneWidget,
      );
      expect(find.textContaining('9:00 AM'), findsOneWidget);

      // A change re-asks, once, after the debounce.
      final before = client.previewCalls.length;
      await tester.enterText(find.byKey(const Key('schedule_editor_time_field')), '10:30');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));
      expect(client.previewCalls.length, before + 1);
      expect(client.previewCalls.last.atTime, '10:30');
    });

    testWidgets('an invalid definition is shown as the invalid state with typed copy', (tester) async {
      client.previewResult = const SchedulePreview(
        valid: false,
        errorCode: ScheduleErrorCode.invalidSchedule,
      );
      await openEditor(tester);
      final l10n = await l10nFor('en');

      expect(find.textContaining(l10n.schedulePreviewInvalid), findsOneWidget);
      expect(find.text(l10n.scheduleErrorInvalidSchedule), findsOneWidget);
    });
  });

  group('recurrence fields', () {
    testWidgets('a weekly shape sends only its days and its time', (tester) async {
      await openEditor(tester);

      await tapVisible(tester, find.byKey(const Key('schedule_editor_kind_weekly')));
      await tapVisible(tester, find.byKey(const Key('schedule_editor_weekday_mon')));
      await tapVisible(tester, find.byKey(const Key('schedule_editor_weekday_wed')));
      await enterVisible(tester, find.byKey(const Key('schedule_editor_task_field')), 'Weekly task');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('schedule_editor_submit_btn')));
      await tester.pumpAndSettle();

      final weekly = client.createCalls.single.definition;
      expect(weekly.kind, ScheduleKind.weekly);
      expect(weekly.weekdays, [ScheduleWeekday.mon, ScheduleWeekday.wed]);
      expect(weekly.atTime, '09:00');
      expect(weekly.monthDay, isNull);
      expect(weekly.intervalMinutes, isNull);
    });

    testWidgets('a monthly shape sends its day of month', (tester) async {
      await openEditor(tester);

      await tapVisible(tester, find.byKey(const Key('schedule_editor_kind_monthly')));
      await enterVisible(tester, find.byKey(const Key('schedule_editor_day_of_month_field')), '15');
      await enterVisible(tester, find.byKey(const Key('schedule_editor_task_field')), 'Monthly task');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('schedule_editor_submit_btn')));
      await tester.pumpAndSettle();

      final monthly = client.createCalls.single.definition;
      expect(monthly.kind, ScheduleKind.monthly);
      expect(monthly.monthDay, 15);
      expect(monthly.weekdays, isEmpty);
    });
  });

  group('edit', () {
    testWidgets('the owning conversation is shown read-only', (tester) async {
      final schedule = scheduleFixture(ownerSessionId: 'session-1', ownerSessionTitle: 'Morning brief runs');
      await openEditor(tester, schedule: schedule);
      final l10n = await l10nFor('en');

      expect(find.byKey(const Key('schedule_editor_owner_readonly')), findsOneWidget);
      expect(find.text(l10n.scheduleOwnedByConversation('Morning brief runs')), findsOneWidget);
      // There is no conversation picker anywhere (D8).
      expect(find.byKey(const Key('schedule_editor_workspace_chip')), findsOneWidget);
    });

    testWidgets('saving sends an update for the same row', (tester) async {
      final schedule = scheduleFixture();
      await openEditor(tester, schedule: schedule);

      await tester.enterText(find.byKey(const Key('schedule_editor_name_field')), 'Renamed');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('schedule_editor_submit_btn')));
      await tester.pumpAndSettle();

      expect(client.updateCalls, hasLength(1));
      final update = client.updateCalls.single;
      expect(update.id, 'task_1');
      expect(update.name.value, 'Renamed');
      expect(update.definition?.kind, ScheduleKind.daily);
      expect(client.createCalls, isEmpty);
    });
  });

  group('reuse', () {
    testWidgets('the form renders the shared workspace and model chips', (tester) async {
      await openEditor(tester);

      expect(find.byType(ComposerWorkspaceChip), findsOneWidget);
      expect(find.byType(ComposerModelChip), findsOneWidget);
      expect(find.byKey(const Key('schedule_editor_workspace_chip')), findsOneWidget);
      expect(find.byKey(const Key('schedule_editor_model_chip')), findsOneWidget);
    });

    testWidgets('the model chip opens the existing picker and reports the pick', (tester) async {
      await openEditor(tester);

      await tapVisible(tester, find.byKey(const Key('model_selector_btn')));

      expect(find.byType(ModelPickerDialog), findsOneWidget);

      await tapVisible(tester, find.text('o3-mini'));

      expect(find.byType(ModelPickerDialog), findsNothing);
      await tester.enterText(find.byKey(const Key('schedule_editor_task_field')), 'Picked a model');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('schedule_editor_submit_btn')));
      await tester.pumpAndSettle();

      expect(client.createCalls.single.model, 'o3-mini');
      expect(client.createCalls.single.providerInstanceId, _providerId);
    });
  });

  group('localization', () {
    testWidgets('the form renders right-to-left in Arabic', (tester) async {
      await openEditor(tester, locale: const Locale('ar'));
      final ar = await l10nFor('ar');

      expect(
        Directionality.of(tester.element(find.byKey(const Key('schedule_editor_sheet')))),
        TextDirection.rtl,
      );
      expect(find.text(ar.scheduleNewTitle), findsOneWidget);
      expect(find.text(ar.scheduleTask), findsOneWidget);
      expect(find.text(ar.scheduleRecurrence), findsOneWidget);
      expect(find.text(ar.scheduleCreate), findsOneWidget);
    });
  });
}
