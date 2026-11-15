import 'package:flutter/material.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
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

/// Renders a wall clock as the user-facing `MMM d, y, HH:mm` text.
///
/// The expected value is built from the instant's own components, so a
/// timezone assertion never reuses the widget's formatting expression: the
/// value passed here is the wall clock the user must read, and a widget that
/// forgets `toLocal()` prints a different one.
String _wallClockText(DateTime value) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '${months[value.month - 1]} ${value.day}, ${value.year}, $hour:$minute';
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
    'reset credits render separately with local expiry and replace the combined count',
    (tester) async {
      // The user-facing instants are authored as local wall clocks and only the
      // wire copy is UTC, so the assertion proves the local conversion instead
      // of repeating it.
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
                availableResets: 2,
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

      expect(
        find.byKey(const Key('provider_usage_reset_credit_a_0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('provider_usage_reset_credit_a_1')),
        findsOneWidget,
      );
      expect(find.text('Reset credit'), findsNWidgets(2));
      expect(find.text('Expires ${_wallClockText(firstLocal)}'), findsOneWidget);
      expect(
        find.text('Expires ${_wallClockText(secondLocal)}'),
        findsOneWidget,
      );
      // The wire timestamps are UTC; on a non-UTC host a missing `toLocal()`
      // would print that wall clock instead and this assertion fails.
      final firstUtcText = 'Expires ${_wallClockText(firstLocal.toUtc())}';
      if (firstUtcText != 'Expires ${_wallClockText(firstLocal)}') {
        expect(find.text(firstUtcText), findsNothing);
      }
      expect(find.text('2 resets available'), findsNothing);
      expect(find.text('Reset limits'), findsOneWidget);
      expect(
        find.byKey(const Key('provider_usage_reset_credit_expiry_a_0')),
        findsOneWidget,
      );
    },
  );

  testWidgets('reset credit copy is localized in Arabic', (tester) async {
    final expiresLocal = DateTime(2026, 11, 15, 10, 30);
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
              availableResets: 1,
              resetCredits: [
                ProviderUsageResetCreditDto(expiresAt: expiresLocal.toUtc()),
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

    expect(find.text('رصيد إعادة ضبط'), findsOneWidget);
    expect(
      find.text('ينتهي في ${_wallClockText(expiresLocal)}'),
      findsOneWidget,
    );
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
      expect(find.text('Reset limits'), findsOneWidget);
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
