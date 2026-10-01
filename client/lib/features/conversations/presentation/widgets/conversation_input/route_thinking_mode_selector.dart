import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/thinking_control.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
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
  Object? _loadToken;

  @override
  void initState() {
    super.initState();
    if (widget.capabilities.usesModelThinkingControls) {
      unawaited(_loadSnapshot());
    }
  }

  @override
  void didUpdateWidget(RouteThinkingModeSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    final shouldReload = RouteThinkingControl.shouldReloadSnapshot(
      previouslyUsedModelControls:
          oldWidget.capabilities.usesModelThinkingControls,
      usesModelControls: widget.capabilities.usesModelThinkingControls,
      previousProviderId: oldWidget.inputSlice.nextMessageProviderId,
      providerId: widget.inputSlice.nextMessageProviderId,
      previousModelId: oldWidget.inputSlice.nextMessageModel,
      modelId: widget.inputSlice.nextMessageModel,
      previousDeviceId: oldWidget.activeAgent?.id,
      deviceId: widget.activeAgent?.id,
    );
    if (shouldReload) {
      unawaited(_loadSnapshot(revalidateSelection: true));
    }
  }

  Future<void> _loadSnapshot({bool revalidateSelection = false}) async {
    final token = Object();
    _loadToken = token;
    try {
      final snapshot = await getIt<ProviderSetupClient>().modelSnapshot(
        agent: widget.activeAgent,
      );
      if (!mounted || _loadToken != token) {
        return;
      }
      setState(() => _snapshot = snapshot);
      if (revalidateSelection) {
        await _revalidateSelection(snapshot);
      }
    } catch (_) {
      if (!mounted || _loadToken != token) {
        return;
      }
      setState(() => _snapshot = null);
    }
  }

  Future<void> _revalidateSelection(ModelCacheSnapshotDto snapshot) async {
    final session = context.read<SessionCubit>().state.selectedSession;
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
    await context.read<ConversationInputCubit>().selectThinkingMode(
      scope: widget.capabilities.thinkingModeScope,
      thinkingMode: null,
    );
  }

  ThinkingControlDescriptorDto? _descriptorForSession(
    Session? session,
    ModelCacheSnapshotDto? snapshot,
  ) {
    return RouteThinkingControl.resolveDescriptor(
      snapshot: snapshot,
      providerInstanceId: RouteThinkingControl.activeProviderId(
        session: session,
        inputSlice: widget.inputSlice,
      ),
      modelId: RouteThinkingControl.activeModelId(
        session: session,
        inputSlice: widget.inputSlice,
      ),
      sessionDescriptor: session?.thinkingControl,
      sessionRouteRevision: session?.routeRevision,
      activeRouteRevision: session?.routeRevision,
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
    final session = usesModelControls
        ? context.select<SessionCubit, Session?>(
            (cubit) => cubit.state.selectedSession,
          )
        : null;
    final descriptor = usesModelControls
        ? _descriptorForSession(session, _snapshot)
        : null;
    final selectorState = RouteThinkingControl.selectorState(
      capabilities: widget.capabilities,
      descriptor: descriptor,
    );

    if (selectorState == RouteThinkingSelectorState.hidden) {
      return const SizedBox(
        key: Key('route_thinking_mode_hidden'),
      );
    }

    final currentSelection = _currentSelectionId(session);
    final label = selectorState == RouteThinkingSelectorState.unavailable
        ? 'Unavailable'
        : RouteThinkingControl.labelForSelection(
            descriptor: descriptor,
            selectionId: currentSelection,
            legacyModes: widget.capabilities.thinkingModesList,
          );

    if (selectorState == RouteThinkingSelectorState.unavailable) {
      return KeyedSubtree(
        key: const Key('route_thinking_mode_unavailable'),
        child: widget.chipBuilder(context, label, enabled: false),
      );
    }

    final effectiveSelection = RouteThinkingControl.effectiveSelectionId(
      descriptor: descriptor,
      selectionId: currentSelection,
      legacyModes: widget.capabilities.thinkingModesList,
    );

    final menuEntries = _menuEntries(
      selectorState: selectorState,
      descriptor: descriptor,
    );

    return PopupMenuButton<String>(
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
}

class _ThinkingMenuEntry {
  final String id;
  final String label;

  const _ThinkingMenuEntry({required this.id, required this.label});
}
