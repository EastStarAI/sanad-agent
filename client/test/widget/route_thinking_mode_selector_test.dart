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
import 'package:sanad_client/features/conversations/presentation/utils/route_thinking_control.dart';
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
/// A `null` entry is the provider-default omission choice.
List<String?> thinkingMenuOptionIds(WidgetTester tester) {
  final finder = find.byKey(const Key('route_thinking_mode_selector_button'));
  expect(finder, findsOneWidget);
  final button = tester.widget<PopupMenuButton<ThinkingMenuChoice>>(finder);
  return button
      .itemBuilder(tester.element(finder))
      .map((item) => (item as PopupMenuItem<ThinkingMenuChoice>).value?.optionId)
      .toList(growable: false);
}

/// Reads the secondary annotation of one built menu entry, if any. Pass `null`
/// for the provider-default omission entry.
String? thinkingMenuSecondaryLabel(WidgetTester tester, String? optionId) {
  final finder = find.byKey(const Key('route_thinking_mode_selector_button'));
  final button = tester.widget<PopupMenuButton<ThinkingMenuChoice>>(finder);
  final items = button.itemBuilder(tester.element(finder)).cast<PopupMenuItem<ThinkingMenuChoice>>();
  final entry = items.where((item) => item.value?.optionId == optionId).firstOrNull;
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
  CapabilityValueScope? selectedScope;
  String? selectedThinkingMode;
  int selectCount = 0;

  _TestConversationInputCubit() : super(const ConversationInputState());

  @override
  Future<void> selectThinkingMode({
    required CapabilityValueScope scope,
    String? thinkingMode,
  }) async {
    selectedScope = scope;
    selectedThinkingMode = thinkingMode;
    selectCount++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestSessionCubit extends Cubit<SessionState> implements SessionCubit {
  _TestSessionCubit([Session? initialSession]) : super(SessionState(selectedSession: initialSession));

  void setSession(Session? session) {
    emit(state.copyWith(selectedSession: session));
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

    final inputSlice = createInputSlice(
      nextMessageProviderId: 'provider-1',
      nextMessageModel: 'model-a',
    );

    await tester.pumpWidget(createWidget(inputSlice: inputSlice));
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
    expect(find.byKey(const Key('chip_Default')), findsOneWidget);
    expect(
      thinkingMenuOptionIds(tester),
      <String?>[null, 'low', 'high'],
      reason: 'the resolved route keeps omission plus its exact options',
    );
    expect(
      thinkingMenuSecondaryLabel(tester, null),
      'provider default: Low',
      reason: 'the documented native default is annotation, not a selection',
    );
    expect(find.byKey(const Key('chip_Low')), findsNothing);
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
    expect(find.byKey(const Key('chip_Default')), findsOneWidget);
    expect(thinkingMenuOptionIds(tester), contains('high'));
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
      expect(find.byKey(const Key('chip_Default')), findsOneWidget);
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

      await tester.pumpWidget(createWidget(inputSlice: inputSliceA));
      await tester.pump();
      expect(find.text('Loading...'), findsOneWidget);

      fakeClient.pendingSnapshotCompleter = completer2;
      final inputSliceB = createInputSlice(
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'model-b',
      );

      await tester.pumpWidget(createWidget(inputSlice: inputSliceB));
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
      expect(find.byKey(const Key('chip_Default')), findsOneWidget);
      expect(
        thinkingMenuOptionIds(tester),
        contains('high'),
        reason: 'the second route resolves its own documented default option',
      );
      expect(thinkingMenuOptionIds(tester), isNot(contains('low')));
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

      expect(find.byKey(const Key('chip_Default')), findsOneWidget);
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

    expect(find.byKey(const Key('chip_Default')), findsOneWidget);
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
    expect(find.byKey(const Key('chip_Default')), findsOneWidget);
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
      expect(find.byKey(const Key('chip_Default')), findsOneWidget);
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
      expect(find.byKey(const Key('chip_Default')), findsOneWidget);
      expect(
        thinkingMenuOptionIds(tester),
        <String?>[null, 'high'],
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
      expect(find.byKey(const Key('chip_Default')), findsOneWidget);
      expect(thinkingMenuOptionIds(tester), contains('low'));
    },
  );

  testWidgets(
    'initial load displays Loading... while authoritative unknown displays Default',
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

      expect(find.byKey(const Key('chip_Default')), findsOneWidget);
      expect(
        thinkingMenuOptionIds(tester),
        <String?>[null, 'low'],
        reason: 'VendorA/model resolves only its own Low option',
      );
      expect(thinkingMenuOptionIds(tester), isNot(contains('high')));

      final sliceB = createInputSlice(
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'VendorB/model',
      );

      await tester.pumpWidget(createWidget(inputSlice: sliceB));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('chip_Default')), findsOneWidget);
      expect(
        thinkingMenuOptionIds(tester),
        <String?>[null, 'high'],
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

        expect(find.byKey(const Key('chip_Default')), findsOneWidget);
        expect(
          thinkingMenuOptionIds(tester),
          contains('medium'),
          reason: 'the documented default is annotated, not selected',
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

        expect(
          find.byKey(const Key('chip_Default')),
          findsOneWidget,
          reason: 'refresh must not turn the untouched request into the off tier',
        );
        expect(thinkingMenuOptionIds(tester), contains('off'));

        await tester.tap(find.byKey(const Key('route_thinking_mode_selector_button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('thinking_mode_option_off')), findsOneWidget);
        expect(find.byKey(const Key('thinking_mode_option_max')), findsOneWidget);
        expect(find.byKey(const Key('thinking_mode_option_low')), findsNothing);
        expect(
          find.byKey(const Key('thinking_mode_omission_check')),
          findsOneWidget,
          reason: 'omission is the checked entry, not the documented off default',
        );
        expect(
          find.byKey(const Key('thinking_mode_check_off')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'repairs invalid selection visibly to provider default on model refresh',
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

        expect(inputCubit.selectCount, 0);

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

        expect(inputCubit.selectCount, 1);
        expect(inputCubit.selectedThinkingMode, isNull);
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

        await tester.pumpWidget(createWidget(inputSlice: inputSlice));
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
        expect(
          find.byKey(const Key('chip_Default')),
          findsOneWidget,
          reason: 'untouched selection shows omission, not the grounded default',
        );
        expect(
          thinkingMenuSecondaryLabel(tester, null),
          'provider default: High',
          reason: 'the grounded model default is annotation metadata',
        );
        expect(thinkingMenuOptionIds(tester), contains('high'));

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
          find.byKey(const Key('thinking_mode_omission_check')),
          findsOneWidget,
          reason: 'omission is checked while no explicit tier is selected',
        );
        expect(
          find.byKey(const Key('thinking_mode_check_high')),
          findsNothing,
          reason: 'the grounded default tier is annotated, not checked',
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
      'returns the explicit selection to provider default through the Default entry',
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

        // Explicit Off stays visible and checked as Off.
        expect(find.byKey(const Key('chip_Off')), findsOneWidget);
        await tester.tap(find.byKey(const Key('route_thinking_mode_selector_button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('thinking_mode_check_off')), findsOneWidget);
        expect(
          find.byKey(const Key('thinking_mode_omission_check')),
          findsNothing,
        );

        await tester.tap(
          find.byKey(const Key('thinking_mode_omission_entry')),
        );
        await tester.pumpAndSettle();

        expect(inputCubit.selectCount, 1);
        expect(
          inputCubit.selectedThinkingMode,
          isNull,
          reason: 'Default clears the selection so the request omits thinking',
        );
        expect(
          inputCubit.selectedThinkingMode,
          isNot('__provider_default__'),
          reason: 'omission must never dispatch a declared or reserved id',
        );
      },
    );

    testWidgets(
      'presents the same explicit level differently from provider default',
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

        // Untouched: omission, annotated with the documented native default.
        await pumpWith(null);
        expect(find.byKey(const Key('chip_Default')), findsOneWidget);
        expect(find.byKey(const Key('chip_Medium')), findsNothing);
        expect(
          thinkingMenuSecondaryLabel(tester, null),
          'provider default: Medium',
        );

        // Explicitly selected native default: a real selection, not omission.
        await pumpWith('medium');
        expect(find.byKey(const Key('chip_Medium')), findsOneWidget);
        expect(find.byKey(const Key('chip_Default')), findsNothing);
        await tester.tap(find.byKey(const Key('route_thinking_mode_selector_button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('thinking_mode_check_medium')), findsOneWidget);
        expect(
          find.byKey(const Key('thinking_mode_omission_check')),
          findsNothing,
        );
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
          <String?>[null, 'off', 'low', 'high'],
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
        final selector = tester.widget<PopupMenuButton<ThinkingMenuChoice>>(
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
          <String?>[null, 'off', 'low'],
        );
        await tester.tap(find.byKey(const Key('route_thinking_mode_selector_button')));
        await tester.pumpAndSettle();
        expect(find.text('On'), findsOneWidget);
        expect(find.text('Off'), findsOneWidget);
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
        expect(thinkingMenuOptionIds(tester), ['quick', 'balanced', 'deep']);
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
      'keeps omission a typed choice that no declared id can collide with',
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
          find.byKey(const Key('thinking_mode_omission_entry')),
          findsOneWidget,
          reason: 'omission is keyed as a typed choice, separate from any declared id',
        );
        expect(
          find.byKey(const Key('thinking_mode_option___provider_default__')),
          findsOneWidget,
          reason: 'the declared option keeps its exact id as its own distinct entry',
        );
        expect(
          find.byKey(const Key('thinking_mode_option_provider_default')),
          findsOneWidget,
          reason: 'a declared id close to the omission key family keeps its own entry',
        );

        await tester.tap(
          find.byKey(const Key('thinking_mode_omission_entry')),
        );
        await tester.pumpAndSettle();

        expect(inputCubit.selectCount, 1);
        expect(
          inputCubit.selectedThinkingMode,
          isNull,
          reason: 'omission clears the selection so the request omits thinking',
        );

        // The declared id next to the omission key family dispatches itself.
        await tester.tap(
          find.byKey(const Key('route_thinking_mode_selector_button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('thinking_mode_option_provider_default')),
        );
        await tester.pumpAndSettle();

        expect(inputCubit.selectCount, 2);
        expect(
          inputCubit.selectedThinkingMode,
          'provider_default',
          reason: 'a declared option is never rewritten into omission',
        );
      },
    );
  });

  group('documented budget-default annotation', () {
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
      'discloses the declared budget of a documented budget default',
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

        final rowAnnotation = thinkingMenuSecondaryLabel(tester, 'low');
        expect(
          rowAnnotation,
          '1024 tokens',
          reason: 'the ordinary budget row keeps its declared count',
        );
        expect(
          thinkingMenuSecondaryLabel(tester, null),
          'provider default: Low · $rowAnnotation',
          reason: 'a documented budget default reuses its ordinary row budget annotation',
        );
      },
    );

    testWidgets(
      'identifies an amount-unknown documented budget default as a budget',
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
          reason: 'the ordinary row identifies the preset as a budget',
        );
        expect(
          thinkingMenuSecondaryLabel(tester, null),
          'provider default: High · Token budget',
          reason: 'a budget-preset default is never presented as a native effort default alone',
        );
      },
    );

    testWidgets(
      'keeps the plain annotation for a documented non-budget effort default',
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
          thinkingMenuSecondaryLabel(tester, null),
          'provider default: High',
          reason: 'an ordinary effort default gains no budget wording',
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
      expect(find.byKey(const Key('chip_افتراضي')), findsNothing);
    });

    testWidgets('localizes the omission entry and its default annotation', (
      tester,
    ) async {
      await pumpForModel(
        tester,
        const ThinkingControlDescriptorDto(
          status: ThinkingCapabilityStatus.supported,
          kind: ThinkingControlKind.effort,
          defaultOptionId: 'high',
          options: [
            ThinkingControlOptionDto(id: 'low', label: 'Low'),
            ThinkingControlOptionDto(id: 'high', label: 'High'),
          ],
        ),
        'model-default',
      );

      expect(
        find.byKey(const Key('chip_افتراضي')),
        findsOneWidget,
        reason: 'an untouched selection shows the localized omission label',
      );
      expect(find.byKey(const Key('chip_Default')), findsNothing);

      await tester.tap(
        find.byKey(const Key('route_thinking_mode_selector_button')),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<Text>(find.byKey(const Key('thinking_mode_title_omission'))).data,
        'افتراضي',
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const Key('thinking_mode_secondary_omission')),
            )
            .data,
        'الافتراضي لدى المزوّد: High',
      );
      expect(
        find.byKey(const Key('thinking_mode_omission_entry')),
        findsOneWidget,
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
  });
}
