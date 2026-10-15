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

import '../mocks/mock_socket_service.dart';

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
    return MaterialApp(home: child);
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
    expect(find.text('Low'), findsOneWidget);
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
    expect(find.text('High'), findsOneWidget);
  });

  testWidgets(
    'renders Default chip for providerManaged models without Off label',
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
        find.byKey(const Key('route_thinking_mode_provider_managed')),
        findsOneWidget,
      );
      expect(find.text('Default'), findsOneWidget);
      expect(find.text('Off'), findsNothing);
      expect(find.text('Unavailable'), findsNothing);
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
      expect(find.text('High Effort'), findsOneWidget);

      final inputSlice2 = createInputSlice(
        nextMessageProviderId: 'provider-2',
        nextMessageModel: 'shared-model-id',
      );

      await tester.pumpWidget(createWidget(inputSlice: inputSlice2));
      await tester.pumpAndSettle();

      expect(find.text('High Effort'), findsNothing);
      expect(
        find.byKey(const Key('route_thinking_mode_provider_managed')),
        findsOneWidget,
      );
      expect(find.text('Default'), findsOneWidget);
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
      expect(find.text('Route B High'), findsOneWidget);
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

      expect(find.text('Medium Effort'), findsOneWidget);

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

    expect(find.text('Agent 1 High'), findsOneWidget);

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
    expect(find.text('Agent 2 Low'), findsOneWidget);
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
      expect(find.text('Route A Low'), findsOneWidget);

      final sliceB = createInputSlice(
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'model-b',
      );

      await tester.pumpWidget(createWidget(inputSlice: sliceB));
      await tester.pumpAndSettle();
      expect(find.text('Route B High'), findsOneWidget);

      // Now switch back to Route A. With pending completer on background fetch:
      fakeClient.pendingSnapshotCompleter = Completer<ModelCacheSnapshotDto>();
      await tester.pumpWidget(createWidget(inputSlice: sliceA));
      await tester.pump();

      // No flicker to loading! Route A Low is displayed immediately
      expect(
        find.byKey(const Key('route_thinking_mode_loading')),
        findsNothing,
      );
      expect(find.text('Route A Low'), findsOneWidget);
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

      // Authoritative unknown: shows Default, NOT Loading...
      expect(
        find.byKey(const Key('route_thinking_mode_loading')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('route_thinking_mode_provider_managed')),
        findsOneWidget,
      );
      expect(find.text('Default'), findsOneWidget);
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

      expect(find.text('Low'), findsOneWidget);
      expect(find.text('High'), findsNothing);

      final sliceB = createInputSlice(
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'VendorB/model',
      );

      await tester.pumpWidget(createWidget(inputSlice: sliceB));
      await tester.pumpAndSettle();

      expect(find.text('High'), findsOneWidget);
      expect(find.text('Low'), findsNothing);
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

        expect(find.byKey(const Key('chip_Medium')), findsOneWidget);

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

        expect(find.byKey(const Key('chip_Off')), findsOneWidget);

        await tester.tap(find.byKey(const Key('route_thinking_mode_selector_button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('thinking_mode_option_off')), findsOneWidget);
        expect(find.byKey(const Key('thinking_mode_option_max')), findsOneWidget);
        expect(find.byKey(const Key('thinking_mode_option_low')), findsNothing);
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

        expect(find.byKey(const Key('route_thinking_mode_provider_managed')), findsOneWidget);
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

        expect(find.byKey(const Key('route_thinking_mode_hidden')), findsOneWidget);
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

        expect(find.byKey(const Key('route_thinking_mode_provider_managed')), findsOneWidget);

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
          find.byKey(const Key('chip_High')),
          findsOneWidget,
          reason: 'the grounded model default is High, not a fabricated Default',
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
          reason: 'the grounded default tier must be the checked entry',
        );
      },
    );

    testWidgets(
      'keeps the selector hidden for the pre-fix unsupported V4.1 descriptor',
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
          find.byKey(const Key('route_thinking_mode_hidden')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('route_thinking_mode_selector_button')),
          findsNothing,
          reason: 'an unevidenced near-ID must not gain thinking controls',
        );
      },
    );
  });
}
