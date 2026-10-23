// `ComposerModelChip` must work outside the conversation composer: a caller
// supplies the state and receives the pick, so the schedule form reuses it
// instead of forking the model selector.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/composer_model_chip.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_usage_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_cubit.dart';

const _providerId = 'provider-instance-1';
const _modelId = 'gpt-4o';
final _agent = DeviceConfig(id: 'agent-1', name: 'SanadAgent', isOnline: true);

void main() {
  late _FakeProviderClient client;
  late ProviderUsageCubit usageCubit;

  setUp(() async {
    await getIt.reset();
    client = _FakeProviderClient();
    getIt.registerSingleton<ProviderSetupClient>(client);
    usageCubit = ProviderUsageCubit(localDeviceId: 'hardware-1', client: client);
    getIt.registerSingleton<ProviderUsageCubit>(usageCubit);
  });

  tearDown(() async {
    await usageCubit.close();
    await getIt.reset();
  });

  Widget chip({
    String? providerId = _providerId,
    String? modelId = _modelId,
    required void Function(String providerId, String modelId) onModelSelected,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: ComposerModelChip(
            activeAgent: _agent,
            providerId: providerId,
            modelId: modelId,
            contextUsage: null,
            session: null,
            dimTextColor: Colors.black54,
            chipBgColor: Colors.grey.shade200,
            borderColor: Colors.grey,
            onModelSelected: onModelSelected,
          ),
        ),
      ),
    );
  }

  testWidgets('renders the composer key and the caller route with no conversation cubits', (tester) async {
    // The chip tolerates a deployment without the shared usage owner, exactly
    // as the composer does today.
    await getIt.unregister<ProviderUsageCubit>();

    await tester.pumpWidget(chip(onModelSelected: (_, _) {}));
    await tester.pump();

    // Same key the composer's model selector carries.
    expect(find.byKey(const Key('model_selector_btn')), findsOneWidget);
    // No session and no usage catalog: the label falls back to the provider id.
    expect(find.text('Provider Instance 1 | gpt-4o'), findsOneWidget);
  });

  testWidgets('shows Select model when the caller holds no route', (tester) async {
    await tester.pumpWidget(
      chip(providerId: null, modelId: null, onModelSelected: (_, _) {}),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('model_selector_btn')), findsOneWidget);
    expect(find.text('Select model'), findsOneWidget);
  });

  testWidgets('selecting a model calls onModelSelected with the provider instance and model', (tester) async {
    final picks = <(String, String)>[];
    await tester.pumpWidget(chip(onModelSelected: (providerId, modelId) => picks.add((providerId, modelId))));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('model_selector_btn')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('o3-mini'));
    await tester.pumpAndSettle();

    expect(picks, [(_providerId, 'o3-mini')]);
    expect(client.recentRecords, [(_providerId, 'o3-mini')]);
  });

  testWidgets('provider usage progress and display name follow the caller provider id', (tester) async {
    client.usage = ProviderUsageResultDto(
      status: 'available',
      providerInstanceId: _providerId,
      snapshot: ProviderUsageSnapshotDto(
        providerInstanceId: _providerId,
        providerTemplateId: 'openai',
        source: 'test',
        fetchedAt: DateTime.utc(2026, 1, 1),
        windows: const [
          ProviderUsageWindowDto(type: 'five_hour', label: '5h', usedPercent: 50),
        ],
      ),
    );
    client.support = ProviderUsageSupportDto(support: {_providerId: true});

    await tester.pumpWidget(chip(onModelSelected: (_, _) {}));
    await tester.pumpAndSettle();

    // The daemon-owned display name replaces the humanized provider id once
    // the shared usage owner has loaded it for the caller's device.
    expect(find.text('Provider One | gpt-4o'), findsOneWidget);

    final progress = tester.widgetList<FractionallySizedBox>(find.byType(FractionallySizedBox));
    expect(progress, isNotEmpty, reason: 'a supported provider with a visible snapshot shows its usage fill');
    expect(progress.first.widthFactor, 0.5);
  });
}

/// A minimal provider client: a model catalog, the recent-model write, and the
/// usage answers the shared `ProviderUsageCubit` asks for.
class _FakeProviderClient extends Fake implements ProviderSetupClient {
  final List<(String, String)> recentRecords = [];
  ProviderUsageSupportDto support = const ProviderUsageSupportDto(support: {});
  ProviderUsageResultDto usage = const ProviderUsageResultDto(status: 'unavailable');

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
          models: [
            ModelCacheModelDto(id: _modelId),
            ModelCacheModelDto(id: 'o3-mini'),
          ],
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
  }) async => support;

  @override
  Future<ProviderUsageResultDto> usageGet({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async => usage;
}
