import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/thinking_control.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_state.dart';
import 'package:sanad_client/features/conversations/presentation/utils/route_thinking_control.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';

typedef RouteThinkingModeChipBuilder =
    Widget Function(
      BuildContext context,
      String label, {
      required bool enabled,
    });

class RouteThinkingModeSelector extends StatefulWidget {
  final Capability capabilities;
  final ConversationInputSlice inputSlice;
  final DeviceConfig? activeAgent;
  final RouteThinkingModeChipBuilder chipBuilder;

  const RouteThinkingModeSelector({
    super.key,
    required this.capabilities,
    required this.inputSlice,
    required this.activeAgent,
    required this.chipBuilder,
  });

  @override
  State<RouteThinkingModeSelector> createState() =>
      _RouteThinkingModeSelectorState();
}

class _RouteThinkingModeSelectorState extends State<RouteThinkingModeSelector> {
  ModelCacheSnapshotDto? _snapshot;
  String? _snapshotAgentId;
  Object? _loadToken;
  bool _isLoading = false;
  bool _hasFetchError = false;
  bool _initialized = false;

  String? _lastProviderId;
  String? _lastModelId;
  String? _lastDeviceId;
  bool? _lastUsesModelControls;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      final session = _currentSession();
      _checkRouteChanged(
        session: session,
        activeAgent: widget.activeAgent,
        revalidateSelection: false,
      );
    }
  }

  @override
  void didUpdateWidget(RouteThinkingModeSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    final session = _currentSession();
    _checkRouteChanged(
      session: session,
      activeAgent: widget.activeAgent,
      revalidateSelection: true,
    );
  }

  Session? _currentSession() {
    try {
      return context.read<SessionCubit>().state.selectedSession;
    } catch (_) {
      return null;
    }
  }

  void _checkRouteChanged({
    required Session? session,
    required DeviceConfig? activeAgent,
    required bool revalidateSelection,
  }) {
    final usesModelControls = widget.capabilities.usesModelThinkingControls;
    final activeProvider = RouteThinkingControl.activeProviderId(
      session: session,
      inputSlice: widget.inputSlice,
    );
    final activeModel = RouteThinkingControl.activeModelId(
      session: session,
      inputSlice: widget.inputSlice,
    );
    final activeDevice = activeAgent?.id;

    if (activeDevice != _snapshotAgentId) {
      _snapshot = null;
      _snapshotAgentId = activeDevice;
    }

    final routeChanged = _lastUsesModelControls != usesModelControls ||
        _lastProviderId != activeProvider ||
        _lastModelId != activeModel ||
        _lastDeviceId != activeDevice;

    if (routeChanged) {
      _lastUsesModelControls = usesModelControls;
      _lastProviderId = activeProvider;
      _lastModelId = activeModel;
      _lastDeviceId = activeDevice;

      if (usesModelControls) {
        final cachedDescriptor = _descriptorForSession(session, _snapshot);
        if (cachedDescriptor == null) {
          setState(() {
            _isLoading = true;
            _hasFetchError = false;
          });
        }
        unawaited(_loadSnapshot(revalidateSelection: revalidateSelection));
      } else {
        _loadToken = null;
        setState(() {
          _isLoading = false;
          _hasFetchError = false;
        });
      }
    }
  }

  Future<void> _loadSnapshot({bool revalidateSelection = false}) async {
    final token = Object();
    _loadToken = token;
    final session = _currentSession();
    final cachedDescriptor = _descriptorForSession(session, _snapshot);
    if (cachedDescriptor == null && !_isLoading) {
      setState(() {
        _isLoading = true;
        _hasFetchError = false;
      });
    }
    try {
      final snapshot = await getIt<ProviderSetupClient>().modelSnapshot(
        agent: widget.activeAgent,
      );
      if (!mounted || _loadToken != token) {
        return;
      }
      setState(() {
        _snapshot = snapshot;
        _isLoading = false;
        _hasFetchError = false;
      });
      if (revalidateSelection) {
        await _revalidateSelection(snapshot);
      }
    } catch (_) {
      if (!mounted || _loadToken != token) {
        return;
      }
      setState(() {
        _snapshot = null;
        _isLoading = false;
        _hasFetchError = true;
      });
    }
  }

  Future<void> _revalidateSelection(ModelCacheSnapshotDto snapshot) async {
    final session = _currentSession();
    final descriptor = _descriptorForSession(session, snapshot);
    if (descriptor == null || !descriptor.isSelectable) {
      return;
    }
    final currentSelection = _currentSelectionId(session);
    if (RouteThinkingControl.isValidSelection(
      descriptor: descriptor,
      selectionId: currentSelection,
    )) {
      return;
    }
    final targetSessionId = session?.id;
    await context.read<ConversationInputCubit>().selectThinkingMode(
      scope: widget.capabilities.thinkingModeScope,
      thinkingMode: null,
    );
    if (!mounted || _currentSession()?.id != targetSessionId) {
      return;
    }
  }

  ThinkingControlDescriptorDto? _descriptorForSession(
    Session? session,
    ModelCacheSnapshotDto? snapshot,
  ) {
    final activeProvider = RouteThinkingControl.activeProviderId(
      session: session,
      inputSlice: widget.inputSlice,
    );
    final activeModel = RouteThinkingControl.activeModelId(
      session: session,
      inputSlice: widget.inputSlice,
    );
    final hasPendingRouteChange =
        (widget.inputSlice.nextMessageProviderId != null &&
            widget.inputSlice.nextMessageProviderId != session?.modelProvider) ||
        (widget.inputSlice.nextMessageModel != null &&
            widget.inputSlice.nextMessageModel != session?.model);
    final activeRouteRevision =
        hasPendingRouteChange ? null : session?.routeRevision;

    return RouteThinkingControl.resolveDescriptor(
      snapshot: snapshot,
      providerInstanceId: activeProvider,
      modelId: activeModel,
      sessionDescriptor: session?.thinkingControl,
      sessionRouteRevision: session?.routeRevision,
      activeRouteRevision: activeRouteRevision,
      sessionProviderId: session?.modelProvider,
      sessionModelId: session?.model,
    );
  }

  String? _currentSelectionId(Session? session) {
    if (widget.capabilities.thinkingModeScope == CapabilityValueScope.message) {
      return widget.inputSlice.nextMessageThinkingMode ??
          session?.thinkingMode?.trim();
    }
    final sessionMode = session?.thinkingMode?.trim();
    if (sessionMode != null && sessionMode.isNotEmpty) {
      return sessionMode;
    }
    return widget.inputSlice.nextMessageThinkingMode;
  }

  List<_ThinkingMenuEntry> _menuEntries({
    required RouteThinkingSelectorState selectorState,
    required ThinkingControlDescriptorDto? descriptor,
  }) {
    if (selectorState == RouteThinkingSelectorState.legacy) {
      return widget.capabilities.thinkingModesList
          .map((mode) => _ThinkingMenuEntry(id: mode, label: mode))
          .toList(growable: false);
    }
    return descriptor?.options
            .map(
              (option) => _ThinkingMenuEntry(
                id: option.id,
                label: option.label,
              ),
            )
            .toList(growable: false) ??
        const [];
  }

  @override
  Widget build(BuildContext context) {
    final usesModelControls = widget.capabilities.usesModelThinkingControls;
    Session? session;
    if (usesModelControls) {
      try {
        session = context.select<SessionCubit, Session?>(
          (cubit) => cubit.state.selectedSession,
        );
      } catch (_) {
        session = null;
      }
    }
    final descriptor = usesModelControls
        ? _descriptorForSession(session, _snapshot)
        : null;
    final selectorState = RouteThinkingControl.selectorState(
      capabilities: widget.capabilities,
      descriptor: descriptor,
      isLoading: _isLoading,
      hasFetchError: _hasFetchError,
    );

    Widget content;
    if (selectorState == RouteThinkingSelectorState.hidden) {
      content = const SizedBox(
        key: Key('route_thinking_mode_hidden'),
      );
    } else if (selectorState == RouteThinkingSelectorState.loading) {
      content = KeyedSubtree(
        key: const Key('route_thinking_mode_loading'),
        child: widget.chipBuilder(context, 'Loading...', enabled: false),
      );
    } else if (selectorState == RouteThinkingSelectorState.fetchFailure) {
      content = KeyedSubtree(
        key: const Key('route_thinking_mode_fetch_failure'),
        child: InkWell(
          onTap: () => unawaited(_loadSnapshot(revalidateSelection: true)),
          child: Tooltip(
            message: 'Failed to load thinking options. Click to retry.',
            child: widget.chipBuilder(context, 'Retry', enabled: true),
          ),
        ),
      );
    } else if (selectorState == RouteThinkingSelectorState.providerManaged) {
      content = KeyedSubtree(
        key: const Key('route_thinking_mode_provider_managed'),
        child: Tooltip(
          message: 'Thinking is managed by the provider',
          child: widget.chipBuilder(context, 'Default', enabled: false),
        ),
      );
    } else {
      final currentSelection = _currentSelectionId(session);
      final label = RouteThinkingControl.labelForSelection(
        descriptor: descriptor,
        selectionId: currentSelection,
        legacyModes: widget.capabilities.thinkingModesList,
      );

      final effectiveSelection = RouteThinkingControl.effectiveSelectionId(
        descriptor: descriptor,
        selectionId: currentSelection,
        legacyModes: widget.capabilities.thinkingModesList,
      );

      final menuEntries = _menuEntries(
        selectorState: selectorState,
        descriptor: descriptor,
      );

      content = PopupMenuButton<String>(
        key: const Key('route_thinking_mode_selector_button'),
        tooltip: 'Select Thinking Mode',
        child: widget.chipBuilder(context, label, enabled: true),
        itemBuilder: (context) {
          final theme = Theme.of(context);
          return menuEntries
              .map(
                (entry) {
                  final isSelected = entry.id == effectiveSelection;
                  return PopupMenuItem<String>(
                    key: Key('thinking_mode_option_${entry.id}'),
                    value: entry.id,
                    height: 32,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isSelected)
                          Icon(
                            Icons.check,
                            key: Key('thinking_mode_check_${entry.id}'),
                            size: 14,
                            color: theme.colorScheme.primary,
                          )
                        else
                          const SizedBox(
                            key: Key('thinking_mode_check_placeholder'),
                            width: 14,
                          ),
                        const SizedBox(width: 8),
                        Text(
                          entry.label,
                          key: Key('thinking_mode_title_${entry.id}'),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight:
                                isSelected ? FontWeight.w600 : FontWeight.w400,
                            color: isSelected ? theme.colorScheme.primary : null,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              )
              .toList(growable: false);
        },
        onSelected: (value) {
          unawaited(
            context.read<ConversationInputCubit>().selectThinkingMode(
              scope: widget.capabilities.thinkingModeScope,
              thinkingMode: value,
            ),
          );
        },
      );
    }

    if (!usesModelControls) {
      return content;
    }

    try {
      context.read<SessionCubit>();
      return BlocListener<SessionCubit, SessionState>(
        listenWhen: (previous, current) =>
            previous.selectedSession != current.selectedSession,
        listener: (context, state) {
          _checkRouteChanged(
            session: state.selectedSession,
            activeAgent: widget.activeAgent,
            revalidateSelection: true,
          );
        },
        child: content,
      );
    } catch (_) {
      return content;
    }
  }
}

class _ThinkingMenuEntry {
  final String id;
  final String label;

  const _ThinkingMenuEntry({required this.id, required this.label});
}
