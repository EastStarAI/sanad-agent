import 'package:flutter/material.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
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
  /// Credit id carried by each reset request, in call order. A null entry
  /// proves the count-only fallback kept the legacy request.
  final List<String?> creditIds = [];

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
    String? creditId,
    DeviceConfig? agent,
  }) async {
    confirmationTokens.add(confirmationToken);
    creditIds.add(creditId);
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

Widget _wrap(ProviderUsageCubit cubit, Widget child, {String locale = 'en'}) {
  return MaterialApp(
    locale: Locale(locale),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: const [Locale('en'), Locale('ar')],
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
          ProviderUsageSection(agent: null, instanceId: 'a', onReconnect: () {}),
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
          ProviderUsageSection(agent: null, instanceId: 'a', onReconnect: () {}),
        ),
      );
      await tester.pump();
      expect(find.text('Usage & limits'), findsOneWidget);
      // The section is addressable by key the moment it renders (issue 339
      // review 3).
      expect(find.byKey(const Key('provider_usage_section_a')), findsOneWidget);
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
                planName: 'Pro',
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
          ProviderUsageSection(agent: null, instanceId: 'a', onReconnect: () {}),
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

      // Every body line is reachable through a stable, locale-independent key.
      expect(find.byKey(const Key('provider_usage_section_a')), findsOneWidget);
      expect(find.byKey(const Key('provider_usage_plan_a')), findsOneWidget);
      expect(
        find.byKey(const Key('provider_usage_window_a_weekly')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('provider_usage_window_a_monthly')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'reset countdown includes days and hours and never duplicates the prefix',
    (tester) async {
      final now = DateTime.now();
      cubit.emit(
        cubit.state.upsertEntry(
          _localDeviceId,
          'a',
          ProviderUsageEntry(
            phase: ProviderUsagePhase.fresh,
            fetchedAt: now,
            result: ProviderUsageResultDto(
              status: 'available',
              providerInstanceId: 'a',
              snapshot: ProviderUsageSnapshotDto(
                providerInstanceId: 'a',
                providerTemplateId: 'opencode-go',
                source: 'opencode_go',
                fetchedAt: now,
                windows: [
                  ProviderUsageWindowDto(
                    type: 'weekly',
                    label: 'Weekly',
                    usedPercent: 10.0,
                    resetAt: now.add(
                      const Duration(days: 2, hours: 5, minutes: 5),
                    ),
                  ),
                  ProviderUsageWindowDto(
                    type: 'session',
                    label: 'Session',
                    usedPercent: 20.0,
                    resetAt: now.add(const Duration(hours: 3, minutes: 5)),
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
          ProviderUsageSection(agent: null, instanceId: 'a', onReconnect: () {}),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Usage & limits'));
      await tester.pumpAndSettle();

      expect(find.text('Resets in 2 d 5 h'), findsOneWidget);
      expect(find.text('Resets in 3 h'), findsOneWidget);
      expect(find.textContaining('Resets Resets'), findsNothing);
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
          ProviderUsageSection(agent: null, instanceId: 'a', onReconnect: () {}),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Usage & limits'));
      await tester.pumpAndSettle();

      expect(find.text('Retry'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
      // The action and the message are keyed, not text-addressed.
      expect(find.byKey(const Key('provider_usage_retry_a')), findsOneWidget);
      expect(find.byKey(const Key('provider_usage_reconnect_a')), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const Key('provider_usage_message_a'))).data,
        'Usage information is temporarily unavailable. Please retry.',
      );
      // The daemon's English text is never echoed; the status owns localized
      // copy so an RTL interface is fully translated (issue 339 review 2).
      expect(find.text('service busy'), findsNothing);
      expect(
        find.text('Usage information is temporarily unavailable. Please retry.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'auth_required runs the shared account re-authentication, not a refresh',
    (tester) async {
      var reconnects = 0;
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
          ProviderUsageSection(
            agent: null,
            instanceId: 'a',
            onReconnect: () => reconnects++,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Usage & limits'));
      await tester.pumpAndSettle();

      expect(find.text('Reconnect'), findsOneWidget);
      expect(find.textContaining('Account sign-in is required'), findsOneWidget);
      expect(find.byIcon(Icons.login), findsOneWidget);

      await tester.tap(find.byKey(const Key('provider_usage_reconnect_a')));
      await tester.pumpAndSettle();

      expect(reconnects, 1, reason: 'Reconnect must run the shared action');
      // A usage refresh would have replaced the affordance with a spinner.
      expect(find.text('Reconnect'), findsOneWidget);
    },
  );

  testWidgets(
    'API-key auth_required opens the instance form instead of OAuth reconnect',
    (tester) async {
      var reconnects = 0;
      var credentialUpdates = 0;
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
          ProviderUsageSection(
            agent: null,
            instanceId: 'a',
            onReconnect: () => reconnects++,
            isApiKeyAuth: true,
            onUpdateCredential: () => credentialUpdates++,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Usage & limits'));
      await tester.pumpAndSettle();

      expect(find.text('Update API key'), findsOneWidget);
      expect(
        find.text('Update this provider\'s API key to view usage limits.'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.key_outlined), findsOneWidget);
      expect(
        find.byKey(const Key('provider_usage_reconnect_a')),
        findsNothing,
        reason: 'an API key cannot be repaired by the OAuth reconnect flow',
      );

      await tester.tap(
        find.byKey(const Key('provider_usage_update_api_key_a')),
      );
      await tester.pumpAndSettle();

      expect(credentialUpdates, 1);
      expect(reconnects, 0);
    },
  );

  testWidgets(
    'API-key auth_required without an edit callback degrades to Retry',
    (tester) async {
      var reconnects = 0;
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
          ProviderUsageSection(
            agent: null,
            instanceId: 'a',
            onReconnect: () => reconnects++,
            isApiKeyAuth: true,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Usage & limits'));
      await tester.pumpAndSettle();

      // Without an edit callback there is nothing to open and no OAuth flow a
      // static key could use, so the documented fallback is Retry - never a
      // dead `needsAuth` button.
      expect(find.byKey(const Key('provider_usage_retry_a')), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(
        find.byKey(const Key('provider_usage_update_api_key_a')),
        findsNothing,
      );
      expect(find.byKey(const Key('provider_usage_reconnect_a')), findsNothing);

      await tester.tap(find.byKey(const Key('provider_usage_retry_a')));
      await tester.pumpAndSettle();

      expect(reconnects, 0);
    },
  );

  testWidgets('the usage messages and labels are localized in Arabic', (
    tester,
  ) async {
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
        ProviderUsageSection(agent: null, instanceId: 'a', onReconnect: () {}),
        locale: 'ar',
      ),
    );
    await tester.pump();
    await tester.tap(find.text('الاستخدام والحدود'));
    await tester.pumpAndSettle();

    expect(find.text('إعادة الربط'), findsOneWidget);
    expect(
      find.text('يلزم تسجيل الدخول إلى الحساب لعرض حدود الاستخدام.'),
      findsOneWidget,
    );
    // The keys do not translate with the interface: the same instance id is the
    // counter under `en` and `ar` (issue 339 review 3).
    expect(find.byKey(const Key('provider_usage_section_a')), findsOneWidget);
    expect(find.byKey(const Key('provider_usage_reconnect_a')), findsOneWidget);
    expect(find.byKey(const Key('provider_usage_message_a')), findsOneWidget);
  });

  testWidgets('window labels localize by typed window type with a label '
      'fallback', (tester) async {
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
              providerTemplateId: 'opencode-go',
              source: 'opencode_go_usage_api',
              fetchedAt: DateTime.now().toUtc(),
              windows: const [
                ProviderUsageWindowDto(
                  type: 'weekly',
                  label: 'Weekly',
                  usedPercent: 42,
                  remainingPercent: 58,
                ),
                ProviderUsageWindowDto(
                  type: 'session',
                  label: 'Session',
                  usedPercent: 5,
                  remainingPercent: 95,
                ),
                ProviderUsageWindowDto(
                  type: 'rolling',
                  label: 'Rolling window',
                  usedPercent: 1,
                  remainingPercent: 99,
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
        ProviderUsageSection(agent: null, instanceId: 'a', onReconnect: () {}),
        locale: 'ar',
      ),
    );
    await tester.pump();
    await tester.tap(find.text('الاستخدام والحدود'));
    await tester.pumpAndSettle();

    expect(find.text('أسبوعي'), findsOneWidget);
    expect(find.text('الجلسة'), findsOneWidget);
    expect(find.text('Weekly'), findsNothing);
    // An unknown future type still renders the daemon's label instead of
    // disappearing.
    expect(find.text('Rolling window'), findsOneWidget);
  });

  testWidgets('the reset countdown uses the Arabic singular, dual and plural '
      'forms', (tester) async {
    final now = DateTime.now();
    cubit.emit(
      cubit.state.upsertEntry(
        _localDeviceId,
        'a',
        ProviderUsageEntry(
          phase: ProviderUsagePhase.fresh,
          fetchedAt: now,
          result: ProviderUsageResultDto(
            status: 'available',
            providerInstanceId: 'a',
            snapshot: ProviderUsageSnapshotDto(
              providerInstanceId: 'a',
              providerTemplateId: 'opencode-go',
              source: 'opencode_go',
              fetchedAt: now,
              windows: [
                ProviderUsageWindowDto(
                  type: 'weekly',
                  label: 'Weekly',
                  usedPercent: 10.0,
                  resetAt: now.add(
                    const Duration(days: 2, hours: 5, minutes: 5),
                  ),
                ),
                ProviderUsageWindowDto(
                  type: 'session',
                  label: 'Session',
                  usedPercent: 20.0,
                  resetAt: now.add(
                    const Duration(days: 1, hours: 2, minutes: 5),
                  ),
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
        ProviderUsageSection(agent: null, instanceId: 'a', onReconnect: () {}),
        locale: 'ar',
      ),
    );
    await tester.pump();
    await tester.tap(find.text('الاستخدام والحدود'));
    await tester.pumpAndSettle();

    // Two days is the Arabic dual (no numeral) and five hours is the plural.
    expect(find.text('يُعاد الضبط بعد يومين و5 ساعات'), findsOneWidget);
    // One day and two hours are both dual forms.
    expect(find.text('يُعاد الضبط بعد يوم واحد وساعتين'), findsOneWidget);
  });

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
          ProviderUsageSection(agent: null, instanceId: 'a', onReconnect: () {}),
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

  testWidgets(
    'reset credits stack title over a relative expiry and each row redeems itself',
    (tester) async {
      // Relative text is asserted with an authored margin so a slow pump can
      // never flip `2 d 5 h` into `2 d 4 h`; the exact instant is only in the
      // tooltip, which is asserted from the same instant the widget receives.
      final now = DateTime.now();
      final firstLocal = now.add(const Duration(days: 2, hours: 5, minutes: 30));
      final secondLocal = now.add(
        const Duration(days: 10, hours: 3, minutes: 30),
      );
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
                availableResets: 2,
                resetCredits: [
                  ProviderUsageResetCreditDto(
                    expiresAt: firstLocal.toUtc(),
                    creditId: 'credit-first',
                  ),
                  ProviderUsageResetCreditDto(
                    expiresAt: secondLocal.toUtc(),
                    creditId: 'credit-second',
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      client.resetResults.addAll([
        const ProviderUsageResetResultDto(
          status: 'confirmation_required',
          providerInstanceId: 'a',
          message: 'Resetting now may waste this credit.',
          confirmationToken: 'confirm-first',
        ),
        const ProviderUsageResetResultDto(
          status: 'confirmation_required',
          providerInstanceId: 'a',
          message: 'Resetting now may waste this credit.',
          confirmationToken: 'confirm-second',
        ),
      ]);
      await tester.pumpWidget(
        _wrap(
          cubit,
          ProviderUsageSection(agent: null, instanceId: 'a', onReconnect: () {}),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Usage & limits'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('provider_usage_reset_credit_a_0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('provider_usage_reset_credit_a_1')),
        findsOneWidget,
      );
      expect(find.text('Reset credit'), findsNWidgets(2));
      // Relative by default: no absolute date in the normal state.
      expect(find.text('Expires in 2 d 5 h'), findsOneWidget);
      expect(find.text('Expires in 10 d 3 h'), findsOneWidget);
      expect(
        find.text(DateFormat('EEEE, MMMM d, y, HH:mm').format(firstLocal)),
        findsNothing,
        reason: 'the absolute instant must stay inside the tooltip',
      );
      expect(find.text('2 resets available'), findsNothing);
      // Every credit row owns its own action.
      expect(
        find.byKey(const Key('provider_usage_reset_action_a_0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('provider_usage_reset_action_a_1')),
        findsOneWidget,
      );

      // The tooltip carries the exact local instant for that row.
      expect(
        find.byTooltip(DateFormat('EEEE, MMMM d, y, HH:mm').format(firstLocal)),
        findsOneWidget,
      );
      expect(
        find.byTooltip(DateFormat('EEEE, MMMM d, y, HH:mm').format(secondLocal)),
        findsOneWidget,
      );

      // Pressing a row spends that row's credit, not the earliest one.
      await tester.tap(find.byKey(const Key('provider_usage_reset_action_a_1')));
      await tester.pumpAndSettle();
      expect(client.creditIds, ['credit-second']);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('provider_usage_reset_action_a_0')));
      await tester.pumpAndSettle();
      expect(client.creditIds, ['credit-second', 'credit-first']);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('reset credit expiry and tooltip are localized in Arabic', (
    tester,
  ) async {
    final now = DateTime.now();
    // 2 days → the Arabic dual form; 5 days → the "few" plural form.
    final dualLocal = now.add(const Duration(days: 2, minutes: 30));
    final fewLocal = now.add(const Duration(days: 5, minutes: 30));
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
              availableResets: 2,
              resetCredits: [
                ProviderUsageResetCreditDto(
                  expiresAt: dualLocal.toUtc(),
                  creditId: 'credit-dual',
                ),
                ProviderUsageResetCreditDto(
                  expiresAt: fewLocal.toUtc(),
                  creditId: 'credit-few',
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
        ProviderUsageSection(agent: null, instanceId: 'a', onReconnect: () {}),
        locale: 'ar',
      ),
    );
    await tester.pump();
    await tester.tap(find.text('الاستخدام والحدود'));
    await tester.pumpAndSettle();

    expect(find.text('رصيد إعادة ضبط'), findsNWidgets(2));
    expect(find.text('ينتهي بعد يومين'), findsOneWidget);
    expect(find.text('ينتهي بعد 5 أيام'), findsOneWidget);

    // The tooltip uses the app locale, so it must not fall back to English
    // month names inside an Arabic card.
    final arabicTooltip = DateFormat(
      'EEEE, MMMM d, y, HH:mm',
      'ar',
    ).format(dualLocal);
    expect(find.byTooltip(arabicTooltip), findsOneWidget);
    expect(arabicTooltip.contains('Nov'), isFalse);
  });

  testWidgets(
    'the combined count stays visible when the credit rows disagree with it',
    (tester) async {
      final firstLocal = DateTime(2026, 11, 15, 10, 30);
      final secondLocal = DateTime(2026, 11, 20, 10, 30);
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
                // One credit is dropped while parsing, so the detail rows and
                // the authoritative count disagree.
                availableResets: 3,
                resetCredits: [
                  ProviderUsageResetCreditDto(expiresAt: firstLocal.toUtc()),
                  ProviderUsageResetCreditDto(expiresAt: secondLocal.toUtc()),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(
        _wrap(
          cubit,
          ProviderUsageSection(agent: null, instanceId: 'a', onReconnect: () {}),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Usage & limits'));
      await tester.pumpAndSettle();

      expect(find.text('3 resets available'), findsOneWidget);
      expect(
        find.byKey(const Key('provider_usage_reset_count_a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('provider_usage_reset_credit_a_0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('provider_usage_reset_credit_a_1')),
        findsOneWidget,
      );
      // Two rows, two actions: the count disagreement never hides a row.
      expect(find.text('Reset limits'), findsNWidgets(2));
    },
  );

  testWidgets(
    'an inapplicable credit keeps the rows and disables every action',
    (tester) async {
      final now = DateTime.now();
      final firstLocal = now.add(const Duration(days: 3, minutes: 30));
      final secondLocal = now.add(const Duration(days: 6, minutes: 30));
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
                availableResets: 2,
                // The credits exist and must stay visible, but the provider
                // reports that none can be applied right now.
                applicableResets: 0,
                resetCredits: [
                  ProviderUsageResetCreditDto(
                    expiresAt: firstLocal.toUtc(),
                    creditId: 'credit-first',
                  ),
                  ProviderUsageResetCreditDto(
                    expiresAt: secondLocal.toUtc(),
                    creditId: 'credit-second',
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
          ProviderUsageSection(agent: null, instanceId: 'a', onReconnect: () {}),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Usage & limits'));
      await tester.pumpAndSettle();

      // Both credit rows survive the inapplicable state.
      expect(
        find.byKey(const Key('provider_usage_reset_credit_a_0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('provider_usage_reset_credit_a_1')),
        findsOneWidget,
      );
      expect(
        find.text('This reset credit cannot be applied right now.'),
        findsOneWidget,
      );
      final hint = find.byKey(const Key('provider_usage_reset_blocked_a'));
      expect(hint, findsOneWidget);
      // The explanation sits directly under the first row, above the second.
      final hintTop = tester.getTopLeft(hint).dy;
      expect(
        hintTop,
        greaterThan(
          tester
              .getTopLeft(find.byKey(const Key('provider_usage_reset_credit_a_0')))
              .dy,
        ),
      );
      expect(
        hintTop,
        lessThan(
          tester
              .getTopLeft(find.byKey(const Key('provider_usage_reset_credit_a_1')))
              .dy,
        ),
      );

      // Every row's action is disabled, not just the first one.
      for (final key in ['provider_usage_reset_action_a_0', 'provider_usage_reset_action_a_1']) {
        final button = tester.widget<TextButton>(find.byKey(Key(key)));
        expect(button.onPressed, isNull, reason: '$key is disabled');
      }

      // A disabled action never reaches the daemon.
      await tester.tap(find.byKey(const Key('provider_usage_reset_action_a_0')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('provider_usage_reset_action_a_1')));
      await tester.pump();
      expect(client.confirmationTokens, isEmpty);
      expect(client.creditIds, isEmpty);
      expect(client.resetResults, isEmpty);

      // The same hint is localized.
      await tester.pumpWidget(
        _wrap(
          cubit,
          ProviderUsageSection(agent: null, instanceId: 'a', onReconnect: () {}),
          locale: 'ar',
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('الاستخدام والحدود'));
      await tester.pumpAndSettle();
      expect(
        find.text('لا يمكن استخدام رصيد إعادة الضبط الآن.'),
        findsOneWidget,
      );
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
        ProviderUsageSection(agent: null, instanceId: 'a', onReconnect: () {}),
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
