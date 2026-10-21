import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/thinking_control.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_state.dart';

import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/route_thinking_mode_selector.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client_impl.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import '../mocks/mock_socket_service.dart';

/// Reads the option ids of the built thinking menu without opening it, so route
/// resolution can be asserted without tapping (and without mutating selection).
/// Every entry is one exact declared native option: the menu offers no synthetic
/// provider-default row.
List<String> thinkingMenuOptionIds(WidgetTester tester) {
  final finder = find.byKey(const Key('route_thinking_mode_selector_button'));
  expect(finder, findsOneWidget);
  final button = tester.widget<PopupMenuButton<String>>(finder);
  return button
      .itemBuilder(tester.element(finder))
      .map((item) => (item as PopupMenuItem<String>).value!)
      .toList(growable: false);
}

/// Reads the secondary annotation of one built menu entry, if any.
String? thinkingMenuSecondaryLabel(WidgetTester tester, String optionId) {
  final finder = find.byKey(const Key('route_thinking_mode_selector_button'));
  final button = tester.widget<PopupMenuButton<String>>(finder);
  final items = button.itemBuilder(tester.element(finder)).cast<PopupMenuItem<String>>();
  final entry = items.where((item) => item.value == optionId).firstOrNull;
  if (entry == null) {
    return null;
  }
  final texts = <String>[];
  void collect(Widget? widget) {
    if (widget == null) {
      return;
    }
    if (widget is Text) {
      final data = widget.data;
      if (data != null) {
        texts.add(data);
      }
      return;
    }
    if (widget is Row) {
      widget.children.forEach(collect);
      return;
    }
    if (widget is Column) {
      widget.children.forEach(collect);
      return;
    }
    if (widget is Flexible) {
      collect(widget.child);
      return;
    }
    if (widget is Expanded) {
      collect(widget.child);
      return;
    }
    if (widget is Padding) {
      collect(widget.child);
      return;
    }
    if (widget is Align) {
      collect(widget.child);
    }
  }

  collect(entry.child);
  return texts.length > 1 ? texts[1] : null;
}

/// Reads the tooltip explanation attached to one selector state container.
String thinkingStateTooltip(WidgetTester tester, String containerKey) {
  final tooltip = tester.widget<Tooltip>(
    find.descendant(
      of: find.byKey(Key(containerKey)),
      matching: find.byType(Tooltip),
    ),
  );
  return tooltip.message ?? '';
}

class _TestRealProviderSetupClient extends ProviderSetupClientImpl {
  _TestRealProviderSetupClient({required super.connectionCoordinator});

  ModelCacheSnapshotDto snapshotResult = const ModelCacheSnapshotDto(instances: [], recent: []);
  int snapshotCallCount = 0;

  @override
  Future<ModelCacheSnapshotDto> modelSnapshot({DeviceConfig? agent}) async {
    snapshotCallCount++;
    return snapshotResult;
  }
}

class _FakeProviderSetupClient extends Fake implements ProviderSetupClient {
  Completer<ModelCacheSnapshotDto>? pendingSnapshotCompleter;
  ModelCacheSnapshotDto snapshotResult = const ModelCacheSnapshotDto(
    instances: [],
    recent: [],
  );
  bool shouldThrow = false;

  int callCount = 0;
  final modelUpdatesController = StreamController<ModelCacheUpdateEvent>.broadcast();

  @override
  Stream<ModelCacheUpdateEvent> get modelUpdates => modelUpdatesController.stream;

  final modelSnapshotsController = StreamController<ModelSnapshotPublication>.broadcast();

  @override
  Stream<ModelSnapshotPublication> get modelSnapshots => modelSnapshotsController.stream;

  @override
  Future<ModelCacheSnapshotDto> modelSnapshot({DeviceConfig? agent}) async {
    callCount++;
    if (shouldThrow) {
      throw Exception('Network error');
    }
    if (pendingSnapshotCompleter != null) {
      return pendingSnapshotCompleter!.future;
    }
    return snapshotResult;
  }
}

class _TestConversationInputCubit extends Cubit<ConversationInputState> implements ConversationInputCubit {
  @override
  void reportRouteThinkingAdmission({
    required String? providerId,
    required String? modelId,
    required bool admitsSelection,
  }) {}

  _TestConversationInputCubit({this.mirrorSessionCubit}) : super(const ConversationInputState());

  /// Mirrors the composer's real preference write into a session cubit so the
  /// mounted control observes the admitted value exactly as it would in the app.
  final _TestSessionCubit? mirrorSessionCubit;

  CapabilityValueScope? selectedScope;
  String? selectedThinkingMode;
  int selectCount = 0;

  /// Mirrors the composer's own active-session ownership, which the real
  /// `ConversationInputCubit` receives from `SessionMessagesCubit`.
  void setActiveSession(String? sessionId) {
    emit(
      state.copyWith(
        activeSessionId: sessionId,
        clearActiveSessionId: sessionId == null,
      ),
    );
  }

  @override
  Future<void> selectThinkingMode({
    required CapabilityValueScope scope,
    String? thinkingMode,
  }) async {
    selectedScope = scope;
    selectedThinkingMode = thinkingMode;
    selectCount++;
    mirrorSessionCubit?.setThinkingMode(thinkingMode);
  }

  /// Display-only admissions for an open conversation, with the conversation
  /// that owned each one. They never write a preference (live acceptance 106b
  /// r2 G2), so they are kept apart from [selectCount].
  final List<({String? ownerId, String? thinkingMode})> admissions = [];

  int get admitCount => admissions.length;

  String? get admittedThinkingMode => admissions.isEmpty ? null : admissions.last.thinkingMode;

  /// The explicit (user-chosen) thinking value the composer carries; a draft
  /// resolves its effective selection from it.
  String? explicitThinkingMode;

  @override
  String? get explicitNextMessageThinkingMode => explicitThinkingMode;

  @override
  void admitRouteThinkingMode(String? thinkingMode) {
    admissions.add(
      (ownerId: mirrorSessionCubit?.state.selectedSession?.id, thinkingMode: thinkingMode),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestSessionCubit extends Cubit<SessionState> implements SessionCubit {
  _TestSessionCubit([Session? initialSession]) : super(SessionState(selectedSession: initialSession));

  /// Every applied thinking write, with the conversation that owned it at the
  /// moment the write happened.
  final List<({String? ownerId, String? thinkingMode})> thinkingWrites = [];

  void setSession(Session? session) {
    emit(state.copyWith(selectedSession: session));
  }

  /// Applies the equivalent of the composer's persisted thinking preference.
  void setThinkingMode(String? thinkingMode) {
    final session = state.selectedSession;
    if (session == null) {
      return;
    }
    final trimmed = thinkingMode?.trim();
    (thinkingWrites).add(
      (ownerId: session.id, thinkingMode: trimmed == null || trimmed.isEmpty ? null : trimmed),
    );
    setSession(
      trimmed == null || trimmed.isEmpty
          ? session.copyWith(clearThinkingMode: true)
          : session.copyWith(thinkingMode: trimmed),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ConversationInputSlice createInputSlice({
  String? nextMessageProviderId,
  String? nextMessageModel,
  String? nextMessageThinkingMode,
}) {
  return ConversationInputSlice(
    isProcessing: false,
    nextMessageProviderId: nextMessageProviderId,
    nextMessageModel: nextMessageModel,
    nextMessageThinkingMode: nextMessageThinkingMode,
    availableWorkspaces: const [],
    selectedWorkspace: null,
    isLoadingWorkspaces: false,
    requiresWorkspace: false,
    permissionMode: WorkspacePermissionMode.defaultMode,
    isLoadingPermissionMode: false,
    pendingSuspendedRequest: null,
    runtimeNotice: null,
    queuedMessages: const [],
  );
}

void main() {
  late _FakeProviderSetupClient fakeClient;

  setUp(() async {
    if (getIt.isRegistered<ProviderSetupClient>()) {
      await getIt.unregister<ProviderSetupClient>();
    }
    fakeClient = _FakeProviderSetupClient();
    getIt.registerSingleton<ProviderSetupClient>(fakeClient);
  });

  tearDown(() async {
    await fakeClient.modelUpdatesController.close();
    await fakeClient.modelSnapshotsController.close();
    if (getIt.isRegistered<ProviderSetupClient>()) {
      await getIt.unregister<ProviderSetupClient>();
    }
  });

  Widget createWidget({
    required ConversationInputSlice inputSlice,
    Capability capabilities = const Capability(
      supportsThinkingModeChange: true,
      thinkingModeSource: ThinkingModeSource.model,
    ),
    DeviceConfig? activeAgent,
    ConversationInputCubit? inputCubit,
    SessionCubit? sessionCubit,
    Locale? locale,
  }) {
    Widget child = Scaffold(
      body: RouteThinkingModeSelector(
        capabilities: capabilities,
        inputSlice: inputSlice,
        activeAgent: activeAgent,
        chipBuilder: (context, label, {required enabled}) {
          return Text(label, key: Key('chip_$label'));
        },
      ),
    );
    if (inputCubit != null) {
      child = BlocProvider<ConversationInputCubit>.value(
        value: inputCubit,
        child: child,
      );
    }
    if (sessionCubit != null) {
      child = BlocProvider<SessionCubit>.value(
        value: sessionCubit,
        child: child,
      );
    }
    return MaterialApp(
      home: child,
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    );
  }

  testWidgets('renders Loading... chip without cache while awaiting snapshot', (
    tester,
  ) async {
    fakeClient.pendingSnapshotCompleter = Completer<ModelCacheSnapshotDto>();

    final sessionCubit = _TestSessionCubit(
      Session(
        id: 'session-1',
        title: 'Session 1',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        modelProvider: 'provider-1',
        model: 'model-a',
      ),
    );
    final inputCubit = _TestConversationInputCubit(
      mirrorSessionCubit: sessionCubit,
    );

    final inputSlice = createInputSlice(
      nextMessageProviderId: 'provider-1',
      nextMessageModel: 'model-a',
    );

    await tester.pumpWidget(
      createWidget(
        inputSlice: inputSlice,
        inputCubit: inputCubit,
        sessionCubit: sessionCubit,
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('route_thinking_mode_loading')),
      findsOneWidget,
    );
    expect(find.text('Loading...'), findsOneWidget);
    expect(
      find.byKey(const Key('route_thinking_mode_unavailable')),
      findsNothing,
    );

    fakeClient.pendingSnapshotCompleter!.complete(
      const ModelCacheSnapshotDto(
        instances: [
          ModelCacheInstanceDto(
            id: 'provider-1',
            displayName: 'P1',
            status: 'ready',
            isDefault: true,
            cacheStatus: 'fetched',
            models: [
              ModelCacheModelDto(
                id: 'model-a',
                thinkingControl: ThinkingControlDescriptorDto(
                  status: ThinkingCapabilityStatus.supported,
                  defaultOptionId: 'low',
                  options: [
                    ThinkingControlOptionDto(id: 'low', label: 'Low'),
                    ThinkingControlOptionDto(id: 'high', label: 'High'),
                  ],
                ),
              ),
            ],
          ),
        ],
        recent: [],
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byKey(const Key('route_thinking_mode_loading')), findsNothing);
    expect(
      find.byKey(const Key('route_thinking_mode_selector_button')),
      findsOneWidget,
    );
    // The declared native default is admitted for display and the next send
    // only: the open conversation's preference is never written (G2).
    expect(find.byKey(const Key('chip_Low')), findsOneWidget);
    expect(inputCubit.admitCount, 1);
    expect(inputCubit.admittedThinkingMode, 'low');
    expect(inputCubit.selectCount, 0);
    expect(find.byKey(const Key('chip_Default')), findsNothing);
    expect(
      thinkingMenuOptionIds(tester),
      <String>['high', 'low'],
      reason: 'the resolved route offers exactly its declared native options',
    );
    expect(
      thinkingMenuSecondaryLabel(tester, 'low'),
      'Provider default',
      reason: 'only the declared native default carries the menu-only hint',
    );
    expect(
      thinkingMenuSecondaryLabel(tester, 'high'),
      isNull,
      reason: 'no provider-default annotation is rendered on any other option',
    );
  });

  testWidgets('renders Retry chip on fetch failure and retries on tap', (
    tester,
  ) async {
    fakeClient.shouldThrow = true;

    final inputSlice = createInputSlice(
      nextMessageProviderId: 'provider-1',
      nextMessageModel: 'model-a',
    );

    await tester.pumpWidget(createWidget(inputSlice: inputSlice));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('route_thinking_mode_fetch_failure')),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byKey(const Key('route_thinking_mode_loading')), findsNothing);

    fakeClient.shouldThrow = false;
    fakeClient.snapshotResult = const ModelCacheSnapshotDto(
      instances: [
        ModelCacheInstanceDto(
          id: 'provider-1',
          displayName: 'P1',
          status: 'ready',
          isDefault: true,
          cacheStatus: 'fetched',
          models: [
            ModelCacheModelDto(
              id: 'model-a',
              thinkingControl: ThinkingControlDescriptorDto(
                status: ThinkingCapabilityStatus.supported,
                options: [ThinkingControlOptionDto(id: 'high', label: 'High')],
              ),
            ),
          ],
        ),
      ],
      recent: [],
    );

    await tester.tap(
      find.byKey(const Key('route_thinking_mode_fetch_failure')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('route_thinking_mode_fetch_failure')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('route_thinking_mode_selector_button')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('route_thinking_mode_selector_button')),
      findsOneWidget,
    );
    expect(thinkingMenuOptionIds(tester), contains('high'));
  });

  testWidgets('a later successful snapshot for the device clears the Retry chip (Task 124 D5)', (tester) async {
    fakeClient.shouldThrow = true;
    final inputSlice = createInputSlice(
      nextMessageProviderId: 'provider-1',
      nextMessageModel: 'model-a',
    );
    await tester.pumpWidget(createWidget(inputSlice: inputSlice));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('route_thinking_mode_fetch_failure')), findsOneWidget);
    final callsAfterFailure = fakeClient.callCount;

    // Another consumer's snapshot load for this device succeeds later.
    fakeClient.modelSnapshotsController.add(
      const ModelSnapshotPublication(
        deviceId: null,
        snapshot: ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    options: [ThinkingControlOptionDto(id: 'high', label: 'High')],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('route_thinking_mode_fetch_failure')), findsNothing);
    expect(find.byKey(const Key('route_thinking_mode_selector_button')), findsOneWidget);
    expect(fakeClient.callCount, callsAfterFailure, reason: 'the published snapshot is adopted without a new request');
  });

  testWidgets(
    'renders a distinct unknown chip without Off label',
    (tester) async {
      fakeClient.snapshotResult = const ModelCacheSnapshotDto(
        instances: [
          ModelCacheInstanceDto(
            id: 'provider-1',
            displayName: 'P1',
            status: 'ready',
            isDefault: true,
            cacheStatus: 'fetched',
            models: [
              ModelCacheModelDto(
                id: 'model-unknown',
                thinkingControl: ThinkingControlDescriptorDto(
                  status: ThinkingCapabilityStatus.unknown,
                ),
              ),
            ],
          ),
        ],
        recent: [],
      );

      final inputSlice = createInputSlice(
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'model-unknown',
      );

      await tester.pumpWidget(createWidget(inputSlice: inputSlice));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('route_thinking_mode_unknown')),
        findsOneWidget,
      );
      expect(find.text('Not reported'), findsOneWidget);
      expect(
        find.byKey(const Key('route_thinking_mode_no_control')),
        findsNothing,
        reason: 'unknown evidence must stay distinct from resolved no-control',
      );
      expect(
        find.byKey(const Key('route_thinking_mode_hidden')),
        findsNothing,
        reason: 'the thinking control stays visible for every model route',
      );
      // Unknown evidence must not be presented as a chosen level.
      expect(find.text('Default'), findsNothing);
      expect(find.text('Off'), findsNothing);
      expect(find.text('Unavailable'), findsNothing);
      expect(
        find.byKey(const Key('route_thinking_mode_selector_button')),
        findsNothing,
        reason: 'no selectable menu exists for unknown evidence',
      );
    },
  );

  testWidgets(
    'isolates identical model IDs across different provider instances',
    (tester) async {
      fakeClient.snapshotResult = const ModelCacheSnapshotDto(
        instances: [
          ModelCacheInstanceDto(
            id: 'provider-1',
            displayName: 'P1',
            status: 'ready',
            isDefault: true,
            cacheStatus: 'fetched',
            models: [
              ModelCacheModelDto(
                id: 'shared-model-id',
                thinkingControl: ThinkingControlDescriptorDto(
                  status: ThinkingCapabilityStatus.supported,
                  options: [
                    ThinkingControlOptionDto(id: 'high', label: 'High Effort'),
                  ],
                ),
              ),
            ],
          ),
          ModelCacheInstanceDto(
            id: 'provider-2',
            displayName: 'P2',
            status: 'ready',
            isDefault: false,
            cacheStatus: 'fetched',
            models: [
              ModelCacheModelDto(
                id: 'shared-model-id',
                thinkingControl: ThinkingControlDescriptorDto(
                  status: ThinkingCapabilityStatus.unknown,
                ),
              ),
            ],
          ),
        ],
        recent: [],
      );

      final inputSlice1 = createInputSlice(
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'shared-model-id',
      );

      await tester.pumpWidget(createWidget(inputSlice: inputSlice1));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('route_thinking_mode_selector_button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('route_thinking_mode_selector_button')),
        findsOneWidget,
      );
      expect(
        thinkingMenuOptionIds(tester),
        contains('high'),
        reason: 'provider-1 resolves its own High Effort option',
      );

      final inputSlice2 = createInputSlice(
        nextMessageProviderId: 'provider-2',
        nextMessageModel: 'shared-model-id',
      );

      await tester.pumpWidget(createWidget(inputSlice: inputSlice2));
      await tester.pumpAndSettle();

      expect(find.text('High Effort'), findsNothing);
      expect(
        find.byKey(const Key('route_thinking_mode_unknown')),
        findsOneWidget,
        reason: 'the second provider reported no thinking control for this id',
      );
      expect(
        find.byKey(const Key('route_thinking_mode_no_control')),
        findsNothing,
      );
      expect(find.text('Not reported'), findsOneWidget);
    },
  );

  testWidgets(
    'ignores late snapshot response from superseded route selection',
    (tester) async {
      final completer1 = Completer<ModelCacheSnapshotDto>();
      final completer2 = Completer<ModelCacheSnapshotDto>();

      fakeClient.pendingSnapshotCompleter = completer1;

      final inputSliceA = createInputSlice(
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'model-a',
      );

      final inputCubit = _TestConversationInputCubit();
      await tester.pumpWidget(
        createWidget(inputSlice: inputSliceA, inputCubit: inputCubit),
      );
      await tester.pump();
      expect(find.text('Loading...'), findsOneWidget);

      fakeClient.pendingSnapshotCompleter = completer2;
      final inputSliceB = createInputSlice(
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'model-b',
      );

      await tester.pumpWidget(
        createWidget(inputSlice: inputSliceB, inputCubit: inputCubit),
      );
      await tester.pump();

      completer1.complete(
        const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    defaultOptionId: 'low',
                    options: [
                      ThinkingControlOptionDto(id: 'low', label: 'Route A Low'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        ),
      );

      await tester.pump();

      expect(find.text('Route A Low'), findsNothing);
      expect(
        find.byKey(const Key('route_thinking_mode_loading')),
        findsOneWidget,
      );
      expect(
        inputCubit.selectCount,
        0,
        reason: 'a superseded response must never select for the newer route',
      );

      completer2.complete(
        const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-b',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    defaultOptionId: 'high',
                    options: [
                      ThinkingControlOptionDto(
                        id: 'high',
                        label: 'Route B High',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Route A Low'), findsNothing);
      expect(
        find.byKey(const Key('route_thinking_mode_selector_button')),
        findsOneWidget,
      );
      expect(
        thinkingMenuOptionIds(tester),
        contains('high'),
        reason: 'the second route resolves its own documented default option',
      );
      expect(thinkingMenuOptionIds(tester), isNot(contains('low')));
      expect(
        inputCubit.selectCount,
        0,
        reason: 'admitting a route default is never a user choice (Task 122 D2)',
      );
      expect(
        inputCubit.admitCount,
        1,
        reason: 'only the resolved current route admits its own native default',
      );
      expect(inputCubit.admittedThinkingMode, 'high');
    },
  );

  testWidgets(
    'same-route cached descriptor reuses options without loading flicker',
    (tester) async {
      fakeClient.snapshotResult = const ModelCacheSnapshotDto(
        instances: [
          ModelCacheInstanceDto(
            id: 'provider-1',
            displayName: 'P1',
            status: 'ready',
            isDefault: true,
            cacheStatus: 'fetched',
            models: [
              ModelCacheModelDto(
                id: 'model-cached',
                thinkingControl: ThinkingControlDescriptorDto(
                  status: ThinkingCapabilityStatus.supported,
                  options: [
                    ThinkingControlOptionDto(
                      id: 'medium',
                      label: 'Medium Effort',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
        recent: [],
      );

      final inputSlice1 = createInputSlice(
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'model-cached',
      );

      await tester.pumpWidget(createWidget(inputSlice: inputSlice1));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('route_thinking_mode_selector_button')),
        findsOneWidget,
      );
      expect(
        thinkingMenuOptionIds(tester),
        contains('medium'),
        reason: 'the cached descriptor for this route kept its own option',
      );

      // Now set pending completer for any background refresh
      fakeClient.pendingSnapshotCompleter = Completer<ModelCacheSnapshotDto>();

      // Re-pump widget with same route (e.g. another slice update)
      final inputSlice2 = createInputSlice(
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'model-cached',
        nextMessageThinkingMode: 'medium',
      );

      await tester.pumpWidget(createWidget(inputSlice: inputSlice2));
      await tester.pump();

      // Because Route 1 is already in _snapshot cache, it should NEVER flicker to loading
      expect(
        find.byKey(const Key('route_thinking_mode_loading')),
        findsNothing,
      );
      expect(find.text('Medium Effort'), findsOneWidget);
      expect(
        thinkingMenuOptionIds(tester),
        contains('medium'),
        reason: 'an explicit selection keeps showing its own option label',
      );
    },
  );

  testWidgets('device switch invalidates borrowed snapshot across agents', (
    tester,
  ) async {
    fakeClient.snapshotResult = const ModelCacheSnapshotDto(
      instances: [
        ModelCacheInstanceDto(
          id: 'provider-1',
          displayName: 'P1',
          status: 'ready',
          isDefault: true,
          cacheStatus: 'fetched',
          models: [
            ModelCacheModelDto(
              id: 'shared-model',
              thinkingControl: ThinkingControlDescriptorDto(
                status: ThinkingCapabilityStatus.supported,
                options: [
                  ThinkingControlOptionDto(id: 'high', label: 'Agent 1 High'),
                ],
              ),
            ),
          ],
        ),
      ],
      recent: [],
    );

    final agent1 = DeviceConfig(id: 'agent-1', name: 'Agent 1');
    final inputSlice = createInputSlice(
      nextMessageProviderId: 'provider-1',
      nextMessageModel: 'shared-model',
    );

    await tester.pumpWidget(
      createWidget(inputSlice: inputSlice, activeAgent: agent1),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('route_thinking_mode_selector_button')),
      findsOneWidget,
    );
    expect(
      thinkingMenuOptionIds(tester),
      contains('high'),
      reason: 'agent 1 resolves its own High option',
    );

    // Now prepare a pending completer for agent 2
    final completerAgent2 = Completer<ModelCacheSnapshotDto>();
    fakeClient.pendingSnapshotCompleter = completerAgent2;

    final agent2 = DeviceConfig(id: 'agent-2', name: 'Agent 2');
    await tester.pumpWidget(
      createWidget(inputSlice: inputSlice, activeAgent: agent2),
    );
    await tester.pump();

    // Snapshot from agent 1 must NOT be borrowed: it must show Loading...
    expect(find.text('Agent 1 High'), findsNothing);
    expect(
      find.byKey(const Key('route_thinking_mode_loading')),
      findsOneWidget,
    );

    // Complete agent 2 with different options
    completerAgent2.complete(
      const ModelCacheSnapshotDto(
        instances: [
          ModelCacheInstanceDto(
            id: 'provider-1',
            displayName: 'P1',
            status: 'ready',
            isDefault: true,
            cacheStatus: 'fetched',
            models: [
              ModelCacheModelDto(
                id: 'shared-model',
                thinkingControl: ThinkingControlDescriptorDto(
                  status: ThinkingCapabilityStatus.supported,
                  options: [
                    ThinkingControlOptionDto(id: 'low', label: 'Agent 2 Low'),
                  ],
                ),
              ),
            ],
          ),
        ],
        recent: [],
      ),
    );

    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('route_thinking_mode_selector_button')),
      findsOneWidget,
    );
    expect(
      thinkingMenuOptionIds(tester),
      contains('low'),
      reason: 'agent 2 resolves its own Low option',
    );
  });

  testWidgets(
    'A -> B -> A route switching reuses cached descriptors without loading flicker',
    (tester) async {
      fakeClient.snapshotResult = const ModelCacheSnapshotDto(
        instances: [
          ModelCacheInstanceDto(
            id: 'provider-1',
            displayName: 'P1',
            status: 'ready',
            isDefault: true,
            cacheStatus: 'fetched',
            models: [
              ModelCacheModelDto(
                id: 'model-a',
                thinkingControl: ThinkingControlDescriptorDto(
                  status: ThinkingCapabilityStatus.supported,
                  options: [
                    ThinkingControlOptionDto(id: 'low', label: 'Route A Low'),
                  ],
                ),
              ),
              ModelCacheModelDto(
                id: 'model-b',
                thinkingControl: ThinkingControlDescriptorDto(
                  status: ThinkingCapabilityStatus.supported,
                  options: [
                    ThinkingControlOptionDto(id: 'high', label: 'Route B High'),
                  ],
                ),
              ),
            ],
          ),
        ],
        recent: [],
      );

      final sliceA = createInputSlice(
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'model-a',
      );

      await tester.pumpWidget(createWidget(inputSlice: sliceA));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('route_thinking_mode_selector_button')),
        findsOneWidget,
      );
      expect(
        thinkingMenuOptionIds(tester),
        contains('low'),
        reason: 'route A resolves its own Low option',
      );

      final sliceB = createInputSlice(
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'model-b',
      );

      await tester.pumpWidget(createWidget(inputSlice: sliceB));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('route_thinking_mode_selector_button')),
        findsOneWidget,
      );
      expect(
        thinkingMenuOptionIds(tester),
        <String>['high'],
        reason: 'route B resolves only its own High option',
      );

      // Now switch back to Route A. With pending completer on background fetch:
      fakeClient.pendingSnapshotCompleter = Completer<ModelCacheSnapshotDto>();
      await tester.pumpWidget(createWidget(inputSlice: sliceA));
      await tester.pump();

      // No flicker to loading! Route A's own descriptor is displayed immediately
      expect(
        find.byKey(const Key('route_thinking_mode_loading')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('route_thinking_mode_selector_button')),
        findsOneWidget,
      );
      expect(thinkingMenuOptionIds(tester), contains('low'));
    },
  );

  testWidgets(
    'initial load displays Loading... while authoritative unknown displays Not reported',
    (tester) async {
      final completer = Completer<ModelCacheSnapshotDto>();
      fakeClient.pendingSnapshotCompleter = completer;

      final inputSlice = createInputSlice(
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'model-unknown',
      );

      await tester.pumpWidget(createWidget(inputSlice: inputSlice));
      await tester.pump();

      // Initial load: shows Loading...
      expect(
        find.byKey(const Key('route_thinking_mode_loading')),
        findsOneWidget,
      );
      expect(find.text('Loading...'), findsOneWidget);

      // Resolve snapshot with unknown status
      completer.complete(
        const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-unknown',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.unknown,
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        ),
      );

      await tester.pumpAndSettle();

      // Authoritative unknown: shows the unknown chip, NOT Loading...
      expect(
        find.byKey(const Key('route_thinking_mode_loading')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('route_thinking_mode_unknown')),
        findsOneWidget,
      );
      expect(find.text('Not reported'), findsOneWidget);
    },
  );

  testWidgets(
    'revalidation does not reset selection when session is superseded',
    (tester) async {
      final inputCubit = _TestConversationInputCubit();
      final session1 = Session(
        id: 'session-1',
        title: 'Session 1',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        modelProvider: 'provider-1',
        model: 'model-a',
        thinkingMode: 'high',
      );
      final sessionCubit = _TestSessionCubit(session1);

      fakeClient.snapshotResult = const ModelCacheSnapshotDto(
        instances: [
          ModelCacheInstanceDto(
            id: 'provider-1',
            displayName: 'P1',
            status: 'ready',
            isDefault: true,
            cacheStatus: 'fetched',
            models: [
              ModelCacheModelDto(
                id: 'model-a',
                thinkingControl: ThinkingControlDescriptorDto(
                  status: ThinkingCapabilityStatus.supported,
                  options: [
                    ThinkingControlOptionDto(id: 'high', label: 'High'),
                  ],
                ),
              ),
              ModelCacheModelDto(
                id: 'model-b',
                thinkingControl: ThinkingControlDescriptorDto(
                  status: ThinkingCapabilityStatus.supported,
                  options: [ThinkingControlOptionDto(id: 'low', label: 'Low')],
                ),
              ),
            ],
          ),
        ],
        recent: [],
      );

      final sliceA = createInputSlice(
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'model-a',
        nextMessageThinkingMode: 'high',
      );

      await tester.pumpWidget(
        createWidget(
          inputSlice: sliceA,
          inputCubit: inputCubit,
          sessionCubit: sessionCubit,
        ),
      );
      await tester.pumpAndSettle();

      expect(inputCubit.selectCount, 0);

      // Now prepare a pending completer for route change to model-b
      final completer = Completer<ModelCacheSnapshotDto>();
      fakeClient.pendingSnapshotCompleter = completer;

      final sliceB = createInputSlice(
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'model-b',
        nextMessageThinkingMode: 'high', // 'high' is invalid for model-b
      );

      await tester.pumpWidget(
        createWidget(
          inputSlice: sliceB,
          inputCubit: inputCubit,
          sessionCubit: sessionCubit,
        ),
      );
      await tester.pump();

      // Switch session to session-2 while fetch is in-flight
      final session2 = Session(
        id: 'session-2',
        title: 'Session 2',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        modelProvider: 'provider-1',
        model: 'model-b',
        thinkingMode: 'low',
      );
      sessionCubit.setSession(session2);

      // Complete snapshot
      completer.complete(fakeClient.snapshotResult);
      await tester.pumpAndSettle();

      // Session 2 has 'low' which is valid for model-b; its selection is not reset
      expect(inputCubit.selectedThinkingMode, isNot(equals('invalid')));
    },
  );

  testWidgets(
    'does not conflate namespaced or case-distinct model descriptors within same provider',
    (tester) async {
      fakeClient.snapshotResult = const ModelCacheSnapshotDto(
        instances: [
          ModelCacheInstanceDto(
            id: 'provider-1',
            displayName: 'Provider 1',
            status: 'ready',
            isDefault: true,
            cacheStatus: 'fetched',
            models: [
              ModelCacheModelDto(
                id: 'VendorA/model',
                thinkingControl: ThinkingControlDescriptorDto(
                  status: ThinkingCapabilityStatus.supported,
                  defaultOptionId: 'low',
                  options: [ThinkingControlOptionDto(id: 'low', label: 'Low')],
                ),
              ),
              ModelCacheModelDto(
                id: 'VendorB/model',
                thinkingControl: ThinkingControlDescriptorDto(
                  status: ThinkingCapabilityStatus.supported,
                  defaultOptionId: 'high',
                  options: [
                    ThinkingControlOptionDto(id: 'high', label: 'High'),
                  ],
                ),
              ),
            ],
          ),
        ],
        recent: [],
      );

      final sliceA = createInputSlice(
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'VendorA/model',
      );

      await tester.pumpWidget(createWidget(inputSlice: sliceA));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('route_thinking_mode_selector_button')),
        findsOneWidget,
      );
      expect(
        thinkingMenuOptionIds(tester),
        <String>['low'],
        reason: 'VendorA/model resolves only its own Low option',
      );
      expect(thinkingMenuOptionIds(tester), isNot(contains('high')));

      final sliceB = createInputSlice(
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'VendorB/model',
      );

      await tester.pumpWidget(createWidget(inputSlice: sliceB));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('route_thinking_mode_selector_button')),
        findsOneWidget,
      );
      expect(
        thinkingMenuOptionIds(tester),
        <String>['high'],
        reason: 'VendorB/model resolves only its own High option',
      );
      expect(thinkingMenuOptionIds(tester), isNot(contains('low')));
    },
  );

  group('RouteThinkingModeSelector refresh lifecycle', () {
    testWidgets(
      'updates visible menu and options on terminal model.refresh without route change or restart',
      (tester) async {
        final session = Session(
          id: 'session-1',
          title: 'Session 1',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          modelProvider: 'provider-1',
          model: 'model-a',
        );
        final sessionCubit = _TestSessionCubit(session);
        final inputCubit = _TestConversationInputCubit(
          mirrorSessionCubit: sessionCubit,
        );

        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    defaultOptionId: 'medium',
                    capabilityRevision: 'rev-1',
                    options: [
                      ThinkingControlOptionDto(id: 'low', label: 'Low'),
                      ThinkingControlOptionDto(id: 'medium', label: 'Medium'),
                      ThinkingControlOptionDto(id: 'high', label: 'High'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        final slice = createInputSlice(
          nextMessageProviderId: 'provider-1',
          nextMessageModel: 'model-a',
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: slice,
            inputCubit: inputCubit,
            sessionCubit: sessionCubit,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('route_thinking_mode_selector_button')),
          findsOneWidget,
        );
        expect(
          thinkingMenuOptionIds(tester),
          contains('medium'),
          reason: 'the declared native default is an ordinary option',
        );
        expect(
          find.byKey(const Key('chip_Medium')),
          findsOneWidget,
          reason: 'the declared native default is admitted, not annotated',
        );
        expect(inputCubit.admittedThinkingMode, 'medium');

        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    defaultOptionId: 'off',
                    capabilityRevision: 'rev-2',
                    options: [
                      ThinkingControlOptionDto(id: 'off', label: 'Off'),
                      ThinkingControlOptionDto(id: 'max', label: 'Max'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        fakeClient.modelUpdatesController.add(
          const ModelCacheUpdateEvent(
            providerInstanceId: 'provider-1',
            status: 'updated',
          ),
        );
        await tester.pumpAndSettle();

        // The previously admitted Medium is gone with rev-2, so the refresh
        // repairs only to the newly declared valid default.
        expect(inputCubit.admitCount, 2);
        expect(inputCubit.admittedThinkingMode, 'off');
        expect(find.byKey(const Key('chip_Off')), findsOneWidget);
        expect(thinkingMenuOptionIds(tester), <String>['max', 'off']);

        await tester.tap(find.byKey(const Key('route_thinking_mode_selector_button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('thinking_mode_option_off')), findsOneWidget);
        expect(find.byKey(const Key('thinking_mode_option_max')), findsOneWidget);
        expect(find.byKey(const Key('thinking_mode_option_low')), findsNothing);
        expect(
          find.byKey(const Key('thinking_mode_check_off')),
          findsOneWidget,
          reason: 'the declared native off default is the checked row',
        );
      },
    );

    testWidgets(
      'repairs a removed choice to the refreshed native default on model refresh',
      (tester) async {
        final session = Session(
          id: 'session-1',
          title: 'Session 1',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          modelProvider: 'provider-1',
          model: 'model-a',
          thinkingMode: 'low',
        );
        final sessionCubit = _TestSessionCubit(session);
        final inputCubit = _TestConversationInputCubit(
          mirrorSessionCubit: sessionCubit,
        );

        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    options: [
                      ThinkingControlOptionDto(id: 'low', label: 'Low'),
                      ThinkingControlOptionDto(id: 'high', label: 'High'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        final slice = createInputSlice(
          nextMessageProviderId: 'provider-1',
          nextMessageModel: 'model-a',
          nextMessageThinkingMode: 'low',
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: slice,
            inputCubit: inputCubit,
            sessionCubit: sessionCubit,
          ),
        );
        await tester.pumpAndSettle();

        expect(inputCubit.admitCount, 0);

        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    capabilityRevision: 'rev-2',
                    options: [
                      ThinkingControlOptionDto(id: 'fast', label: 'Fast'),
                      ThinkingControlOptionDto(id: 'deep', label: 'Deep'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        fakeClient.modelUpdatesController.add(
          const ModelCacheUpdateEvent(
            providerInstanceId: 'provider-1',
            status: 'updated',
          ),
        );
        await tester.pumpAndSettle();

        expect(inputCubit.admitCount, 1);
        expect(inputCubit.admittedThinkingMode, isNull);

        // The composer clear propagates through the real slice; rebuild with the
        // cleared value so the rendered control reflects what will be sent.
        await tester.pumpWidget(
          createWidget(
            inputSlice: createInputSlice(
              nextMessageProviderId: 'provider-1',
              nextMessageModel: 'model-a',
            ),
            inputCubit: inputCubit,
            sessionCubit: sessionCubit,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('chip_Provider default')),
          findsOneWidget,
          reason: 'a removed choice with no known default shows the selected '
              'Provider default state, never an empty selection',
        );
        expect(find.byKey(const Key('chip_Not selected')), findsNothing);
        expect(
          inputCubit.admitCount,
          1,
          reason: 'a repaired-away selection never re-dispatches',
        );
      },
    );

    testWidgets(
      'retains valid selection when still valid in refreshed descriptor',
      (tester) async {
        final session = Session(
          id: 'session-1',
          title: 'Session 1',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          modelProvider: 'provider-1',
          model: 'model-a',
          thinkingMode: 'high',
        );
        final sessionCubit = _TestSessionCubit(session);
        final inputCubit = _TestConversationInputCubit();

        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    options: [
                      ThinkingControlOptionDto(id: 'low', label: 'Low'),
                      ThinkingControlOptionDto(id: 'high', label: 'High'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        final slice = createInputSlice(
          nextMessageProviderId: 'provider-1',
          nextMessageModel: 'model-a',
          nextMessageThinkingMode: 'high',
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: slice,
            inputCubit: inputCubit,
            sessionCubit: sessionCubit,
          ),
        );
        await tester.pumpAndSettle();

        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    capabilityRevision: 'rev-2',
                    options: [
                      ThinkingControlOptionDto(id: 'low', label: 'Low'),
                      ThinkingControlOptionDto(id: 'high', label: 'High'),
                      ThinkingControlOptionDto(id: 'max', label: 'Max'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        fakeClient.modelUpdatesController.add(
          const ModelCacheUpdateEvent(
            providerInstanceId: 'provider-1',
            status: 'updated',
          ),
        );
        await tester.pumpAndSettle();

        expect(inputCubit.selectCount, 0);
      },
    );

    testWidgets(
      'failed model refresh retains prior validated authority',
      (tester) async {
        final session = Session(
          id: 'session-1',
          title: 'Session 1',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          modelProvider: 'provider-1',
          model: 'model-a',
        );
        final sessionCubit = _TestSessionCubit(session);
        final inputCubit = _TestConversationInputCubit();

        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    options: [
                      ThinkingControlOptionDto(id: 'low', label: 'Low'),
                      ThinkingControlOptionDto(id: 'high', label: 'High'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        final slice = createInputSlice(
          nextMessageProviderId: 'provider-1',
          nextMessageModel: 'model-a',
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: slice,
            inputCubit: inputCubit,
            sessionCubit: sessionCubit,
          ),
        );
        await tester.pumpAndSettle();

        final initialCallCount = fakeClient.callCount;

        fakeClient.modelUpdatesController.add(
          const ModelCacheUpdateEvent(
            providerInstanceId: 'provider-1',
            status: 'failed',
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('route_thinking_mode_selector_button')), findsOneWidget);
        expect(fakeClient.callCount, initialCallCount);
      },
    );

    testWidgets(
      'ignores superseded event for different provider or cross-device',
      (tester) async {
        final session = Session(
          id: 'session-1',
          title: 'Session 1',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          modelProvider: 'provider-1',
          model: 'model-a',
        );
        final sessionCubit = _TestSessionCubit(session);
        final inputCubit = _TestConversationInputCubit();

        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    options: [
                      ThinkingControlOptionDto(id: 'low', label: 'Low'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        final slice = createInputSlice(
          nextMessageProviderId: 'provider-1',
          nextMessageModel: 'model-a',
        );

        final activeAgent = DeviceConfig(
          id: 'agent-1',
          name: 'Agent 1',
          hardwareId: 'agent-1',
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: slice,
            inputCubit: inputCubit,
            sessionCubit: sessionCubit,
            activeAgent: activeAgent,
          ),
        );
        await tester.pumpAndSettle();

        final countAfterInit = fakeClient.callCount;

        // Different provider
        fakeClient.modelUpdatesController.add(
          const ModelCacheUpdateEvent(
            providerInstanceId: 'provider-2',
            status: 'updated',
          ),
        );
        await tester.pumpAndSettle();
        expect(fakeClient.callCount, countAfterInit);

        // Cross-device event for different agent
        fakeClient.modelUpdatesController.add(
          const ModelCacheUpdateEvent(
            providerInstanceId: 'provider-1',
            status: 'updated',
            deviceId: 'other-agent',
          ),
        );
        await tester.pumpAndSettle();
        expect(fakeClient.callCount, countAfterInit);
      },
    );

    testWidgets(
      'reflects thinking control removal in refreshed snapshot',
      (tester) async {
        final session = Session(
          id: 'session-1',
          title: 'Session 1',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          modelProvider: 'provider-1',
          model: 'model-a',
        );
        final sessionCubit = _TestSessionCubit(session);
        final inputCubit = _TestConversationInputCubit();

        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    options: [
                      ThinkingControlOptionDto(id: 'low', label: 'Low'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        final slice = createInputSlice(
          nextMessageProviderId: 'provider-1',
          nextMessageModel: 'model-a',
          nextMessageThinkingMode: 'low',
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: slice,
            inputCubit: inputCubit,
            sessionCubit: sessionCubit,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('route_thinking_mode_selector_button')), findsOneWidget);

        // Refreshed snapshot has null thinkingControl (removed)
        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: null,
                ),
              ],
            ),
          ],
          recent: [],
        );

        fakeClient.modelUpdatesController.add(
          const ModelCacheUpdateEvent(
            providerInstanceId: 'provider-1',
            status: 'updated',
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('route_thinking_mode_unknown')), findsOneWidget);
        expect(inputCubit.selectedThinkingMode, isNull);
      },
    );

    testWidgets(
      'reflects unsupported status in refreshed snapshot',
      (tester) async {
        final session = Session(
          id: 'session-1',
          title: 'Session 1',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          modelProvider: 'provider-1',
          model: 'model-a',
        );
        final sessionCubit = _TestSessionCubit(session);
        final inputCubit = _TestConversationInputCubit();

        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    options: [
                      ThinkingControlOptionDto(id: 'low', label: 'Low'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        final slice = createInputSlice(
          nextMessageProviderId: 'provider-1',
          nextMessageModel: 'model-a',
          nextMessageThinkingMode: 'low',
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: slice,
            inputCubit: inputCubit,
            sessionCubit: sessionCubit,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('route_thinking_mode_selector_button')), findsOneWidget);

        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.unsupported,
                    capabilityRevision: 'unsupported',
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        fakeClient.modelUpdatesController.add(
          const ModelCacheUpdateEvent(
            providerInstanceId: 'provider-1',
            status: 'updated',
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('route_thinking_mode_no_control')), findsOneWidget);
        expect(
          find.byKey(const Key('route_thinking_mode_hidden')),
          findsNothing,
          reason: 'a resolved no-control route stays visible and explained',
        );
        expect(
          find.byKey(const Key('route_thinking_mode_selector_button')),
          findsNothing,
          reason: 'no selectable menu may be offered for an unsupported route',
        );
        expect(inputCubit.selectedThinkingMode, isNull);
      },
    );

    testWidgets(
      'restores selectable options when restored config brings back thinking control',
      (tester) async {
        final session = Session(
          id: 'session-1',
          title: 'Session 1',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          modelProvider: 'provider-1',
          model: 'model-a',
        );
        final sessionCubit = _TestSessionCubit(session);
        final inputCubit = _TestConversationInputCubit();

        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: null,
                ),
              ],
            ),
          ],
          recent: [],
        );

        final slice = createInputSlice(
          nextMessageProviderId: 'provider-1',
          nextMessageModel: 'model-a',
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: slice,
            inputCubit: inputCubit,
            sessionCubit: sessionCubit,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('route_thinking_mode_unknown')), findsOneWidget);

        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    capabilityRevision: 'rev-restored',
                    options: [
                      ThinkingControlOptionDto(id: 'quick', label: 'Quick'),
                      ThinkingControlOptionDto(id: 'deep', label: 'Deep'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        fakeClient.modelUpdatesController.add(
          const ModelCacheUpdateEvent(
            providerInstanceId: 'provider-1',
            status: 'updated',
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('route_thinking_mode_selector_button')), findsOneWidget);

        // Select restored option
        await tester.tap(find.byKey(const Key('route_thinking_mode_selector_button')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Quick'));
        await tester.pumpAndSettle();
        expect(inputCubit.selectedThinkingMode, 'quick');
      },
    );

    testWidgets(
      'failed modelSnapshot fetch preserves prior same-device snapshot without losing authority',
      (tester) async {
        // The conversation stores its own High: an existing conversation shows
        // its stored selection, never a value carried in memory (Task 122 D3).
        final session = Session(
          id: 'session-1',
          title: 'Session 1',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          modelProvider: 'provider-1',
          model: 'model-a',
          thinkingMode: 'high',
        );
        final sessionCubit = _TestSessionCubit(session);
        final inputCubit = _TestConversationInputCubit();

        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    options: [
                      ThinkingControlOptionDto(id: 'low', label: 'Low'),
                      ThinkingControlOptionDto(id: 'high', label: 'High'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        final slice = createInputSlice(
          nextMessageProviderId: 'provider-1',
          nextMessageModel: 'model-a',
          nextMessageThinkingMode: 'high',
        );

        final agent = DeviceConfig(
          id: 'device-1',
          name: 'Device 1',
          hardwareId: 'device-1',
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: slice,
            inputCubit: inputCubit,
            sessionCubit: sessionCubit,
            activeAgent: agent,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('High'), findsOneWidget);
        expect(find.byKey(const Key('route_thinking_mode_selector_button')), findsOneWidget);

        fakeClient.shouldThrow = true;

        fakeClient.modelUpdatesController.add(
          const ModelCacheUpdateEvent(
            providerInstanceId: 'provider-1',
            status: 'updated',
            deviceId: 'device-1',
          ),
        );
        await tester.pumpAndSettle();

        // Preserves prior same-device options and selection
        expect(find.text('High'), findsOneWidget);
        expect(find.byKey(const Key('route_thinking_mode_selector_button')), findsOneWidget);
        expect(find.byKey(const Key('route_thinking_mode_fetch_failure')), findsNothing);

        // Switching to different agent does not preserve prior-device snapshot
        final agent2 = DeviceConfig(
          id: 'device-2',
          name: 'Device 2',
          hardwareId: 'device-2',
        );
        await tester.pumpWidget(
          createWidget(
            inputSlice: slice,
            inputCubit: inputCubit,
            sessionCubit: sessionCubit,
            activeAgent: agent2,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('route_thinking_mode_fetch_failure')), findsOneWidget);
      },
    );
  });

  group('RouteThinkingModeSelector real ProviderSetupClientImpl stream integration', () {
    late FakeSanadSocketService local;
    late FakeSanadSocketService cloud;
    late DeviceConnectionCoordinator coordinator;
    late _TestRealProviderSetupClient realClient;

    setUp(() async {
      local = FakeSanadSocketService()..setConnected(true);
      cloud = FakeSanadSocketService()..setConnected(true);
      coordinator = DeviceConnectionCoordinator(
        cloudSocketService: cloud,
        localSocketService: local,
        currentDeviceId: 'this-hardware',
      );
      realClient = _TestRealProviderSetupClient(
        connectionCoordinator: coordinator,
      );
      if (getIt.isRegistered<ProviderSetupClient>()) {
        await getIt.unregister<ProviderSetupClient>();
      }
      getIt.registerSingleton<ProviderSetupClient>(realClient);
    });

    tearDown(() async {
      if (getIt.isRegistered<ProviderSetupClient>()) {
        await getIt.unregister<ProviderSetupClient>();
      }
      coordinator.dispose();
      local.dispose();
      cloud.dispose();
    });

    testWidgets('an agent-less snapshot load clears the Retry of a selector on the current device (Task 124 D5)', (
      tester,
    ) async {
      final impl = ProviderSetupClientImpl(connectionCoordinator: coordinator);
      await getIt.unregister<ProviderSetupClient>();
      getIt.registerSingleton<ProviderSetupClient>(impl);
      final currentDevice = DeviceConfig(id: 'this-hardware', name: 'This device', hardwareId: 'this-hardware', isOnline: true);

      await tester.pumpWidget(
        createWidget(
          inputSlice: createInputSlice(nextMessageProviderId: 'provider-1', nextMessageModel: 'model-a'),
          activeAgent: currentDevice,
        ),
      );
      // The selector's own snapshot request goes unanswered and times out.
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('route_thinking_mode_fetch_failure')), findsOneWidget);

      // Another consumer loads the snapshot without naming a device.
      local.clearCaptured();
      final load = impl.modelSnapshot();
      await tester.pump();
      final command = local.capturedCommands.singleWhere((entry) => entry['command'] == 'model.snapshot');
      final requestId = (command['payload'] as Map)['request_id'] as String;
      local.debugEmitEvent({
        'device_id': 'this-hardware',
        'event': 'model.snapshot_result',
        'request_id': requestId,
        'payload': {
          'request_id': requestId,
          'instances': [
            {
              'id': 'provider-1',
              'display_name': 'P1',
              'status': 'ready',
              'models': [
                {
                  'id': 'model-a',
                  'thinking_control': {
                    'status': 'supported',
                    'options': [
                      {'id': 'high', 'label': 'High'},
                    ],
                  },
                },
              ],
            },
          ],
          'recent': <Object>[],
        },
      });
      await load;
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('route_thinking_mode_fetch_failure')), findsNothing);
      expect(find.byKey(const Key('route_thinking_mode_selector_button')), findsOneWidget);
    });

    testWidgets(
      'filters missing, malformed, foreign identity and unknown status while accepting allowed aliases on both transports',
      (tester) async {
        final session = Session(
          id: 'session-1',
          title: 'Session 1',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          modelProvider: 'provider-1',
          model: 'model-a',
        );
        final sessionCubit = _TestSessionCubit(session);
        final inputCubit = _TestConversationInputCubit();

        realClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    options: [
                      ThinkingControlOptionDto(id: 'low', label: 'Low'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        final activeAgent = DeviceConfig(
          id: 'local-agent',
          name: 'Local Agent',
          hardwareId: 'this-hardware',
          metadata: {'cloud_device_id': 'cloud-agent-alias'},
        );

        final slice = createInputSlice(
          nextMessageProviderId: 'provider-1',
          nextMessageModel: 'model-a',
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: slice,
            inputCubit: inputCubit,
            sessionCubit: sessionCubit,
            activeAgent: activeAgent,
          ),
        );
        await tester.pumpAndSettle();

        final initialCalls = realClient.snapshotCallCount;

        // 1. Missing identity on cloud socket -> dropped
        cloud.debugEmitEvent({
          'event': 'model.cache_updated',
          'payload': {
            'provider_instance_id': 'provider-1',
            'status': 'updated',
          },
        });
        await tester.pumpAndSettle();
        expect(realClient.snapshotCallCount, initialCalls);

        // 2. Malformed identity -> dropped
        cloud.debugEmitEvent({
          'event': 'model.cache_updated',
          'device_id': 12345,
          'payload': {
            'provider_instance_id': 'provider-1',
            'status': 'updated',
          },
        });
        await tester.pumpAndSettle();
        expect(realClient.snapshotCallCount, initialCalls);

        // 3. Wrong identity (foreign device) -> ignored
        cloud.debugEmitEvent({
          'event': 'model.cache_updated',
          'device_id': 'foreign-device',
          'payload': {
            'provider_instance_id': 'provider-1',
            'status': 'updated',
          },
        });
        await tester.pumpAndSettle();
        expect(realClient.snapshotCallCount, initialCalls);

        // 4. Unknown status -> dropped
        local.debugEmitEvent({
          'event': 'model.cache_updated',
          'hardware_id': 'this-hardware',
          'payload': {
            'provider_instance_id': 'provider-1',
            'status': 'pending_approval',
          },
        });
        await tester.pumpAndSettle();
        expect(realClient.snapshotCallCount, initialCalls);

        // 5. Allowed alias: Cloud event carrying cloudDeviceId triggers refresh
        cloud.debugEmitEvent({
          'event': 'model.cache_updated',
          'device_id': 'cloud-agent-alias',
          'payload': {
            'provider_instance_id': 'provider-1',
            'status': 'updated',
          },
        });
        await tester.pumpAndSettle();
        expect(realClient.snapshotCallCount, initialCalls + 1);

        // 6. Allowed alias: Local event carrying hardwareId triggers refresh
        local.debugEmitEvent({
          'event': 'model.cache_updated',
          'hardware_id': 'this-hardware',
          'payload': {
            'provider_instance_id': 'provider-1',
            'status': 'updated',
          },
        });
        await tester.pumpAndSettle();
        expect(realClient.snapshotCallCount, initialCalls + 2);
      },
    );
  });

  group('RouteThinkingModeSelector OpenCode Go exact V4.1 controls', () {
    // Exact agent-emitted descriptor for DeepSeek V4.1 Flash on OpenCode Go:
    // Chat `thinking.type: enabled/disabled` plus finite
    // `reasoning_effort: low/high/max`, enabled by default at default `high`
    // (https://api-docs.deepseek.com/guides/thinking_mode). `minimal`/`medium`/
    // `xhigh`/`ultra` are documented request remaps, never distinct tiers.
    const v41Descriptor = ThinkingControlDescriptorDto(
      status: ThinkingCapabilityStatus.supported,
      kind: ThinkingControlKind.effort,
      options: [
        ThinkingControlOptionDto(
          id: 'off',
          label: 'Off',
          isOff: true,
        ),
        ThinkingControlOptionDto(id: 'low', label: 'Low'),
        ThinkingControlOptionDto(
          id: 'high',
          label: 'High',
          isProviderDefault: true,
        ),
        ThinkingControlOptionDto(id: 'max', label: 'Max'),
      ],
      defaultOptionId: 'high',
      capabilityRevision: 'rev-v41',
      source: 'profile',
    );

    testWidgets(
      'shows the exact V4.1 selector with real finite tiers and grounded default',
      (tester) async {
        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'inst-v41-go',
              displayName: 'OpenCode Go',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'deepseek-v4.1-flash',
                  name: 'DeepSeek V4.1 Flash',
                  supportsReasoningOutput: true,
                  thinkingControl: v41Descriptor,
                ),
              ],
            ),
          ],
          recent: [],
        );

        final inputSlice = createInputSlice(
          nextMessageProviderId: 'inst-v41-go',
          nextMessageModel: 'deepseek-v4.1-flash',
        );

        final sessionCubit = _TestSessionCubit(
          Session(
            id: 'session-v41',
            title: 'V4.1',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            modelProvider: 'inst-v41-go',
            model: 'deepseek-v4.1-flash',
          ),
        );
        final inputCubit = _TestConversationInputCubit(
          mirrorSessionCubit: sessionCubit,
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: inputSlice,
            inputCubit: inputCubit,
            sessionCubit: sessionCubit,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('route_thinking_mode_hidden')),
          findsNothing,
          reason: 'the exact V4.1 regression must not hide the selector',
        );
        expect(
          find.byKey(const Key('route_thinking_mode_selector_button')),
          findsOneWidget,
        );
        // The grounded native default is admitted as its own ordinary tier.
        expect(
          find.byKey(const Key('chip_High')),
          findsOneWidget,
          reason: 'the grounded native default is the admitted selection',
        );
        expect(inputCubit.admittedThinkingMode, 'high');
        expect(
          thinkingMenuOptionIds(tester),
          <String>['max', 'high', 'low', 'off'],
          reason: 'the menu offers exactly the grounded finite tiers',
        );

        await tester.tap(
          find.byKey(const Key('route_thinking_mode_selector_button')),
        );
        await tester.pumpAndSettle();

        for (final optionId in ['off', 'low', 'high', 'max']) {
          expect(
            find.byKey(Key('thinking_mode_option_$optionId')),
            findsOneWidget,
            reason: '$optionId must be a visible real V4.1 tier',
          );
        }
        for (final remappedAlias in ['minimal', 'medium', 'xhigh', 'ultra']) {
          expect(
            find.byKey(Key('thinking_mode_option_$remappedAlias')),
            findsNothing,
            reason: '$remappedAlias is a request remap, not a visible tier',
          );
        }
        expect(
          find.byKey(const Key('thinking_mode_check_high')),
          findsOneWidget,
          reason: 'the grounded native default is the checked row',
        );
      },
    );

    testWidgets(
      'keeps a visible explained control for the pre-fix unsupported V4.1 descriptor',
      (tester) async {
        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'inst-v41-go',
              displayName: 'OpenCode Go',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'deepseek-v4.1-flash-x',
                  name: 'DeepSeek V4.1 Flash X',
                  supportsReasoningOutput: true,
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.unsupported,
                    capabilityRevision: 'rev-near-id',
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        final inputSlice = createInputSlice(
          nextMessageProviderId: 'inst-v41-go',
          nextMessageModel: 'deepseek-v4.1-flash-x',
        );

        await tester.pumpWidget(createWidget(inputSlice: inputSlice));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('route_thinking_mode_no_control')),
          findsOneWidget,
          reason: 'an unevidenced near-ID keeps a visible, explained control',
        );
        expect(
          find.byKey(const Key('route_thinking_mode_hidden')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('route_thinking_mode_selector_button')),
          findsNothing,
          reason: 'an unevidenced near-ID must not gain thinking controls',
        );
      },
    );
  });

  group('approved always-visible thinking control', () {
    testWidgets(
      'keeps distinct visible chips for no-control and unknown routes',
      (tester) async {
        const noControlDescriptor = ThinkingControlDescriptorDto(
          status: ThinkingCapabilityStatus.unsupported,
        );
        const unknownDescriptor = ThinkingControlDescriptorDto(
          status: ThinkingCapabilityStatus.unknown,
        );

        Future<void> pumpWith(
          ThinkingControlDescriptorDto descriptor,
          String modelId,
        ) async {
          fakeClient.snapshotResult = ModelCacheSnapshotDto(
            instances: [
              ModelCacheInstanceDto(
                id: 'provider-1',
                displayName: 'P1',
                status: 'ready',
                isDefault: true,
                cacheStatus: 'fetched',
                models: [
                  ModelCacheModelDto(id: modelId, thinkingControl: descriptor),
                ],
              ),
            ],
            recent: const [],
          );
          await tester.pumpWidget(
            createWidget(
              inputSlice: createInputSlice(
                nextMessageProviderId: 'provider-1',
                nextMessageModel: modelId,
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        await pumpWith(noControlDescriptor, 'model-a');
        expect(find.byKey(const Key('route_thinking_mode_no_control')), findsOneWidget);
        expect(find.byKey(const Key('route_thinking_mode_unknown')), findsNothing);
        expect(find.byKey(const Key('route_thinking_mode_hidden')), findsNothing);
        expect(find.byKey(const Key('chip_No control')), findsOneWidget);
        expect(
          find.byKey(const Key('route_thinking_mode_selector_button')),
          findsNothing,
        );

        await pumpWith(unknownDescriptor, 'model-b');
        expect(find.byKey(const Key('route_thinking_mode_unknown')), findsOneWidget);
        expect(find.byKey(const Key('route_thinking_mode_no_control')), findsNothing);
        expect(find.byKey(const Key('route_thinking_mode_hidden')), findsNothing);
        expect(find.byKey(const Key('chip_Not reported')), findsOneWidget);
        // Neither state may be presented as a chosen level or as "Default".
        expect(find.byKey(const Key('chip_Default')), findsNothing);
        expect(find.byKey(const Key('chip_Off')), findsNothing);
      },
    );

    testWidgets(
      'retains an explicit Off over the declared native default',
      (tester) async {
        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    kind: ThinkingControlKind.effort,
                    defaultOptionId: 'high',
                    options: [
                      ThinkingControlOptionDto(id: 'off', label: 'Off', isOff: true),
                      ThinkingControlOptionDto(
                        id: 'high',
                        label: 'High',
                        isProviderDefault: true,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        final inputCubit = _TestConversationInputCubit();
        await tester.pumpWidget(
          createWidget(
            inputSlice: createInputSlice(
              nextMessageProviderId: 'provider-1',
              nextMessageModel: 'model-a',
              nextMessageThinkingMode: 'off',
            ),
            inputCubit: inputCubit,
          ),
        );
        await tester.pumpAndSettle();

        // A valid explicit choice wins outright, including Off: resolution must
        // never overwrite it with the route's declared default.
        expect(inputCubit.selectCount, 0);
        expect(find.byKey(const Key('chip_Off')), findsOneWidget);
        expect(thinkingMenuOptionIds(tester), <String>['high', 'off']);
        await tester.tap(find.byKey(const Key('route_thinking_mode_selector_button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('thinking_mode_check_off')), findsOneWidget);

        // Choosing the declared native default dispatches exactly its own id.
        await tester.tap(find.byKey(const Key('thinking_mode_option_high')));
        await tester.pumpAndSettle();

        expect(inputCubit.selectCount, 1);
        expect(inputCubit.selectedThinkingMode, 'high');
      },
    );

    testWidgets(
      'presents the admitted native default exactly like any ordinary level',
      (tester) async {
        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    kind: ThinkingControlKind.effort,
                    defaultOptionId: 'medium',
                    options: [
                      ThinkingControlOptionDto(id: 'medium', label: 'Medium'),
                      ThinkingControlOptionDto(id: 'off', label: 'Off', isOff: true),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        Future<void> pumpWith(String? thinkingMode) async {
          await tester.pumpWidget(
            createWidget(
              inputSlice: createInputSlice(
                nextMessageProviderId: 'provider-1',
                nextMessageModel: 'model-a',
                nextMessageThinkingMode: thinkingMode,
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        // The declared native default is a real admitted level, so the chip and
        // the checked row name it exactly.
        await pumpWith('medium');
        expect(find.byKey(const Key('chip_Medium')), findsOneWidget);
        expect(find.byKey(const Key('chip_Default')), findsNothing);
        expect(find.byKey(const Key('chip_Not selected')), findsNothing);
        await tester.tap(find.byKey(const Key('route_thinking_mode_selector_button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('thinking_mode_check_medium')), findsOneWidget);

        // An explicit Off stays its own distinct admitted state.
        await pumpWith('off');
        expect(find.byKey(const Key('chip_Off')), findsOneWidget);
        expect(find.byKey(const Key('chip_Medium')), findsNothing);
      },
    );

    testWidgets(
      'annotates token-budget presets with their real token values',
      (tester) async {
        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-budget',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    kind: ThinkingControlKind.tokenBudget,
                    defaultOptionId: 'high',
                    options: [
                      ThinkingControlOptionDto(id: 'off', label: 'Off', isOff: true),
                      ThinkingControlOptionDto(
                        id: 'low',
                        label: 'Low',
                        budgetTokens: 1024,
                      ),
                      ThinkingControlOptionDto(
                        id: 'high',
                        label: 'High',
                        budgetTokens: 8192,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: createInputSlice(
              nextMessageProviderId: 'provider-1',
              nextMessageModel: 'model-budget',
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          thinkingMenuOptionIds(tester),
          <String>['high', 'low', 'off'],
          reason: 'budget presets keep their exact ids and are never expanded',
        );
        expect(
          thinkingMenuSecondaryLabel(tester, 'low'),
          '1024 tokens',
          reason: 'the preset is identified as a token budget with its real value',
        );
        expect(thinkingMenuSecondaryLabel(tester, 'high'), '8192 tokens');
        expect(
          thinkingMenuSecondaryLabel(tester, 'off'),
          isNull,
          reason: 'an Off preset carries no budget',
        );

        // A selected budget discloses its token value on the control itself.
        await tester.pumpWidget(
          createWidget(
            inputSlice: createInputSlice(
              nextMessageProviderId: 'provider-1',
              nextMessageModel: 'model-budget',
              nextMessageThinkingMode: 'low',
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('chip_Low')), findsOneWidget);
        final selector = tester.widget<PopupMenuButton<String>>(
          find.byKey(const Key('route_thinking_mode_selector_button')),
        );
        expect(selector.tooltip, contains('1024 tokens'));
      },
    );

    testWidgets(
      'keeps boolean native options labelled On and Off',
      (tester) async {
        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-toggle',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    kind: ThinkingControlKind.toggle,
                    options: [
                      ThinkingControlOptionDto(id: 'off', label: 'Off', isOff: true),
                      ThinkingControlOptionDto(
                        id: 'low',
                        label: 'On',
                        isProviderDefault: true,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: createInputSlice(
              nextMessageProviderId: 'provider-1',
              nextMessageModel: 'model-toggle',
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          thinkingMenuOptionIds(tester),
          <String>['low', 'off'],
        );
        await tester.tap(find.byKey(const Key('route_thinking_mode_selector_button')));
        await tester.pumpAndSettle();
        // The closed chip also names the admitted native default (On).
        expect(
          find.descendant(
            of: find.byKey(const Key('thinking_mode_option_low')),
            matching: find.text('On'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('thinking_mode_option_off')),
            matching: find.text('Off'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('thinking_mode_option_medium')),
          findsNothing,
          reason: 'a boolean contract must not gain effort tiers',
        );
      },
    );

    testWidgets(
      'preserves an explicit selection while thinking evidence is unknown',
      (tester) async {
        final session = Session(
          id: 'session-1',
          title: 'Session 1',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          modelProvider: 'provider-1',
          model: 'model-a',
        );
        final sessionCubit = _TestSessionCubit(session);
        final inputCubit = _TestConversationInputCubit();

        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-a',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.unknown,
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: createInputSlice(
              nextMessageProviderId: 'provider-1',
              nextMessageModel: 'model-a',
              nextMessageThinkingMode: 'high',
            ),
            inputCubit: inputCubit,
            sessionCubit: sessionCubit,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('chip_Not reported')), findsOneWidget);
        expect(
          inputCubit.selectCount,
          0,
          reason: 'unknown evidence must not rewrite the explicit selection',
        );
        expect(inputCubit.selectedThinkingMode, isNull);
      },
    );
  });

  group('bounded independent-review repairs', () {
    testWidgets(
      'keeps a disabled unavailable control when the route carries no thinking transport',
      (tester) async {
        const capabilities = Capability(supportsThinkingModeChange: false);

        await tester.pumpWidget(
          createWidget(
            inputSlice: createInputSlice(),
            capabilities: capabilities,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('route_thinking_mode_hidden')),
          findsNothing,
          reason: 'a route without thinking transport keeps a visible control',
        );
        expect(
          find.byKey(const Key('route_thinking_mode_unavailable')),
          findsOneWidget,
        );
        expect(find.text('Unavailable'), findsOneWidget);
        expect(
          find.byKey(const Key('route_thinking_mode_selector_button')),
          findsNothing,
          reason: 'no menu may be offered when thinking transport is absent',
        );
      },
    );

    testWidgets(
      'keeps a disabled unavailable control when the legacy device list is empty',
      (tester) async {
        const capabilities = Capability(
          supportsThinkingModeChange: true,
          thinkingModesList: [],
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: createInputSlice(),
            capabilities: capabilities,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('route_thinking_mode_hidden')),
          findsNothing,
          reason: 'an empty legacy list is an unavailable transport, not absence',
        );
        expect(
          find.byKey(const Key('route_thinking_mode_unavailable')),
          findsOneWidget,
        );
        expect(find.text('Unavailable'), findsOneWidget);
        expect(
          find.byKey(const Key('route_thinking_mode_selector_button')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'keeps the legacy device list selectable when modes are declared',
      (tester) async {
        const capabilities = Capability(
          supportsThinkingModeChange: true,
          thinkingModesList: ['quick', 'balanced', 'deep'],
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: createInputSlice(),
            capabilities: capabilities,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('route_thinking_mode_selector_button')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('route_thinking_mode_unavailable')), findsNothing);
        expect(find.text('balanced'), findsOneWidget);
        expect(thinkingMenuOptionIds(tester), ['deep', 'balanced', 'quick']);
      },
    );

    testWidgets(
      'identifies an undeclared token-budget preset as a budget without inventing a value',
      (tester) async {
        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-budget',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    kind: ThinkingControlKind.tokenBudget,
                    options: [
                      ThinkingControlOptionDto(
                        id: 'off',
                        label: 'Off',
                        isOff: true,
                      ),
                      ThinkingControlOptionDto(
                        id: 'low',
                        label: 'Low',
                        budgetTokens: 1024,
                      ),
                      ThinkingControlOptionDto(id: 'high', label: 'High'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: createInputSlice(
              nextMessageProviderId: 'provider-1',
              nextMessageModel: 'model-budget',
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          thinkingMenuSecondaryLabel(tester, 'high'),
          'Token budget',
          reason: 'a budget preset stays identifiable as a budget without a declared token count',
        );
        expect(thinkingMenuSecondaryLabel(tester, 'low'), '1024 tokens');
        expect(
          thinkingMenuSecondaryLabel(tester, 'off'),
          isNull,
          reason: 'an Off preset carries no budget',
        );
      },
    );

    testWidgets(
      'does not invent a token count for a truncated fractional budget',
      (tester) async {
        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-fractional',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    kind: ThinkingControlKind.effort,
                    options: [
                      ThinkingControlOptionDto(id: 'high', label: 'High'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: createInputSlice(
              nextMessageProviderId: 'provider-1',
              nextMessageModel: 'model-fractional',
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          thinkingMenuSecondaryLabel(tester, 'high'),
          isNull,
          reason: 'fractional budget metadata is absent evidence, not 1024',
        );
      },
    );

    testWidgets(
      'dispatches a declared option whose exact id was the omission sentinel',
      (tester) async {
        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-sentinel',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    kind: ThinkingControlKind.effort,
                    options: [
                      ThinkingControlOptionDto(
                        id: '__provider_default__',
                        label: 'Native Sentinel',
                      ),
                      ThinkingControlOptionDto(id: 'high', label: 'High'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        final inputCubit = _TestConversationInputCubit();
        await tester.pumpWidget(
          createWidget(
            inputSlice: createInputSlice(
              nextMessageProviderId: 'provider-1',
              nextMessageModel: 'model-sentinel',
            ),
            inputCubit: inputCubit,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('route_thinking_mode_selector_button')),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Native Sentinel'));
        await tester.pumpAndSettle();

        expect(
          inputCubit.selectedThinkingMode,
          '__provider_default__',
          reason: 'a declared native option id must dispatch itself, never omission',
        );
      },
    );

    testWidgets(
      'dispatches each declared id exactly, including reserved-looking ids',
      (tester) async {
        fakeClient.snapshotResult = const ModelCacheSnapshotDto(
          instances: [
            ModelCacheInstanceDto(
              id: 'provider-1',
              displayName: 'P1',
              status: 'ready',
              isDefault: true,
              cacheStatus: 'fetched',
              models: [
                ModelCacheModelDto(
                  id: 'model-sentinel',
                  thinkingControl: ThinkingControlDescriptorDto(
                    status: ThinkingCapabilityStatus.supported,
                    kind: ThinkingControlKind.effort,
                    options: [
                      ThinkingControlOptionDto(
                        id: '__provider_default__',
                        label: 'Native Sentinel',
                      ),
                      ThinkingControlOptionDto(
                        id: 'provider_default',
                        label: 'Declared Key Twin',
                      ),
                      ThinkingControlOptionDto(id: 'high', label: 'High'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          recent: [],
        );

        final inputCubit = _TestConversationInputCubit();
        await tester.pumpWidget(
          createWidget(
            inputSlice: createInputSlice(
              nextMessageProviderId: 'provider-1',
              nextMessageModel: 'model-sentinel',
              nextMessageThinkingMode: 'high',
            ),
            inputCubit: inputCubit,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('route_thinking_mode_selector_button')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('thinking_mode_option___provider_default__')),
          findsOneWidget,
          reason: 'the declared option keeps its exact id as its own distinct entry',
        );
        expect(
          find.byKey(const Key('thinking_mode_option_provider_default')),
          findsOneWidget,
          reason: 'a declared id close to a reserved-looking family keeps its own entry',
        );
        expect(
          find.byKey(const Key('thinking_mode_option_high')),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const Key('thinking_mode_option_provider_default')),
        );
        await tester.pumpAndSettle();

        expect(inputCubit.selectCount, 1);
        expect(
          inputCubit.selectedThinkingMode,
          'provider_default',
          reason: 'a declared option always dispatches its own exact id',
        );

        // The reserved-looking declared id dispatches itself as well.
        await tester.tap(
          find.byKey(const Key('route_thinking_mode_selector_button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('thinking_mode_option___provider_default__')),
        );
        await tester.pumpAndSettle();

        expect(inputCubit.selectCount, 2);
        expect(inputCubit.selectedThinkingMode, '__provider_default__');
      },
    );
  });

  group('budget row annotation', () {
    Future<void> pumpBudgetModel(
      WidgetTester tester, {
      required String? defaultOptionId,
      required List<ThinkingControlOptionDto> options,
      String modelId = 'model-budget-default',
      ThinkingControlKind kind = ThinkingControlKind.tokenBudget,
    }) async {
      fakeClient.snapshotResult = ModelCacheSnapshotDto(
        instances: [
          ModelCacheInstanceDto(
            id: 'provider-1',
            displayName: 'P1',
            status: 'ready',
            isDefault: true,
            cacheStatus: 'fetched',
            models: [
              ModelCacheModelDto(
                id: modelId,
                thinkingControl: ThinkingControlDescriptorDto(
                  status: ThinkingCapabilityStatus.supported,
                  kind: kind,
                  defaultOptionId: defaultOptionId,
                  options: options,
                ),
              ),
            ],
          ),
        ],
        recent: const [],
      );
      await tester.pumpWidget(
        createWidget(
          inputSlice: createInputSlice(
            nextMessageProviderId: 'provider-1',
            nextMessageModel: modelId,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'discloses the declared budget of a budget preset row',
      (tester) async {
        await pumpBudgetModel(
          tester,
          defaultOptionId: 'low',
          options: const [
            ThinkingControlOptionDto(id: 'off', label: 'Off', isOff: true),
            ThinkingControlOptionDto(
              id: 'low',
              label: 'Low',
              budgetTokens: 1024,
            ),
            ThinkingControlOptionDto(id: 'high', label: 'High'),
          ],
        );

        expect(
          thinkingMenuSecondaryLabel(tester, 'low'),
          '1024 tokens',
          reason: 'the budget row keeps its declared count',
        );
        expect(
          thinkingMenuSecondaryLabel(tester, 'off'),
          isNull,
          reason: 'an Off preset carries no budget',
        );
        expect(
          thinkingMenuSecondaryLabel(tester, 'high'),
          'Token budget',
          reason: 'an amount-unknown budget preset stays labelled as a budget',
        );
      },
    );

    testWidgets(
      'identifies an amount-unknown budget preset as a budget',
      (tester) async {
        await pumpBudgetModel(
          tester,
          defaultOptionId: 'high',
          options: const [
            ThinkingControlOptionDto(id: 'off', label: 'Off', isOff: true),
            ThinkingControlOptionDto(id: 'high', label: 'High'),
          ],
        );

        expect(
          thinkingMenuSecondaryLabel(tester, 'high'),
          'Token budget',
          reason: 'the row identifies the preset as a budget without inventing a count',
        );
      },
    );

    testWidgets(
      'keeps declared budget annotations attached to their own rows only',
      (tester) async {
        await pumpBudgetModel(
          tester,
          defaultOptionId: null,
          kind: ThinkingControlKind.effort,
          options: const [
            ThinkingControlOptionDto(id: 'low', label: 'Low', budgetTokens: 1024),
            ThinkingControlOptionDto(
              id: 'high',
              label: 'High',
              isProviderDefault: true,
            ),
          ],
          modelId: 'model-effort-default',
        );

        expect(
          thinkingMenuSecondaryLabel(tester, 'high'),
          'Provider default',
          reason: 'the effort default carries the menu-only hint and no budget wording',
        );
        expect(
          find.byKey(const Key('thinking_mode_secondary_high')),
          findsNothing,
          reason: 'an ordinary effort default gains no budget annotation',
        );
        expect(
          thinkingMenuSecondaryLabel(tester, 'low'),
          '1024 tokens',
          reason: 'a declared budget annotation stays on its own row',
        );
      },
    );
  });

  group('localized thinking-control copy', () {
    const arabic = Locale('ar');

    Future<void> pumpForModel(
      WidgetTester tester,
      ThinkingControlDescriptorDto descriptor,
      String modelId, {
      Locale? locale = arabic,
    }) async {
      fakeClient.snapshotResult = ModelCacheSnapshotDto(
        instances: [
          ModelCacheInstanceDto(
            id: 'provider-1',
            displayName: 'P1',
            status: 'ready',
            isDefault: true,
            cacheStatus: 'fetched',
            models: [
              ModelCacheModelDto(id: modelId, thinkingControl: descriptor),
            ],
          ),
        ],
        recent: const [],
      );
      await tester.pumpWidget(
        createWidget(
          inputSlice: createInputSlice(
            nextMessageProviderId: 'provider-1',
            nextMessageModel: modelId,
          ),
          locale: locale,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('localizes the no-control label and explanation', (
      tester,
    ) async {
      await pumpForModel(
        tester,
        const ThinkingControlDescriptorDto(
          status: ThinkingCapabilityStatus.unsupported,
        ),
        'model-no-control',
      );

      expect(
        find.byKey(const Key('route_thinking_mode_no_control')),
        findsOneWidget,
      );
      expect(find.text('لا يوجد تحكم'), findsOneWidget);
      expect(
        find.text('No control'),
        findsNothing,
        reason: 'the localized surface must not fall back to an English literal',
      );
      expect(
        thinkingStateTooltip(tester, 'route_thinking_mode_no_control'),
        'لا يوجد مستوى تفكير قابل للاختيار لهذا النموذج.',
      );
      expect(
        find.byKey(const Key('route_thinking_mode_selector_button')),
        findsNothing,
      );
    });

    testWidgets('localizes the not-reported label and explanation', (
      tester,
    ) async {
      await pumpForModel(
        tester,
        const ThinkingControlDescriptorDto(
          status: ThinkingCapabilityStatus.unknown,
        ),
        'model-unknown',
      );

      expect(
        find.byKey(const Key('route_thinking_mode_unknown')),
        findsOneWidget,
      );
      expect(find.text('غير مُبلَّغ عنه'), findsOneWidget);
      expect(find.text('Not reported'), findsNothing);
      expect(
        thinkingStateTooltip(tester, 'route_thinking_mode_unknown'),
        'لم يتم الإبلاغ عن خيارات التفكير لهذا النموذج.',
      );
      expect(find.byKey(const Key('chip_Not selected')), findsNothing);
    });

    testWidgets('localizes the Provider default chip and the declared option rows', (
      tester,
    ) async {
      await pumpForModel(
        tester,
        const ThinkingControlDescriptorDto(
          status: ThinkingCapabilityStatus.supported,
          kind: ThinkingControlKind.effort,
          options: [
            ThinkingControlOptionDto(id: 'low', label: 'Low'),
            ThinkingControlOptionDto(id: 'high', label: 'High'),
          ],
        ),
        'model-no-default',
      );

      // No valid explicit choice and no declared native default: the chip
      // shows the localized selected Provider default state, never an empty
      // selection.
      expect(
        find.byKey(const Key('chip_الافتراضي لدى المزوّد')),
        findsOneWidget,
        reason: 'the Provider default chip is localized copy, never an English literal',
      );
      expect(find.text('Not selected'), findsNothing);
      expect(find.text('غير محدد'), findsNothing);

      await tester.tap(
        find.byKey(const Key('route_thinking_mode_selector_button')),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const Key('thinking_mode_title_low'))).data,
        'Low',
        reason: 'declared native option labels stay descriptor-owned',
      );
      expect(
        find.byKey(const Key('thinking_mode_option_low')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('thinking_mode_check_placeholder')),
        findsWidgets,
        reason: 'no row is checked while nothing is admitted',
      );
    });

    testWidgets('localizes the unavailable explanation', (tester) async {
      await tester.pumpWidget(
        createWidget(
          inputSlice: createInputSlice(),
          capabilities: const Capability(supportsThinkingModeChange: false),
          locale: arabic,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('غير متاح'), findsOneWidget);
      expect(
        thinkingStateTooltip(tester, 'route_thinking_mode_unavailable'),
        'اختيار نمط التفكير غير متاح لهذا الجهاز.',
      );
    });

    testWidgets('localizes the menu-only provider-default hint', (tester) async {
      await pumpForModel(
        tester,
        const ThinkingControlDescriptorDto(
          status: ThinkingCapabilityStatus.supported,
          kind: ThinkingControlKind.effort,
          defaultOptionId: 'medium',
          options: [
            ThinkingControlOptionDto(id: 'low', label: 'Low'),
            ThinkingControlOptionDto(id: 'medium', label: 'Medium'),
            ThinkingControlOptionDto(id: 'high', label: 'High'),
          ],
        ),
        'model-default-hint',
      );

      expect(
        find.text('الافتراضي لدى المزوّد'),
        findsNothing,
        reason: 'the hint belongs to the expanded menu, not the closed chip',
      );

      await tester.tap(
        find.byKey(const Key('route_thinking_mode_selector_button')),
      );
      await tester.pumpAndSettle();

      expect(find.text('الافتراضي لدى المزوّد'), findsOneWidget);
      expect(
        find.text('Provider default'),
        findsNothing,
        reason: 'the localized menu must not fall back to an English literal',
      );
    });

    testWidgets('localizes the loading label', (tester) async {
      fakeClient.pendingSnapshotCompleter = Completer<ModelCacheSnapshotDto>();

      await tester.pumpWidget(
        createWidget(
          inputSlice: createInputSlice(
            nextMessageProviderId: 'provider-1',
            nextMessageModel: 'model-a',
          ),
          locale: arabic,
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const Key('route_thinking_mode_loading')),
        findsOneWidget,
      );
      expect(find.text('جارٍ التحميل...'), findsOneWidget);
      expect(
        find.text('Loading...'),
        findsNothing,
        reason: 'the localized surface must not fall back to an English literal',
      );

      fakeClient.pendingSnapshotCompleter!.complete(
        const ModelCacheSnapshotDto(instances: [], recent: []),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('route_thinking_mode_loading')), findsNothing);
    });

    testWidgets('localizes the retry label and its retry explanation', (
      tester,
    ) async {
      fakeClient.shouldThrow = true;

      await tester.pumpWidget(
        createWidget(
          inputSlice: createInputSlice(
            nextMessageProviderId: 'provider-1',
            nextMessageModel: 'model-a',
          ),
          locale: arabic,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('route_thinking_mode_fetch_failure')),
        findsOneWidget,
      );
      expect(find.text('إعادة المحاولة'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(
        thinkingStateTooltip(tester, 'route_thinking_mode_fetch_failure'),
        'تعذّر تحميل خيارات التفكير. انقر لإعادة المحاولة.',
      );

      fakeClient.shouldThrow = false;
      fakeClient.snapshotResult = const ModelCacheSnapshotDto(
        instances: [
          ModelCacheInstanceDto(
            id: 'provider-1',
            displayName: 'P1',
            status: 'ready',
            isDefault: true,
            cacheStatus: 'fetched',
            models: [
              ModelCacheModelDto(
                id: 'model-a',
                thinkingControl: ThinkingControlDescriptorDto(
                  status: ThinkingCapabilityStatus.supported,
                  options: [ThinkingControlOptionDto(id: 'high', label: 'High')],
                ),
              ),
            ],
          ),
        ],
        recent: [],
      );

      await tester.tap(find.byKey(const Key('route_thinking_mode_fetch_failure')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('route_thinking_mode_fetch_failure')),
        findsNothing,
        reason: 'the localized retry affordance still performs the real refresh',
      );
    });

    testWidgets('localizes the select-mode tooltip', (tester) async {
      await pumpForModel(
        tester,
        const ThinkingControlDescriptorDto(
          status: ThinkingCapabilityStatus.supported,
          kind: ThinkingControlKind.effort,
          options: [
            ThinkingControlOptionDto(id: 'low', label: 'Low'),
            ThinkingControlOptionDto(id: 'high', label: 'High'),
          ],
        ),
        'model-no-default',
      );

      expect(
        tester
            .widget<PopupMenuButton<String>>(
              find.byKey(const Key('route_thinking_mode_selector_button')),
            )
            .tooltip,
        'اختر نمط التفكير',
      );
    });
  });

  group('77K native thinking default auto-selection', () {
    const supportedOptions = [
      ThinkingControlOptionDto(id: 'low', label: 'Low'),
      ThinkingControlOptionDto(id: 'medium', label: 'Medium'),
      ThinkingControlOptionDto(id: 'high', label: 'High'),
    ];

    ModelCacheSnapshotDto snapshotFor(
      String modelId,
      ThinkingControlDescriptorDto descriptor,
    ) {
      return ModelCacheSnapshotDto(
        instances: [
          ModelCacheInstanceDto(
            id: 'provider-1',
            displayName: 'P1',
            status: 'ready',
            isDefault: true,
            cacheStatus: 'fetched',
            models: [
              ModelCacheModelDto(id: modelId, thinkingControl: descriptor),
            ],
          ),
        ],
        recent: const [],
      );
    }

    testWidgets(
      'admits the declared native default for display without writing it, stable across rebuilds',
      (tester) async {
        fakeClient.snapshotResult = snapshotFor(
          'model-a',
          const ThinkingControlDescriptorDto(
            status: ThinkingCapabilityStatus.supported,
            kind: ThinkingControlKind.effort,
            defaultOptionId: 'medium',
            options: supportedOptions,
          ),
        );

        final sessionCubit = _TestSessionCubit(
          Session(
            id: 'session-1',
            title: 'Session 1',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            modelProvider: 'provider-1',
            model: 'model-a',
          ),
        );
        final inputCubit = _TestConversationInputCubit(
          mirrorSessionCubit: sessionCubit,
        );
        final slice = createInputSlice(
          nextMessageProviderId: 'provider-1',
          nextMessageModel: 'model-a',
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: slice,
            inputCubit: inputCubit,
            sessionCubit: sessionCubit,
          ),
        );
        await tester.pumpAndSettle();

        expect(inputCubit.admitCount, 1);
        expect(inputCubit.admittedThinkingMode, 'medium');
        expect(inputCubit.selectCount, 0, reason: 'admission never writes (G2)');
        expect(sessionCubit.thinkingWrites, isEmpty);
        expect(find.byKey(const Key('chip_Medium')), findsOneWidget);

        // Rebuilding the same route never re-admits an already admitted value.
        await tester.pumpWidget(
          createWidget(
            inputSlice: createInputSlice(
              nextMessageProviderId: 'provider-1',
              nextMessageModel: 'model-a',
              nextMessageThinkingMode: inputCubit.admittedThinkingMode,
            ),
            inputCubit: inputCubit,
            sessionCubit: sessionCubit,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          inputCubit.admitCount,
          1,
          reason: 'resolution must never loop through the composer state',
        );
        expect(find.byKey(const Key('chip_Medium')), findsOneWidget);
      },
    );

    testWidgets(
      'shows the selected Provider default when the declared default is unknown',
      (tester) async {
        fakeClient.snapshotResult = snapshotFor(
          'model-ghost',
          const ThinkingControlDescriptorDto(
            status: ThinkingCapabilityStatus.supported,
            kind: ThinkingControlKind.effort,
            defaultOptionId: 'ultra',
            options: supportedOptions,
          ),
        );

        final inputCubit = _TestConversationInputCubit();
        await tester.pumpWidget(
          createWidget(
            inputSlice: createInputSlice(
              nextMessageProviderId: 'provider-1',
              nextMessageModel: 'model-ghost',
            ),
            inputCubit: inputCubit,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          inputCubit.admitCount,
          0,
          reason: 'an unknown native default must never be guessed',
        );
        expect(find.byKey(const Key('chip_Provider default')), findsOneWidget);
        expect(find.byKey(const Key('chip_Not selected')), findsNothing);
        expect(find.byKey(const Key('chip_Low')), findsNothing);
        expect(find.byKey(const Key('chip_Off')), findsNothing);
        expect(find.byKey(const Key('chip_Default')), findsNothing);

        await tester.tap(
          find.byKey(const Key('route_thinking_mode_selector_button')),
        );
        await tester.pumpAndSettle();

        expect(
          thinkingMenuOptionIds(tester),
          <String>['high', 'medium', 'low'],
        );
        expect(
          find.byKey(const Key('thinking_mode_check_placeholder')),
          findsNWidgets(3),
          reason: 'the menu stays open and unselected until the user chooses',
        );
        expect(find.text('Default'), findsNothing);
        expect(
          find.byKey(const Key('thinking_mode_omission_entry')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'admits each conversation own route default on a same-route switch',
      (tester) async {
        fakeClient.snapshotResult = snapshotFor(
          'model-a',
          const ThinkingControlDescriptorDto(
            status: ThinkingCapabilityStatus.supported,
            kind: ThinkingControlKind.effort,
            defaultOptionId: 'medium',
            options: [
              ThinkingControlOptionDto(id: 'off', label: 'Off', isOff: true),
              ThinkingControlOptionDto(id: 'low', label: 'Low'),
              ThinkingControlOptionDto(id: 'medium', label: 'Medium'),
              ThinkingControlOptionDto(id: 'high', label: 'High'),
            ],
          ),
        );

        final sessionA = Session(
          id: 'session-a',
          title: 'Session A',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          modelProvider: 'provider-1',
          model: 'model-a',
          thinkingMode: 'off',
        );
        final sessionB = Session(
          id: 'session-b',
          title: 'Session B',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          modelProvider: 'provider-1',
          model: 'model-a',
        );
        final sessionCubit = _TestSessionCubit(sessionA);
        final inputCubit = _TestConversationInputCubit(
          mirrorSessionCubit: sessionCubit,
        );
        inputCubit.setActiveSession('session-a');

        await tester.pumpWidget(
          createWidget(
            inputSlice: createInputSlice(
              nextMessageProviderId: 'provider-1',
              nextMessageModel: 'model-a',
            ),
            inputCubit: inputCubit,
            sessionCubit: sessionCubit,
          ),
        );
        await tester.pumpAndSettle();

        // Conversation A keeps its own explicit Off even though the route
        // declares Medium.
        expect(inputCubit.admitCount, 0);
        expect(find.byKey(const Key('chip_Off')), findsOneWidget);

        // Same-route switch: B has no stored choice, so B admits the route's own
        // declared native default instead of inheriting A's Off.
        sessionCubit.setSession(sessionB);
        await tester.pumpAndSettle();
        inputCubit.setActiveSession('session-b');
        await tester.pumpAndSettle();

        expect(
          inputCubit.admitCount,
          1,
          reason: 'an unset conversation admits its own route native default',
        );
        expect(inputCubit.admittedThinkingMode, 'medium');
        expect(inputCubit.admissions, [
          (ownerId: 'session-b', thinkingMode: 'medium'),
        ], reason: 'only the current conversation may own the admission');
        expect(
          sessionCubit.thinkingWrites,
          isEmpty,
          reason: 'opening a conversation never writes its preference (G2)',
        );
        expect(inputCubit.selectCount, 0);
        expect(find.byKey(const Key('chip_Medium')), findsOneWidget);

        // Switching back restores A's own explicit Off without a new write.
        sessionCubit.setSession(sessionA);
        await tester.pumpAndSettle();
        inputCubit.setActiveSession('session-a');
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('chip_Off')), findsOneWidget);
        expect(
          inputCubit.admitCount,
          1,
          reason: "A's valid explicit Off is never overwritten",
        );
      },
    );

    testWidgets(
      'never writes with a stale conversation owner while a snapshot is in flight',
      (tester) async {
        final completer = Completer<ModelCacheSnapshotDto>();
        fakeClient.pendingSnapshotCompleter = completer;

        final sessionA = Session(
          id: 'session-a',
          title: 'Session A',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          modelProvider: 'provider-1',
          model: 'model-a',
          thinkingMode: 'off',
        );
        final sessionB = Session(
          id: 'session-b',
          title: 'Session B',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          modelProvider: 'provider-1',
          model: 'model-a',
        );
        final sessionCubit = _TestSessionCubit(sessionA);
        final inputCubit = _TestConversationInputCubit(
          mirrorSessionCubit: sessionCubit,
        );
        inputCubit.setActiveSession('session-a');

        await tester.pumpWidget(
          createWidget(
            inputSlice: createInputSlice(
              nextMessageProviderId: 'provider-1',
              nextMessageModel: 'model-a',
            ),
            inputCubit: inputCubit,
            sessionCubit: sessionCubit,
          ),
        );
        await tester.pump();
        expect(find.text('Loading...'), findsOneWidget);

        // The conversation changes while the snapshot is still in flight, but
        // the composer has not adopted the new owner yet.
        sessionCubit.setSession(sessionB);
        await tester.pump();

        completer.complete(
          snapshotFor(
            'model-a',
            const ThinkingControlDescriptorDto(
              status: ThinkingCapabilityStatus.supported,
              kind: ThinkingControlKind.effort,
              defaultOptionId: 'medium',
              options: [
                ThinkingControlOptionDto(id: 'off', label: 'Off', isOff: true),
                ThinkingControlOptionDto(id: 'low', label: 'Low'),
                ThinkingControlOptionDto(id: 'medium', label: 'Medium'),
                ThinkingControlOptionDto(id: 'high', label: 'High'),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          inputCubit.admitCount,
          0,
          reason: 'a stale owner must never receive another conversation value',
        );
        expect(sessionCubit.thinkingWrites, isEmpty);

        // Once the composer owns the new conversation, its own default lands
        // exactly once, against that owner.
        inputCubit.setActiveSession('session-b');
        await tester.pumpAndSettle();

        expect(inputCubit.admitCount, 1);
        expect(inputCubit.admittedThinkingMode, 'medium');
        expect(inputCubit.admissions, [
          (ownerId: 'session-b', thinkingMode: 'medium'),
        ]);
        expect(sessionCubit.thinkingWrites, isEmpty);
        expect(inputCubit.selectCount, 0);
      },
    );

    testWidgets(
      'Task 122 D3 (live case 4c): a NULL session shows its route default, never a carried High',
      (tester) async {
        fakeClient.snapshotResult = snapshotFor(
          'glm-5.2',
          const ThinkingControlDescriptorDto(
            status: ThinkingCapabilityStatus.supported,
            kind: ThinkingControlKind.effort,
            defaultOptionId: 'max',
            options: [
              ThinkingControlOptionDto(id: 'high', label: 'High'),
              ThinkingControlOptionDto(id: 'max', label: 'Max'),
            ],
          ),
        );
        final sessionCubit = _TestSessionCubit(
          Session(
            id: 'session-null',
            title: 'NULL',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            modelProvider: 'provider-1',
            model: 'glm-5.2',
          ),
        );
        final inputCubit = _TestConversationInputCubit(mirrorSessionCubit: sessionCubit);
        inputCubit.setActiveSession('session-null');

        await tester.pumpWidget(
          createWidget(
            // The composer still carries a High that glm-5.2 also offers.
            inputSlice: createInputSlice(
              nextMessageProviderId: 'provider-1',
              nextMessageModel: 'glm-5.2',
              nextMessageThinkingMode: 'high',
            ),
            inputCubit: inputCubit,
            sessionCubit: sessionCubit,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('chip_Max')), findsOneWidget);
        expect(find.byKey(const Key('chip_High')), findsNothing);
        expect(inputCubit.admittedThinkingMode, 'max', reason: 'the next send carries the shown default');
        expect(inputCubit.selectCount, 0);
        expect(sessionCubit.thinkingWrites, isEmpty);
      },
    );

    testWidgets(
      'glm-5.2 on OpenCode Go never renders an empty selection (user rule 2026-10-21)',
      (tester) async {
        const goOptions = [
          ThinkingControlOptionDto(id: 'high', label: 'High'),
          ThinkingControlOptionDto(id: 'max', label: 'Max'),
        ];
        Future<(_TestConversationInputCubit, _TestSessionCubit)> openStoredNull(
          ThinkingControlDescriptorDto descriptor,
        ) async {
          fakeClient.snapshotResult = snapshotFor('glm-5.2', descriptor);
          // A fresh mount per scenario: the previous control is disposed.
          await tester.pumpWidget(const SizedBox());
          final sessionCubit = _TestSessionCubit(
            Session(
              id: 'session-glm',
              title: 'GLM',
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
              modelProvider: 'provider-1',
              model: 'glm-5.2',
            ),
          );
          final inputCubit = _TestConversationInputCubit(
            mirrorSessionCubit: sessionCubit,
          );
          await tester.pumpWidget(
            createWidget(
              inputSlice: createInputSlice(
                nextMessageProviderId: 'provider-1',
                nextMessageModel: 'glm-5.2',
              ),
              inputCubit: inputCubit,
              sessionCubit: sessionCubit,
            ),
          );
          await tester.pumpAndSettle();
          return (inputCubit, sessionCubit);
        }

        // The agent filled the shipped `max` as the default: it is shown and
        // carried by the next send without any preference write.
        final (filledCubit, filledSession) = await openStoredNull(
          const ThinkingControlDescriptorDto(
            status: ThinkingCapabilityStatus.supported,
            kind: ThinkingControlKind.effort,
            defaultOptionId: 'max',
            options: [
              ThinkingControlOptionDto(id: 'high', label: 'High'),
              ThinkingControlOptionDto(id: 'max', label: 'Max', isProviderDefault: true),
            ],
          ),
        );
        expect(find.byKey(const Key('chip_Max')), findsOneWidget);
        expect(filledCubit.admissions.map((a) => a.thinkingMode), ['max']);
        expect(filledCubit.selectCount, 0);
        expect(filledSession.thinkingWrites, isEmpty);

        // No layer declares a valid default: the selected state is Provider
        // default (no thinking field), never "Not selected".
        final (noDefaultCubit, noDefaultSession) = await openStoredNull(
          const ThinkingControlDescriptorDto(
            status: ThinkingCapabilityStatus.supported,
            kind: ThinkingControlKind.effort,
            options: goOptions,
          ),
        );
        expect(find.byKey(const Key('chip_Provider default')), findsOneWidget);
        expect(find.byKey(const Key('chip_Not selected')), findsNothing);
        expect(find.text('Not selected'), findsNothing);
        expect(noDefaultCubit.selectCount, 0);
        expect(noDefaultSession.thinkingWrites, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'shows the provider-default hint only below its own option inside the open menu',
      (tester) async {
        fakeClient.snapshotResult = snapshotFor(
          'model-a',
          const ThinkingControlDescriptorDto(
            status: ThinkingCapabilityStatus.supported,
            kind: ThinkingControlKind.effort,
            defaultOptionId: 'medium',
            options: supportedOptions,
          ),
        );
        final sessionCubit = _TestSessionCubit(
          Session(
            id: 'session-1',
            title: 'Session 1',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            modelProvider: 'provider-1',
            model: 'model-a',
          ),
        );
        final inputCubit = _TestConversationInputCubit(
          mirrorSessionCubit: sessionCubit,
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: createInputSlice(
              nextMessageProviderId: 'provider-1',
              nextMessageModel: 'model-a',
            ),
            inputCubit: inputCubit,
            sessionCubit: sessionCubit,
          ),
        );
        await tester.pumpAndSettle();

        // The closed chip names the admitted option and never the hint.
        expect(find.byKey(const Key('chip_Medium')), findsOneWidget);
        expect(find.text('Provider default'), findsNothing);
        expect(find.byKey(const Key('chip_Provider default')), findsNothing);

        await tester.tap(
          find.byKey(const Key('route_thinking_mode_selector_button')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('thinking_mode_default_hint_medium')),
          findsOneWidget,
          reason: 'the hint annotates the declared native default only',
        );
        expect(
          find.byKey(const Key('thinking_mode_default_hint_low')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('thinking_mode_default_hint_high')),
          findsNothing,
        );
        expect(find.text('Provider default'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('marks no option when the declared default is unknown', (
      tester,
    ) async {
      fakeClient.snapshotResult = snapshotFor(
        'model-a',
        const ThinkingControlDescriptorDto(
          status: ThinkingCapabilityStatus.supported,
          kind: ThinkingControlKind.effort,
          defaultOptionId: 'unmatched',
          options: supportedOptions,
        ),
      );
      final sessionCubit = _TestSessionCubit(
        Session(
          id: 'session-1',
          title: 'Session 1',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          modelProvider: 'provider-1',
          model: 'model-a',
        ),
      );
      final inputCubit = _TestConversationInputCubit(
        mirrorSessionCubit: sessionCubit,
      );

      await tester.pumpWidget(
        createWidget(
          inputSlice: createInputSlice(
            nextMessageProviderId: 'provider-1',
            nextMessageModel: 'model-a',
          ),
          inputCubit: inputCubit,
          sessionCubit: sessionCubit,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('chip_Provider default')), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('route_thinking_mode_selector_button')),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('Provider default'),
        findsOneWidget,
        reason: 'only the closed chip names the Provider default state; an '
            'unknown default must never mark an arbitrary option',
      );
      for (final optionId in supportedOptions.map((option) => option.id)) {
        expect(
          find.byKey(Key('thinking_mode_default_hint_$optionId')),
          findsNothing,
        );
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeps a declared budget count readable next to the hint', (
      tester,
    ) async {
      fakeClient.snapshotResult = snapshotFor(
        'model-a',
        const ThinkingControlDescriptorDto(
          status: ThinkingCapabilityStatus.supported,
          kind: ThinkingControlKind.tokenBudget,
          defaultOptionId: 'medium',
          options: [
            ThinkingControlOptionDto(id: 'off', label: 'Off', isOff: true),
            ThinkingControlOptionDto(id: 'low', label: 'Low', budgetTokens: 1024),
            ThinkingControlOptionDto(
              id: 'medium',
              label: 'Medium',
              budgetTokens: 8192,
            ),
          ],
        ),
      );
      final sessionCubit = _TestSessionCubit(
        Session(
          id: 'session-1',
          title: 'Session 1',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
          modelProvider: 'provider-1',
          model: 'model-a',
        ),
      );
      final inputCubit = _TestConversationInputCubit(
        mirrorSessionCubit: sessionCubit,
      );

      await tester.pumpWidget(
        createWidget(
          inputSlice: createInputSlice(
            nextMessageProviderId: 'provider-1',
            nextMessageModel: 'model-a',
          ),
          inputCubit: inputCubit,
          sessionCubit: sessionCubit,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('route_thinking_mode_selector_button')),
      );
      await tester.pumpAndSettle();

      expect(thinkingMenuSecondaryLabel(tester, 'medium'), '8192 tokens');
      expect(
        find.byKey(const Key('thinking_mode_default_hint_medium')),
        findsOneWidget,
      );
      expect(find.text('8192 tokens'), findsOneWidget);
      expect(find.text('Provider default'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'renders the declared choices strongest-first for model and legacy routes',
      (tester) async {
        fakeClient.snapshotResult = snapshotFor(
          'model-a',
          const ThinkingControlDescriptorDto(
            status: ThinkingCapabilityStatus.supported,
            kind: ThinkingControlKind.effort,
            defaultOptionId: 'medium',
            options: supportedOptions,
          ),
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: createInputSlice(
              nextMessageProviderId: 'provider-1',
              nextMessageModel: 'model-a',
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          thinkingMenuOptionIds(tester),
          <String>['high', 'medium', 'low'],
          reason: 'a display reversal keeps the exact declared option ids',
        );

        await tester.pumpWidget(
          createWidget(
            inputSlice: createInputSlice(),
            capabilities: const Capability(
              supportsThinkingModeChange: true,
              thinkingModesList: ['quick', 'balanced', 'deep'],
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          thinkingMenuOptionIds(tester),
          <String>['deep', 'balanced', 'quick'],
          reason: 'the legacy device list reverses for display too',
        );
      },
    );
  });
}
