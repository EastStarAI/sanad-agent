import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/models/auth_session_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_options_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_readiness_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_template_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_usage_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/credential_summary_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/model_picker_dialog.dart';

class _FakeProviderSetupClient extends ProviderSetupClient {
  ModelCacheSnapshotDto snapshotResult = const ModelCacheSnapshotDto(instances: [], recent: []);
  List<RecentModelDto> recentListResult = [];
  ProviderUsageSupportDto usageSupportResult = const ProviderUsageSupportDto(support: {});
  ProviderUsageResultDto usageGetResult = const ProviderUsageResultDto(status: 'unsupported');

  @override
  Future<ModelCacheSnapshotDto> modelSnapshot({DeviceConfig? agent}) async => snapshotResult;

  @override
  Future<List<RecentModelDto>> modelRecentList({DeviceConfig? agent}) async => recentListResult;

  @override
  Future<ProviderUsageSupportDto> usageSupport({
    required List<String> providerInstanceIds,
    DeviceConfig? agent,
  }) async => usageSupportResult;

  @override
  Future<ProviderUsageResultDto> usageGet({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async => usageGetResult;

  @override
  Future<void> modelRefresh({
    required String providerInstanceId,
    bool manual = false,
    DeviceConfig? agent,
  }) async {}

  @override
  Future<void> modelRecentRecord({
    required String providerInstanceId,
    required String modelId,
    DeviceConfig? agent,
  }) async {}

  @override
  Future<ProviderReadinessDto> setupStatus({DeviceConfig? agent}) async =>
      const ProviderReadinessDto(hasProvider: false, runtimeReady: false);
  @override
  Future<ProviderReadinessDto> runtimeCheck({DeviceConfig? agent}) async =>
      const ProviderReadinessDto(hasProvider: false, runtimeReady: false);
  @override
  Future<AuthSessionDto> authStart({
    required String providerId,
    String? providerInstanceId,
    String? templateId,
    String? authMethod,
    DeviceConfig? agent,
  }) async => const AuthSessionDto(sessionId: '1');
  @override
  Future<AuthPollDto> authPoll({required String sessionId, DeviceConfig? agent}) async =>
      const AuthPollDto(status: AuthPollStatus.pending);
  @override
  Future<AuthPollDto> authSubmit({required String sessionId, required String code, DeviceConfig? agent}) async =>
      const AuthPollDto(status: AuthPollStatus.pending);
  @override
  Future<void> authCancel({required String sessionId, DeviceConfig? agent}) async {}
  @override
  Future<String> authStatus({required String providerId, String? providerInstanceId, DeviceConfig? agent}) async =>
      'missing';
  @override
  Future<List<ModelOptionsDto>> modelOptions({String? providerId, bool fetchLive = false, DeviceConfig? agent}) async =>
      [];
  @override
  Future<List<ProviderTemplateDto>> listTemplates({DeviceConfig? agent}) async => [];
  @override
  Future<List<ProviderInstanceDto>> listInstances({DeviceConfig? agent}) async => [];
  @override
  Future<ProviderInstanceDto> createInstance({
    required String templateId,
    required String displayName,
    required String authMethod,
    String? protocol,
    String? baseUrl,
    String? defaultModel,
    int? requestsPerMinute,
    bool? allowAutoFailover,
    bool isDefault = false,
    DeviceConfig? agent,
  }) async => throw UnimplementedError();
  @override
  Future<ProviderInstanceDto> updateInstance({
    required String providerInstanceId,
    String? displayName,
    String? defaultModel,
    String? baseUrl,
    String? protocol,
    int? requestsPerMinute,
    bool? allowAutoFailover,
    DeviceConfig? agent,
  }) async => throw UnimplementedError();
  @override
  Future<ProviderInstanceDto> renameInstance({
    required String providerInstanceId,
    required String displayName,
    DeviceConfig? agent,
  }) async => throw UnimplementedError();
  @override
  Future<void> removeInstance({required String providerInstanceId, DeviceConfig? agent}) async {}
  @override
  Future<void> setInstanceDefault({required String providerInstanceId, DeviceConfig? agent}) async {}
  @override
  Future<Map<String, dynamic>> testInstanceConnection({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async => {};
  @override
  Future<CredentialSummaryDto> updateCredential({
    required String providerInstanceId,
    required String action,
    String? apiKey,
    DeviceConfig? agent,
  }) async => throw UnimplementedError();
  @override
  Future<AuthSessionDto> authReconnect({required String providerInstanceId, DeviceConfig? agent}) async =>
      const AuthSessionDto(sessionId: '1');
  @override
  Future<void> authDisconnect({required String providerInstanceId, DeviceConfig? agent}) async {}
}

void main() {
  late _FakeProviderSetupClient fakeClient;
  late ProviderUsageCubit usageCubit;

  setUp(() async {
    await getIt.reset();
    fakeClient = _FakeProviderSetupClient();
    getIt.registerSingleton<ProviderSetupClient>(fakeClient);
    usageCubit = ProviderUsageCubit(localDeviceId: 'hardware-1', client: fakeClient);
    getIt.registerSingleton<ProviderUsageCubit>(usageCubit);
  });

  tearDown(() async {
    await usageCubit.close();
    await getIt.reset();
  });

  testWidgets('shows at most 5 models by default, expands on Show All, and collapses on Show Less', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final models = List.generate(8, (i) => ModelCacheModelDto(id: 'model-${i + 1}'));
    fakeClient.snapshotResult = ModelCacheSnapshotDto(
      instances: [
        ModelCacheInstanceDto(
          id: 'provider-1',
          displayName: 'Provider One',
          status: 'ready',
          isDefault: true,
          cacheStatus: 'fetched',
          models: models,
        ),
      ],
      recent: const [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () async {
                  await showDialog(
                    context: context,
                    builder: (context) => ModelPickerDialog(
                      onSelected: (providerId, modelId) {},
                    ),
                  );
                },
                child: const Text('Open'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('model-1'), findsOneWidget);
    expect(find.text('model-5'), findsOneWidget);
    expect(find.text('model-6'), findsNothing);
    expect(find.text('8'), findsOneWidget);
    expect(find.text('Load more (3 more)'), findsOneWidget);

    await tester.ensureVisible(find.text('Load more (3 more)'));
    await tester.tap(find.text('Load more (3 more)'));
    await tester.pumpAndSettle();

    expect(find.text('model-6'), findsOneWidget);
    expect(find.text('model-8'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.text('Load more (3 more)'), findsNothing);
    expect(find.text('Show Less'), findsOneWidget);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show Less'));
    await tester.pumpAndSettle();

    expect(find.text('model-6'), findsNothing);
    expect(find.text('8'), findsOneWidget);
    expect(find.text('Load more (3 more)'), findsOneWidget);
  });

  testWidgets('sorts providers (groups) and models by recency', (tester) async {
    final modelsA = [
      const ModelCacheModelDto(id: 'model-a1'),
      const ModelCacheModelDto(id: 'model-a2'),
    ];
    final modelsB = [
      const ModelCacheModelDto(id: 'model-b1'),
      const ModelCacheModelDto(id: 'model-b2'),
    ];

    final recentList = [
      const RecentModelDto(instanceId: 'provider-b', instanceDisplayName: 'Provider B', modelId: 'model-b2'),
      const RecentModelDto(instanceId: 'provider-a', instanceDisplayName: 'Provider A', modelId: 'model-a2'),
    ];

    fakeClient.snapshotResult = ModelCacheSnapshotDto(
      instances: [
        ModelCacheInstanceDto(
          id: 'provider-a',
          displayName: 'Provider A',
          status: 'ready',
          isDefault: false,
          cacheStatus: 'fetched',
          models: modelsA,
        ),
        ModelCacheInstanceDto(
          id: 'provider-b',
          displayName: 'Provider B',
          status: 'ready',
          isDefault: false,
          cacheStatus: 'fetched',
          models: modelsB,
        ),
      ],
      recent: recentList,
    );
    fakeClient.recentListResult = recentList;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () async {
                  await showDialog(
                    context: context,
                    builder: (context) => ModelPickerDialog(
                      onSelected: (providerId, modelId) {},
                    ),
                  );
                },
                child: const Text('Open'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    final listTiles = tester.widgetList<ListTile>(find.byType(ListTile));
    final titleTexts = listTiles.map((t) => (t.title as Text).data).toList();

    final mainModelTexts = titleTexts.where((text) => text != null && !text.contains('/')).toList();
    expect(mainModelTexts, ['model-b2', 'model-b1', 'model-a2', 'model-a1']);
  });

  testWidgets('displays matching search results completely without limits or toggle buttons, and updates count', (
    tester,
  ) async {
    final models = List.generate(8, (i) => ModelCacheModelDto(id: 'gpt-${i + 1}'));
    fakeClient.snapshotResult = ModelCacheSnapshotDto(
      instances: [
        ModelCacheInstanceDto(
          id: 'provider-1',
          displayName: 'Provider One',
          status: 'ready',
          isDefault: true,
          cacheStatus: 'fetched',
          models: models,
        ),
      ],
      recent: const [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () async {
                  await showDialog(
                    context: context,
                    builder: (context) => ModelPickerDialog(
                      onSelected: (providerId, modelId) {},
                    ),
                  );
                },
                child: const Text('Open'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('8'), findsOneWidget);
    expect(find.text('Load more (3 more)'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'gpt');
    await tester.pumpAndSettle();

    expect(find.text('gpt-1'), findsOneWidget);
    expect(find.text('gpt-8'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.textContaining('Load more'), findsNothing);
    expect(find.textContaining('Show Less'), findsNothing);
  });

  testWidgets('formats usage tooltip with remaining percentage and relative reset time', (tester) async {
    final models = [const ModelCacheModelDto(id: 'model-1')];
    fakeClient.snapshotResult = ModelCacheSnapshotDto(
      instances: [
        ModelCacheInstanceDto(
          id: 'provider-1',
          displayName: 'Provider One',
          status: 'ready',
          isDefault: true,
          cacheStatus: 'fetched',
          models: models,
        ),
      ],
      recent: const [],
    );

    fakeClient.usageSupportResult = const ProviderUsageSupportDto(support: {'provider-1': true});
    final now = DateTime.now();
    final resetTime = now.add(const Duration(days: 3));
    fakeClient.usageGetResult = ProviderUsageResultDto(
      status: 'available',
      snapshot: ProviderUsageSnapshotDto(
        providerInstanceId: 'provider-1',
        providerTemplateId: 'template-1',
        source: 'api',
        fetchedAt: now,
        windows: [
          ProviderUsageWindowDto(
            type: 'requests',
            label: 'Requests limit',
            usedPercent: 30.0,
            resetAt: resetTime,
          ),
        ],
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: () async {
                  await showDialog(
                    context: context,
                    builder: (context) => ModelPickerDialog(
                      onSelected: (providerId, modelId) {},
                    ),
                  );
                },
                child: const Text('Open'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await usageCubit.onInstancesLoaded(instanceIds: ['provider-1'], agent: null);
    await tester.pumpAndSettle();

    final tooltipFinder = find.byWidgetPredicate(
      (w) => w is Tooltip && w.message != null && w.message!.contains('Requests limit'),
    );
    expect(tooltipFinder, findsOneWidget);

    final tooltip = tester.widget<Tooltip>(tooltipFinder);
    expect(tooltip.message, contains('Requests limit: 70% remaining (resets in '));
  });
}
