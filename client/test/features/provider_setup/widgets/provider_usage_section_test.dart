import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_usage_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_state.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_usage_section.dart';

const _localDeviceId = 'hardware-1';

/// Stub client used only to satisfy the data-layer contract for the cubit.
/// The widget tests seed the cubit state directly so this client is never
/// actually called on the wire.
class _NoopClient implements ProviderSetupClient {
  final List<ProviderUsageResetResultDto> resetResults = [];
  final List<String?> confirmationTokens = [];

  @override
  Future<ProviderUsageResultDto> usageGet({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async => ProviderUsageResultDto(
    status: 'available',
    providerInstanceId: providerInstanceId,
    snapshot: ProviderUsageSnapshotDto(
      providerInstanceId: providerInstanceId,
      providerTemplateId: 'openai-codex',
      source: 'test',
      fetchedAt: DateTime.now().toUtc(),
      windows: const [],
    ),
  );

  @override
  Future<ProviderUsageResetResultDto> usageReset({
    required String providerInstanceId,
    required String idempotencyKey,
    String? confirmationToken,
    DeviceConfig? agent,
  }) async {
    confirmationTokens.add(confirmationToken);
    return resetResults.removeAt(0);
  }

  @override
  Future<ProviderUsageSupportDto> usageSupport({
    required List<String> providerInstanceIds,
    DeviceConfig? agent,
  }) async => ProviderUsageSupportDto(support: const {});

  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

Widget _wrap(ProviderUsageCubit cubit, Widget child) {
  return MaterialApp(
    home: Scaffold(
      body: BlocProvider.value(
        value: cubit,
        child: SingleChildScrollView(child: child),
      ),
    ),
  );
}

void main() {
  late _NoopClient client;
  late ProviderUsageCubit cubit;
  setUp(() {
    client = _NoopClient();
    cubit = ProviderUsageCubit(client: client, localDeviceId: _localDeviceId);
    addTearDown(cubit.close);
  });

  testWidgets(
    'renders nothing when entry is missing or phase is hidden (unsupported)',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          cubit,
          const ProviderUsageSection(agent: null, instanceId: 'a'),
        ),
      );
      await tester.pump();
      expect(find.text('Usage & limits'), findsNothing, reason: 'no entry yet must not render a disclosure');

      // Mark as hidden (unsupported on the daemon).
      cubit.emit(
        cubit.state.upsertEntry(
          _localDeviceId,
          'a',
          const ProviderUsageEntry(
            phase: ProviderUsagePhase.hidden,
            result: ProviderUsageResultDto(status: 'unsupported'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Usage & limits'), findsNothing, reason: 'unsupported instances must not render the section');
    },
  );

  testWidgets(
    'loading phase renders a small inline indicator without an empty '
    'snapshot',
    (tester) async {
      cubit.emit(
        cubit.state.upsertEntry(
          _localDeviceId,
          'a',
          const ProviderUsageEntry(phase: ProviderUsagePhase.loading),
        ),
      );
      await tester.pumpWidget(
        _wrap(
          cubit,
          const ProviderUsageSection(agent: null, instanceId: 'a'),
        ),
      );
      await tester.pump();
      expect(find.text('Usage & limits'), findsOneWidget);
      await tester.tap(find.text('Usage & limits'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Loading usage…'), findsOneWidget);
    },
  );

  testWidgets(
    'fresh snapshot with Weekly and Monthly shows remaining-first and used '
    'as secondary; no Session placeholder',
    (tester) async {
      cubit.emit(
        cubit.state.upsertEntry(
          _localDeviceId,
          'a',
          ProviderUsageEntry(
            phase: ProviderUsagePhase.fresh,
            fetchedAt: DateTime.now(),
            result: ProviderUsageResultDto(
              status: 'available',
              providerInstanceId: 'a',
              snapshot: ProviderUsageSnapshotDto(
                providerInstanceId: 'a',
                providerTemplateId: 'openai-codex',
                source: 'chatgpt',
                fetchedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
                windows: const [
                  ProviderUsageWindowDto(
                    type: 'weekly',
                    label: 'Weekly',
                    usedPercent: 42.0,
                  ),
                  ProviderUsageWindowDto(
                    type: 'monthly',
                    label: 'Monthly',
                    remainingPercent: 75.0,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(
        _wrap(
          cubit,
          const ProviderUsageSection(agent: null, instanceId: 'a'),
        ),
      );
      await tester.pump();

      // Expand the disclosure so the body renders.
      await tester.tap(find.text('Usage & limits'));
      await tester.pumpAndSettle();

      // Remaining-first; used is secondary.
      expect(
        find.text('58% remaining'),
        findsOneWidget,
        reason: 'Weekly: used=42 → remaining=58, headline is remaining',
      );
      expect(find.text('42% used'), findsOneWidget);
      expect(find.text('75% remaining'), findsOneWidget, reason: 'Monthly: remaining=75 supplied directly');
      expect(find.text('25% used'), findsOneWidget);
      expect(find.text('Session'), findsNothing, reason: 'no placeholder window when missing');
      expect(
        find.textContaining('Updated'),
        findsOneWidget,
        reason: 'footer Updated label must be present',
      );
    },
  );

  testWidgets(
    'needsAttention shows a concise English message and a Retry button, no '
    'provider metadata is hidden',
    (tester) async {
      cubit.emit(
        cubit.state.upsertEntry(
          _localDeviceId,
          'a',
          const ProviderUsageEntry(
            phase: ProviderUsagePhase.needsAttention,
            result: ProviderUsageResultDto(
              status: 'unavailable',
              message: 'service busy',
              providerInstanceId: 'a',
            ),
          ),
        ),
      );
      await tester.pumpWidget(
        _wrap(
          cubit,
          const ProviderUsageSection(agent: null, instanceId: 'a'),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Usage & limits'));
      await tester.pumpAndSettle();

      expect(find.text('Retry'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      // Typed failure message must be concise and never include raw payload.
      expect(find.text('service busy'), findsOneWidget, reason: 'daemon-safe unavailable message should be shown');
    },
  );

  testWidgets(
    'auth_required shows the Reconnect affordance, not generic retry',
    (tester) async {
      cubit.emit(
        cubit.state.upsertEntry(
          _localDeviceId,
          'a',
          const ProviderUsageEntry(
            phase: ProviderUsagePhase.needsAttention,
            result: ProviderUsageResultDto(
              status: 'auth_required',
              providerInstanceId: 'a',
            ),
          ),
        ),
      );
      await tester.pumpWidget(
        _wrap(
          cubit,
          const ProviderUsageSection(agent: null, instanceId: 'a'),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Usage & limits'));
      await tester.pumpAndSettle();

      expect(find.text('Reconnect'), findsOneWidget);
      expect(find.textContaining('Account sign-in is required'), findsOneWidget);
    },
  );

  testWidgets(
    'Refresh is disabled while a request is in flight (double-submit '
    'protection)',
    (tester) async {
      cubit.emit(
        cubit.state.upsertEntry(
          _localDeviceId,
          'a',
          ProviderUsageEntry(
            phase: ProviderUsagePhase.staleRefreshing,
            backgroundRefreshing: true,
            fetchedAt: DateTime.now(),
            result: ProviderUsageResultDto(
              status: 'available',
              providerInstanceId: 'a',
              snapshot: ProviderUsageSnapshotDto(
                providerInstanceId: 'a',
                providerTemplateId: 'openai-codex',
                source: 'chatgpt',
                fetchedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
                windows: const [
                  ProviderUsageWindowDto(
                    type: 'weekly',
                    label: 'Weekly',
                    usedPercent: 42.0,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(
        _wrap(
          cubit,
          const ProviderUsageSection(agent: null, instanceId: 'a'),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Usage & limits'));
      await tester.pump(const Duration(milliseconds: 300));

      // 'Refreshing…' header appears while snapshot remains visible.
      expect(find.text('Refreshing…'), findsOneWidget);
      expect(
        find.text('58% remaining'),
        findsOneWidget,
        reason: 'stale snapshot stays visible during background refresh',
      );

      // The Refresh button is rendered but its onPressed is null → tap is a
      // no-op even if a user interacts with it.
      final refreshFinder = find.text('Refresh');
      expect(refreshFinder, findsOneWidget);
      final textButton = tester.widget<TextButton>(
        find.ancestor(of: refreshFinder, matching: find.byType(TextButton)),
      );
      expect(textButton.onPressed, isNull);
    },
  );

  testWidgets('reset count is conditional and Reset anyway reuses confirmation', (tester) async {
    ProviderUsageEntry entryWithResets(int count) => ProviderUsageEntry(
      phase: ProviderUsagePhase.fresh,
      fetchedAt: DateTime.now(),
      result: ProviderUsageResultDto(
        status: 'available',
        providerInstanceId: 'a',
        snapshot: ProviderUsageSnapshotDto(
          providerInstanceId: 'a',
          providerTemplateId: 'openai-codex',
          source: 'test',
          fetchedAt: DateTime.now().toUtc(),
          windows: const [
            ProviderUsageWindowDto(
              type: 'weekly',
              label: 'Weekly',
              usedPercent: 40,
              remainingPercent: 60,
            ),
          ],
          availableResets: count,
        ),
      ),
    );

    cubit.emit(
      cubit.state.upsertEntry(
        _localDeviceId,
        'a',
        entryWithResets(0),
      ),
    );
    await tester.pumpWidget(
      _wrap(
        cubit,
        const ProviderUsageSection(agent: null, instanceId: 'a'),
      ),
    );
    await tester.tap(find.text('Usage & limits'));
    await tester.pumpAndSettle();
    expect(find.text('Reset limits'), findsNothing);

    cubit.emit(
      cubit.state.upsertEntry(
        _localDeviceId,
        'a',
        entryWithResets(2),
      ),
    );
    client.resetResults.addAll([
      const ProviderUsageResetResultDto(
        status: 'confirmation_required',
        providerInstanceId: 'a',
        message: 'Resetting now may waste this credit.',
        confirmationToken: 'confirm-a',
      ),
      const ProviderUsageResetResultDto(
        status: 'reset',
        providerInstanceId: 'a',
        message: 'Usage limits were reset successfully.',
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('2 resets available'), findsOneWidget);
    await tester.tap(find.text('Reset limits'));
    await tester.pumpAndSettle();
    expect(find.text('Reset before limits are exhausted?'), findsOneWidget);
    await tester.tap(find.text('Reset anyway'));
    await tester.pumpAndSettle();

    expect(client.confirmationTokens, [null, 'confirm-a']);
  });
}
