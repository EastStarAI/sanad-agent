import 'dart:async';

import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/core/navigation/navigation_history_controller.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/session_attention_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_visual_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_sidebar_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_state.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_app_bar.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/conversations/domain/repositories/conversation_repository.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/devices/domain/device_preferences_repository.dart';
import 'package:sanad_client/features/conversations/presentation/screens/brain_activity_view.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/session_sidebar.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/sidebar/sidebar_composition.dart';
import 'package:sanad_client/features/home/presentation/widgets/conversation_workspace_layout.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_readiness_dto.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_setup_flow.dart';
import 'package:sanad_client/infrastructure/local_tools/local_tool_runtime_service.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_tool_runtime_context.dart';
import 'package:sanad_client/infrastructure/platform/window_manager_service.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:sanad_client/utils/app_platform.dart';

import 'package:sanad_client/features/home/presentation/widgets/status_bar.dart';

/// The root home screen.  It is an "orchestration screen" that spans the
/// [auth], [devices], and [conversations] features.  Placed in its own
/// [home] feature following the Widget Composition rule.
class HomeScreen extends StatefulWidget {
  final ConversationDestination? destination;

  const HomeScreen({
    super.key,
    this.destination,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    _applyInitialDestination();
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldDest = oldWidget.destination;
    final newDest = widget.destination;
    if (oldDest?.deviceId != newDest?.deviceId ||
        oldDest?.isNewConversation != newDest?.isNewConversation ||
        oldDest?.sessionId != newDest?.sessionId ||
        oldDest?.workspaceId != newDest?.workspaceId) {
      _applyInitialDestination();
    }
  }

  void _applyInitialDestination() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final routeDestination = widget.destination;
      if (routeDestination == null || !mounted) return;
      final dest = routeDestination.isConversationsList
          ? ConversationDestination.newConversation(deviceId: routeDestination.deviceId)
          : routeDestination;

      // Sync with navigation history controller for external route changes
      // (browser pop/forward, deep link). Uses stack reconciliation to
      // distinguish back/forward from new navigation.
      final historyCtrl = getIt<ConversationHistoryController>();
      if (historyCtrl.snapshot.current == null) {
        historyCtrl.setInitial(dest);
      } else if (dest != historyCtrl.snapshot.current) {
        final back = historyCtrl.snapshot.backStack;
        final forward = historyCtrl.snapshot.forwardStack;
        if (back.isNotEmpty && back.last == dest) {
          historyCtrl.goBack();
        } else if (forward.isNotEmpty && forward.first == dest) {
          historyCtrl.goForward();
        } else {
          historyCtrl.navigateTo(dest);
        }
      }

      // Set active agent. Session selection is applied by _HomeScreenContent,
      // whose BuildContext is below the SessionCubit provider created here.
      unawaited(context.read<DeviceCubit>().setActiveAgent(dest.deviceId));
    });
  }

  @override
  Widget build(BuildContext context) {
    final conversationRepository = getIt<ConversationRepository>();
    final conversationCacheRepository = getIt<ConversationCacheRepository>();
    final preferencesRepository = getIt<IDevicePreferencesRepository>();

    return MultiBlocProvider(
      providers: [
        RepositoryProvider<ConversationRepository>.value(value: conversationRepository),
        RepositoryProvider<ConversationCacheRepository>.value(
          value: conversationCacheRepository,
        ),
        RepositoryProvider<IDevicePreferencesRepository>.value(value: preferencesRepository),
        BlocProvider(
          create: (context) => SessionSidebarCubit(
            cacheRepository: context.read<ConversationCacheRepository>(),
          ),
        ),
        BlocProvider(
          create: (context) => SessionCubit(
            agentCubit: context.read<DeviceCubit>(),
            socketService: context.read<SanadSocketService>(),
            conversationRepository: context.read<ConversationRepository>(),
            historyController: getIt<ConversationHistoryController>(),
            conversationCacheRepository: context.read<ConversationCacheRepository>(),
            connectionCoordinator: getIt<DeviceConnectionCoordinator>(),
          ),
        ),
        BlocProvider(
          create: (context) => SessionMessagesCubit(
            agentCubit: context.read<DeviceCubit>(),
            sessionCubit: context.read<SessionCubit>(),
            conversationRepository: context.read<ConversationRepository>(),
            conversationCacheRepository: context.read<ConversationCacheRepository>(),
            preferencesRepository: context.read<IDevicePreferencesRepository>(),
            capabilitiesStore: getIt<DeviceCapabilitiesStore>(),
            localToolRuntime: getIt<LocalToolRuntimeService>(),
            workspaceRuntimeContext: getIt<WorkspaceToolRuntimeContext>(),
          ),
        ),
        BlocProvider(
          create: (context) => ConversationInputCubit(
            messagesCubit: context.read<SessionMessagesCubit>(),
          ),
        ),
      ],
      child: _HomeScreenContent(
        destination: widget.destination,
      ),
    );
  }
}

// ─── Content ─────────────────────────────────────────────────────────────────

class _HomeScreenContent extends StatefulWidget {
  final ConversationDestination? destination;
  const _HomeScreenContent({this.destination});

  @override
  State<_HomeScreenContent> createState() => _HomeScreenContentState();
}

class _HomeScreenContentState extends State<_HomeScreenContent> {
  static const double _tabletBreakpoint = SidebarBreakpoints.tablet;
  bool _isCheckingProviderSetup = false;
  DeviceConfig? _providerSetupDevice;
  String? _lastCheckedDeviceId;
  String? _skippedDeviceId;
  StreamSubscription<DeletedSessionIdentity>? _deletedSessionSubscription;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  Timer? _hoverDrawerCloseTimer;
  bool _isMenuButtonHovered = false;
  bool _isDrawerHovered = false;
  bool _drawerOpenedByHover = false;

  @override
  void initState() {
    super.initState();
    _applyInitialSessionSelection();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _deletedSessionSubscription = context.read<SessionCubit>().deletedSessions.listen((deleted) {
        if (!mounted) return;
        context.read<SessionMessagesCubit>().invalidateDeletedSession(
          deleted.deviceId,
          deleted.sessionId,
        );
      });
      unawaited(
        _checkProviderSetupForActiveDevice(context.read<DeviceCubit>().state),
      );
    });
  }

  @override
  void dispose() {
    _hoverDrawerCloseTimer?.cancel();
    unawaited(_deletedSessionSubscription?.cancel());
    super.dispose();
  }

  void _onCompactMenuButtonEnter() {
    _hoverDrawerCloseTimer?.cancel();
    _isMenuButtonHovered = true;
    final scaffold = _scaffoldKey.currentState;
    if (scaffold == null || scaffold.isDrawerOpen) return;
    _drawerOpenedByHover = true;
    scaffold.openDrawer();
  }

  void _onCompactMenuButtonExit() {
    _isMenuButtonHovered = false;
    _scheduleHoverDrawerClose();
  }

  void _onCompactDrawerEnter() {
    _hoverDrawerCloseTimer?.cancel();
    _isDrawerHovered = true;
  }

  void _onCompactDrawerExit() {
    _isDrawerHovered = false;
    _scheduleHoverDrawerClose();
  }

  void _scheduleHoverDrawerClose() {
    _hoverDrawerCloseTimer?.cancel();
    if (!_drawerOpenedByHover) return;
    _hoverDrawerCloseTimer = Timer(const Duration(milliseconds: 150), () {
      if (!mounted || _isMenuButtonHovered || _isDrawerHovered) return;
      final scaffold = _scaffoldKey.currentState;
      if (scaffold?.isDrawerOpen ?? false) {
        scaffold!.closeDrawer();
      }
    });
  }

  void _onDrawerChanged(bool isOpened) {
    if (isOpened) return;
    _hoverDrawerCloseTimer?.cancel();
    _isMenuButtonHovered = false;
    _isDrawerHovered = false;
    _drawerOpenedByHover = false;
  }

  @override
  void didUpdateWidget(covariant _HomeScreenContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldDest = oldWidget.destination;
    final newDest = widget.destination;
    if (oldDest?.sessionId != newDest?.sessionId ||
        oldDest?.deviceId != newDest?.deviceId ||
        oldDest?.isNewConversation != newDest?.isNewConversation ||
        oldDest?.workspaceId != newDest?.workspaceId) {
      _applyInitialSessionSelection();
    }
  }

  void _applyInitialSessionSelection() {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final dest = widget.destination;
      if (!mounted) return;

      if (dest == null) {
        final deviceState = context.read<DeviceCubit>().state;
        final activeDevice = deviceState is DeviceActive ? deviceState.activeAgent : null;
        if (activeDevice == null) return;
        final restored = context.read<ConversationCacheRepository>().restartDestination(activeDevice.id);
        final history = getIt<ConversationHistoryController>();
        if (history.snapshot.current == null) {
          history.setInitial(restored);
        } else {
          history.navigateTo(restored);
        }
        if (mounted) context.go(restored.routePath);
        return;
      }

      final devices = switch (context.read<DeviceCubit>().state) {
        DeviceActive(:final agents) => agents,
        DeviceNoActive(:final agents) => agents,
        _ => const <DeviceConfig>[],
      };
      final destinationAgent = devices.where((candidate) => candidate.id == dest.deviceId).firstOrNull;
      if (destinationAgent == null) {
        final fallbackAgent = devices.firstOrNull;
        if (fallbackAgent == null) return;
        final fallback = ConversationDestination.newConversation(deviceId: fallbackAgent.id);
        getIt<ConversationHistoryController>().replaceCurrent(fallback);
        await context.read<SessionCubit>().startNewChat(fallbackAgent);
        if (mounted) context.go(fallback.routePath);
        return;
      }

      if (dest.isSession && dest.sessionId != null) {
        final knownSessions = context.read<SessionCubit>().state.agentSessions[dest.deviceId];
        if (knownSessions != null && knownSessions.every((session) => session.id != dest.sessionId)) {
          final fallback = ConversationDestination.newConversation(deviceId: dest.deviceId);
          getIt<ConversationHistoryController>().replaceCurrent(fallback);
          await context.read<SessionCubit>().startNewChat(destinationAgent);
          if (mounted) context.go(fallback.routePath);
          return;
        }
        final mockSession = Session(
          id: dest.sessionId!,
          title: 'Loading...',
          deviceId: dest.deviceId,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        await context.read<SessionCubit>().selectSession(mockSession);
      } else if (dest.isNewConversation) {
        await context.read<SessionCubit>().startNewChat(
          destinationAgent,
          workspaceId: dest.workspaceId,
        );
      } else if (dest.isConversationsList) {
        await context.read<SessionCubit>().startNewChat(destinationAgent);
        if (mounted) {
          context.go(AppRoutes.newConversationLocation(destinationAgent.id));
        }
      }
    });
  }

  Future<void> _checkProviderSetupForActiveDevice(DeviceState state) async {
    final activeDevice = switch (state) {
      DeviceActive(:final activeAgent) => activeAgent,
      _ => null,
    };

    if (activeDevice == null || !activeDevice.isOnline) {
      // A transport restart is not evidence that provider configuration was
      // removed. Keep the last authoritative readiness result while offline.
      return;
    }

    if (_providerSetupDevice?.id == activeDevice.id ||
        _skippedDeviceId == activeDevice.id ||
        _lastCheckedDeviceId == activeDevice.id ||
        _isCheckingProviderSetup) {
      return;
    }

    final inputCubit = context.read<ConversationInputCubit>();
    final preferencesRepository = context.read<IDevicePreferencesRepository>();
    final cacheRepository = context.read<ConversationCacheRepository>();
    _isCheckingProviderSetup = true;
    try {
      final readiness = await getIt<ProviderSetupClient>().runtimeCheck(
        agent: activeDevice,
      );
      if (readiness.runtimeReady) {
        _initializeProviderSelection(
          device: activeDevice,
          readiness: readiness,
          inputCubit: inputCubit,
          preferencesRepository: preferencesRepository,
          cacheRepository: cacheRepository,
        );
      }
      if (!mounted) return;
      setState(() {
        _lastCheckedDeviceId = activeDevice.id;
        _providerSetupDevice = readiness.runtimeReady ? null : activeDevice;
      });
    } catch (_) {
      // Connection failures are indeterminate, not a "no providers" result.
      // Leave the current UI intact and allow a later reconnect to retry.
      if (mounted) {
        setState(() => _lastCheckedDeviceId = null);
      }
    } finally {
      _isCheckingProviderSetup = false;
    }
  }

  void _initializeProviderSelection({
    required DeviceConfig device,
    required ProviderReadinessDto readiness,
    required ConversationInputCubit inputCubit,
    required IDevicePreferencesRepository preferencesRepository,
    required ConversationCacheRepository cacheRepository,
    bool replaceExisting = false,
  }) {
    final providerId = readiness.activeProvider?.trim();
    final model = readiness.activeModel?.trim();
    if (providerId == null || providerId.isEmpty || model == null || model.isEmpty) {
      return;
    }

    final draft = cacheRepository.newConversationDraft(device.id);
    final hasExistingProvider =
        inputCubit.state.nextMessageProviderId?.trim().isNotEmpty == true ||
        preferencesRepository.getLastProvider(device.id)?.trim().isNotEmpty == true ||
        draft.providerId?.trim().isNotEmpty == true;
    final hasExistingModel =
        inputCubit.state.nextMessageModel?.trim().isNotEmpty == true ||
        preferencesRepository.getLastModel(device.id)?.trim().isNotEmpty == true ||
        draft.model?.trim().isNotEmpty == true;
    if (!replaceExisting && hasExistingProvider && hasExistingModel) return;

    if (!inputCubit.isClosed) {
      inputCubit.initializeProviderSelection(
        providerId: providerId,
        model: model,
        replaceExisting: replaceExisting,
      );
    }
    cacheRepository.setNewConversationDraft(
      device.id,
      providerId: providerId,
      model: model,
    );
    unawaited(
      Future.wait([
        preferencesRepository.setLastProvider(device.id, providerId),
        preferencesRepository.setLastModel(device.id, model),
      ]),
    );
  }

  void _dismissProviderSetupGate({
    bool skipped = false,
    ProviderReadinessDto? readiness,
  }) {
    final activeDevice = switch (context.read<DeviceCubit>().state) {
      DeviceActive(:final activeAgent) => activeAgent,
      _ => null,
    };
    if (!mounted) return;
    if (!skipped && activeDevice != null && readiness != null && readiness.runtimeReady) {
      _initializeProviderSelection(
        device: activeDevice,
        readiness: readiness,
        inputCubit: context.read<ConversationInputCubit>(),
        preferencesRepository: context.read<IDevicePreferencesRepository>(),
        cacheRepository: context.read<ConversationCacheRepository>(),
        replaceExisting: true,
      );
    }
    setState(() {
      if (skipped) {
        _skippedDeviceId = activeDevice?.id;
      } else {
        _skippedDeviceId = null;
      }
      _providerSetupDevice = null;
      _lastCheckedDeviceId = activeDevice?.id;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return BlocListener<SessionCubit, SessionState>(
      listenWhen: (previous, current) {
        final previousSession = previous.selectedSession;
        final currentSession = current.selectedSession;
        return previousSession?.id != currentSession?.id || previousSession?.deviceId != currentSession?.deviceId;
      },
      listener: (context, state) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          final historyCtrl = getIt<ConversationHistoryController>();
          final destination = historyCtrl.snapshot.current;
          if (destination == null) return;
          final currentLocation = GoRouterState.of(context).uri.toString();
          if (currentLocation != destination.routePath) {
            context.go(destination.routePath);
          }
        });
      },
      child: BlocListener<DeviceCubit, DeviceState>(
        listenWhen: (previous, current) {
          final previousDevice = previous is DeviceActive ? previous.activeAgent : null;
          final currentDevice = current is DeviceActive ? current.activeAgent : null;
          if (previousDevice?.id != currentDevice?.id) return true;
          return previousDevice?.isOnline != currentDevice?.isOnline;
        },
        listener: (context, state) {
          final activeDevice = state is DeviceActive ? state.activeAgent : null;
          if (_skippedDeviceId != null && _skippedDeviceId != activeDevice?.id) {
            _skippedDeviceId = null;
          }
          unawaited(_checkProviderSetupForActiveDevice(state));
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isDesktop = constraints.maxWidth > _tabletBreakpoint;

            return ValueListenableBuilder<bool>(
              valueListenable: WindowManagerService.compactModeListenable,
              builder: (context, isCompactWindow, _) {
                final enableHoverDrawer = AppPlatform.isDesktop && !isDesktop && isCompactWindow;
                return Scaffold(
                  key: _scaffoldKey,
                  drawer: isDesktop
                      ? null
                      : _SidebarDrawer(
                          enableHover: enableHoverDrawer,
                          onHoverEnter: _onCompactDrawerEnter,
                          onHoverExit: _onCompactDrawerExit,
                        ),
                  onDrawerChanged: _onDrawerChanged,
                  body: Column(
                    children: [
                      Expanded(
                        child: Stack(
                          children: [
                            if (isDesktop)
                              ConversationWorkspaceLayout(
                                child: Container(
                                  color: theme.scaffoldBackgroundColor,
                                  child: const _MainContent(isMobile: false),
                                ),
                              )
                            else
                              Container(
                                color: theme.scaffoldBackgroundColor,
                                child: _MainContent(
                                  isMobile: true,
                                  onMenuHoverEnter: enableHoverDrawer ? _onCompactMenuButtonEnter : null,
                                  onMenuHoverExit: enableHoverDrawer ? _onCompactMenuButtonExit : null,
                                ),
                              ),
                            if (_providerSetupDevice != null)
                              _ProviderSetupGate(
                                device: _providerSetupDevice!,
                                onReady: (readiness) => _dismissProviderSetupGate(
                                  readiness: readiness,
                                ),
                                onSkip: () => _dismissProviderSetupGate(skipped: true),
                              ),
                          ],
                        ),
                      ),
                      const DesktopOnlyStatusBar(),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ), // end BlocListener<DeviceCubit>
    );
  }
}

class _ProviderSetupGate extends StatelessWidget {
  final DeviceConfig device;
  final ValueChanged<ProviderReadinessDto> onReady;
  final VoidCallback onSkip;

  const _ProviderSetupGate({
    required this.device,
    required this.onReady,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned.fill(
      child: ColoredBox(
        color: theme.colorScheme.scrim.withValues(alpha: 0.72),
        child: Center(
          child: Container(
            width: 760,
            constraints: const BoxConstraints(maxWidth: 760, maxHeight: 700),
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: theme.colorScheme.outline.withValues(alpha: 0.16),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.24),
                  blurRadius: 36,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        'Provider setup required',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: onSkip,
                      icon: const Icon(Icons.close),
                      tooltip: 'Close provider setup',
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '${device.name} does not have a ready provider yet. Configure one now, or skip and continue to Home.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: ProviderSetupFlow(
                    device: device,
                    showReadyState: false,
                    onReady: onReady,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Main content ─────────────────────────────────────────────────────────────

class _MainContent extends StatelessWidget {
  final bool isMobile;
  final VoidCallback? onMenuHoverEnter;
  final VoidCallback? onMenuHoverExit;

  const _MainContent({
    required this.isMobile,
    this.onMenuHoverEnter,
    this.onMenuHoverExit,
  });

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DeviceCubit, DeviceState>(
      builder: (context, deviceState) {
        return BlocBuilder<SessionMessagesCubit, SessionMessagesState>(
          builder: (context, messagesState) {
            return BlocBuilder<SessionCubit, SessionState>(
              builder: (context, sessionState) {
                final visualState = messagesState.visualState;
                final presentedSession = _resolvePresentedSession(
                  activeSessionId: messagesState.activeSessionId,
                  selectedSession: sessionState.selectedSession,
                  agentSessions: sessionState.agentSessions,
                );
                final mainContent = _buildChat(
                  context,
                  presentedDeviceId: presentedSession?.deviceId,
                  messagesState: messagesState,
                  visualState: visualState,
                );

                final conversation = Stack(
                  children: [
                    Positioned.fill(child: mainContent),
                    if (visualState.showAppBar && presentedSession != null)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: ConversationAppBar(
                          key: ValueKey('app_bar_${presentedSession.id}'),
                          sessionTitle: presentedSession.title,
                          workspace: _workspaceFromSession(presentedSession),
                          isMobile: isMobile,
                          onMenuPressed: isMobile ? () => Scaffold.of(context).openDrawer() : null,
                          onMenuHoverEnter: onMenuHoverEnter,
                          onMenuHoverExit: onMenuHoverExit,
                        ),
                      ),
                  ],
                );
                return Stack(
                  children: [
                    Positioned.fill(child: conversation),
                    if (messagesState.showDelayedLoading || messagesState.historyLoadError != null)
                      _HistoryTransitionOverlay(
                        error: messagesState.historyLoadError,
                        onRetry: messagesState.historyLoadError == null
                            ? null
                            : context.read<SessionMessagesCubit>().retryHistoryLoad,
                      ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  DeviceWorkspace? _workspaceFromSession(Session? session) {
    if (session == null || session.workspaceId == null) return null;
    return DeviceWorkspace(
      id: session.workspaceId!,
      name: session.workspaceName ?? 'Workspace',
      path: session.workspacePath ?? '',
    );
  }

  Session? _resolvePresentedSession({
    required String? activeSessionId,
    required Session? selectedSession,
    required Map<String, List<Session>> agentSessions,
  }) {
    if (activeSessionId == null) return null;
    if (selectedSession?.id == activeSessionId) return selectedSession;
    for (final sessions in agentSessions.values) {
      final match = sessions.where((s) => s.id == activeSessionId).firstOrNull;
      if (match != null) return match;
    }
    return null;
  }

  Widget _buildChat(
    BuildContext context, {
    required String? presentedDeviceId,
    required SessionMessagesState messagesState,
    required ConversationVisualState visualState,
  }) {
    final inputCubit = context.read<ConversationInputCubit>();
    final messagesCubit = context.read<SessionMessagesCubit>();
    final cacheRepository = context.read<ConversationCacheRepository>();
    final sessionId = messagesState.activeSessionId;
    final composerSessionId = messagesState.requestedSessionId ?? sessionId;
    final viewportAnchorEventId = presentedDeviceId == null || sessionId == null
        ? null
        : cacheRepository.sessionViewportAnchor(presentedDeviceId, sessionId);
    final hasActiveWork = messagesState.executionSnapshot?.hasActiveWork ?? messagesState.isProcessing;
    final activityEligible =
        messagesState.error == null &&
        messagesState.attentionState?.visualState == SessionAttentionVisualState.runningOrResuming;

    return BrainActivityView(
      key: ValueKey(sessionId),
      messagesStream: null,
      initialMessages: messagesState.messages,
      sessionId: sessionId,
      composerSessionId: composerSessionId,
      initialViewportAnchorEventId: viewportAnchorEventId,
      followLatestOnOpen: hasActiveWork,
      activityEligible: activityEligible,
      executionSnapshot: messagesState.executionSnapshot,
      onViewportAnchorChanged: presentedDeviceId == null || sessionId == null
          ? null
          : (eventId) => cacheRepository.recordSessionViewportAnchor(
              presentedDeviceId,
              sessionId,
              eventId,
            ),
      visualState: visualState,
      pendingSteerCancellationRequestIds: messagesState.pendingSteerCancellationRequestIds,
      hasOlderHistory: messagesState.hasOlderHistory,
      isOlderHistoryLoading: messagesState.isOlderHistoryLoading,
      olderHistoryError: messagesState.olderHistoryError,
      onLoadOlderHistory: messagesCubit.loadOlderHistory,
      onLoadAnchoredHistory: messagesCubit.loadAnchoredHistory,
      onSendMessage: (text, {intent = MessageDeliveryIntent.auto}) async {
        await inputCubit.sendMessage(text, intent: intent);
      },
      onStop: () async {
        await inputCubit.stop();
      },
    );
  }
}

class _HistoryTransitionOverlay extends StatelessWidget {
  final String? error;
  final VoidCallback? onRetry;

  const _HistoryTransitionOverlay({this.error, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Positioned(
      top: 12,
      left: 16,
      right: 16,
      child: Center(
        child: Material(
          key: const Key('history_transition_overlay'),
          color: theme.colorScheme.surfaceContainerHigh,
          elevation: 4,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: error == null
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 10),
                      Text('Loading conversation…'),
                    ],
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline_rounded, size: 20),
                      const SizedBox(width: 10),
                      const Flexible(child: Text('Could not load this conversation.')),
                      const SizedBox(width: 8),
                      TextButton(
                        key: const Key('retry_history_load_button'),
                        onPressed: onRetry,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

// ─── Sidebar drawer (mobile) ───────────────────────────────────────────────

class _SidebarDrawer extends StatelessWidget {
  final bool enableHover;
  final VoidCallback? onHoverEnter;
  final VoidCallback? onHoverExit;

  const _SidebarDrawer({
    this.enableHover = false,
    this.onHoverEnter,
    this.onHoverExit,
  });

  @override
  Widget build(BuildContext context) {
    Widget content = SessionSidebar(
      isDrawerMode: true,
      onClose: () => Navigator.pop(context),
    );
    if (enableHover) {
      content = MouseRegion(
        key: const Key('compact_sidebar_hover_region'),
        onEnter: (_) => onHoverEnter?.call(),
        onExit: (_) => onHoverExit?.call(),
        child: content,
      );
    }

    return Drawer(
      backgroundColor: Theme.of(context).colorScheme.surface,
      width: (MediaQuery.of(context).size.width * SidebarBreakpoints.drawerWidthFactor).clamp(
        SidebarBreakpoints.minWidth,
        MediaQuery.of(context).size.width,
      ),
      child: content,
    );
  }
}
