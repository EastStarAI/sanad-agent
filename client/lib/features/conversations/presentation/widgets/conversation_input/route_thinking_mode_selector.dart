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
import 'package:sanad_client/l10n/app_localizations.dart';

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
  State<RouteThinkingModeSelector> createState() => _RouteThinkingModeSelectorState();
}

class _RouteThinkingModeSelectorState extends State<RouteThinkingModeSelector> {
  ModelCacheSnapshotDto? _snapshot;
  String? _snapshotAgentId;
  Object? _loadToken;
  bool _isLoading = false;
  bool _hasFetchError = false;
  bool _initialized = false;
  bool _isAuthoritativeSnapshot = false;

  String? _lastProviderId;
  String? _lastModelId;
  String? _lastDeviceId;
  bool? _lastUsesModelControls;

  StreamSubscription<ModelCacheUpdateEvent>? _modelUpdatesSub;

  @override
  void initState() {
    super.initState();
    _subscribeToModelUpdates();
  }

  void _subscribeToModelUpdates() {
    if (_modelUpdatesSub != null) return;
    try {
      if (getIt.isRegistered<ProviderSetupClient>()) {
        _modelUpdatesSub = getIt<ProviderSetupClient>().modelUpdates.listen(_handleModelUpdate);
      }
    } catch (_) {}
  }

  void _handleModelUpdate(ModelCacheUpdateEvent event) {
    if (!mounted) return;
    if (!widget.capabilities.usesModelThinkingControls) return;

    final session = _currentSession();
    final activeProvider = RouteThinkingControl.activeProviderId(
      session: session,
      inputSlice: widget.inputSlice,
    );
    if (activeProvider == null ||
        activeProvider.isEmpty ||
        event.providerInstanceId.isEmpty ||
        event.providerInstanceId != activeProvider) {
      return;
    }

    final activeAgent = widget.activeAgent;
    if (activeAgent != null) {
      final devId = event.deviceId;
      if (devId == null || devId.isEmpty || !activeAgent.representsDeviceId(devId)) {
        return;
      }
    } else if (event.deviceId != null) {
      return;
    }

    if (event.isFailed) {
      // Failed refresh retains prior validated authority where appropriate.
      return;
    }

    if (event.isUpdated) {
      unawaited(_loadSnapshot(revalidateSelection: true));
    }
  }

  @override
  void dispose() {
    unawaited(_modelUpdatesSub?.cancel());
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _subscribeToModelUpdates();
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
      _isAuthoritativeSnapshot = false;
      _snapshotAgentId = activeDevice;
    }

    final routeChanged =
        _lastUsesModelControls != usesModelControls ||
        _lastProviderId != activeProvider ||
        _lastModelId != activeModel ||
        _lastDeviceId != activeDevice;

    if (routeChanged) {
      _lastUsesModelControls = usesModelControls;
      _lastProviderId = activeProvider;
      _lastModelId = activeModel;
      _lastDeviceId = activeDevice;
      _isAuthoritativeSnapshot = false;

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
        _isAuthoritativeSnapshot = true;
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
      final sameDevice = widget.activeAgent?.id == _snapshotAgentId;
      setState(() {
        if (!sameDevice) {
          _snapshot = null;
          _isAuthoritativeSnapshot = false;
        }
        _isLoading = false;
        _hasFetchError = true;
      });
    }
  }

  Future<void> _revalidateSelection(ModelCacheSnapshotDto snapshot) async {
    final session = _currentSession();
    final descriptor = _descriptorForSession(session, snapshot);
    final currentSelection = _currentSelectionId(session);
    if (currentSelection == null || currentSelection.isEmpty) {
      return;
    }
    if (descriptor != null && descriptor.status == ThinkingCapabilityStatus.unknown) {
      // Unknown evidence is not capability proof: keep the user's explicit
      // choice instead of rewriting it to provider default on a guess.
      return;
    }
    final isInvalid =
        descriptor == null ||
        !descriptor.isSelectable ||
        !RouteThinkingControl.isValidSelection(
          descriptor: descriptor,
          selectionId: currentSelection,
        );
    if (!isInvalid) {
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
        (widget.inputSlice.nextMessageModel != null && widget.inputSlice.nextMessageModel != session?.model);
    final activeRouteRevision = hasPendingRouteChange ? null : session?.routeRevision;

    return RouteThinkingControl.resolveDescriptor(
      snapshot: snapshot,
      providerInstanceId: activeProvider,
      modelId: activeModel,
      sessionDescriptor: session?.thinkingControl,
      sessionRouteRevision: session?.routeRevision,
      activeRouteRevision: activeRouteRevision,
      sessionProviderId: session?.modelProvider,
      sessionModelId: session?.model,
      isAuthoritative: _isAuthoritativeSnapshot,
    );
  }

  String? _currentSelectionId(Session? session) {
    if (widget.capabilities.thinkingModeScope == CapabilityValueScope.message) {
      return widget.inputSlice.nextMessageThinkingMode ?? session?.thinkingMode?.trim();
    }
    final sessionMode = session?.thinkingMode?.trim();
    if (sessionMode != null && sessionMode.isNotEmpty) {
      return sessionMode;
    }
    return widget.inputSlice.nextMessageThinkingMode;
  }

  List<_ThinkingMenuEntry> _menuEntries({
    required AppLocalizations l10n,
    required RouteThinkingSelectorState selectorState,
    required ThinkingControlDescriptorDto? descriptor,
  }) {
    if (selectorState == RouteThinkingSelectorState.legacy) {
      return widget.capabilities.thinkingModesList
          .map(
            (mode) => _ThinkingMenuEntry(
              choice: ThinkingMenuChoice.option(mode),
              label: mode,
            ),
          )
          .toList(growable: false);
    }
    if (selectorState != RouteThinkingSelectorState.selectable) {
      return const [];
    }
    final documentedDefault = RouteThinkingControl.documentedDefaultOption(descriptor);
    final documentedDefaultAnnotation = _documentedDefaultAnnotation(
      l10n: l10n,
      descriptor: descriptor,
    );
    return <_ThinkingMenuEntry>[
      // Omission stays a first-class, distinct typed choice so the user can
      // return to provider default after an explicit Off or level. The
      // documented native default is shown as annotation only and is never sent
      // by this entry, and no declared option id can impersonate it.
      _ThinkingMenuEntry(
        choice: const ThinkingMenuChoice.providerDefault(),
        label: l10n.thinkingModeProviderDefaultLabel,
        secondaryLabel: documentedDefault == null ? null : documentedDefaultAnnotation,
      ),
      ...?descriptor?.options.map(
        (option) => _ThinkingMenuEntry(
          choice: ThinkingMenuChoice.option(option.id),
          label: option.label,
          secondaryLabel: _budgetAnnotation(
            l10n: l10n,
            descriptor: descriptor,
            option: option,
          ),
        ),
      ),
    ];
  }

  /// Annotation for the omission entry: the documented native default, plus the
  /// same truthful budget annotation its ordinary menu row carries when that
  /// default is itself a token-budget preset (declared count, or an
  /// amount-unknown budget marker). A budget-preset default is therefore never
  /// presented as a native effort default alone, and no count is invented.
  String? _documentedDefaultAnnotation({
    required AppLocalizations l10n,
    required ThinkingControlDescriptorDto? descriptor,
  }) {
    final documentedDefault = RouteThinkingControl.documentedDefaultOption(descriptor);
    if (documentedDefault == null) {
      return null;
    }
    final annotation = l10n.thinkingModeProviderDefaultAnnotation(
      documentedDefault.label,
    );
    final budgetAnnotation = _budgetAnnotation(
      l10n: l10n,
      descriptor: descriptor,
      option: documentedDefault,
    );
    if (budgetAnnotation == null) {
      return annotation;
    }
    // Punctuation-only glue between two already localized messages.
    return '$annotation · $budgetAnnotation';
  }

  /// Budget annotation for an option: its exact declared token count when the
  /// descriptor declared one, otherwise a plain budget marker for a
  /// token-budget preset whose count is absent. No token value is ever invented
  /// and an effort-like label is never the whole story for a budget preset.
  String? _budgetAnnotation({
    required AppLocalizations l10n,
    required ThinkingControlDescriptorDto? descriptor,
    required ThinkingControlOptionDto option,
  }) {
    final declaredTokens = RouteThinkingControl.declaredBudgetTokens(option);
    if (declaredTokens != null) {
      return l10n.thinkingModeTokenBudgetAnnotation(declaredTokens);
    }
    if (RouteThinkingControl.isUndeclaredBudgetPreset(
      descriptor: descriptor,
      option: option,
    )) {
      return l10n.thinkingModeTokenBudgetLabel;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
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
    final descriptor = usesModelControls ? _descriptorForSession(session, _snapshot) : null;
    final selectorState = RouteThinkingControl.selectorState(
      capabilities: widget.capabilities,
      descriptor: descriptor,
      isLoading: _isLoading,
      hasFetchError: _hasFetchError,
    );

    Widget content;
    if (selectorState == RouteThinkingSelectorState.unavailable) {
      // The route carries no thinking transport. The control stays visible and
      // disabled so the surface never disappears, and it offers no menu.
      content = KeyedSubtree(
        key: const Key('route_thinking_mode_unavailable'),
        child: Tooltip(
          message: l10n.thinkingModeUnavailableTooltip,
          child: widget.chipBuilder(
            context,
            l10n.thinkingModeUnavailableLabel,
            enabled: false,
          ),
        ),
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
    } else if (selectorState == RouteThinkingSelectorState.noControl) {
      content = KeyedSubtree(
        key: const Key('route_thinking_mode_no_control'),
        child: Tooltip(
          message: l10n.thinkingModeNoControlTooltip,
          child: widget.chipBuilder(
            context,
            l10n.thinkingModeNoControlLabel,
            enabled: false,
          ),
        ),
      );
    } else if (selectorState == RouteThinkingSelectorState.unknown) {
      content = KeyedSubtree(
        key: const Key('route_thinking_mode_unknown'),
        child: Tooltip(
          message: l10n.thinkingModeUnknownTooltip,
          child: widget.chipBuilder(
            context,
            l10n.thinkingModeUnknownLabel,
            enabled: false,
          ),
        ),
      );
    } else {
      final currentSelection = _currentSelectionId(session);
      final label =
          RouteThinkingControl.labelForSelection(
            descriptor: descriptor,
            selectionId: currentSelection,
            legacyModes: widget.capabilities.thinkingModesList,
          ) ??
          l10n.thinkingModeProviderDefaultLabel;

      final isLegacy = selectorState == RouteThinkingSelectorState.legacy;
      final usesProviderDefault = !isLegacy && RouteThinkingControl.usesProviderDefault(selectionId: currentSelection);
      final legacyCheckedId = isLegacy
          ? RouteThinkingControl.checkedMenuEntryId(
              selectionId: currentSelection,
              legacyModes: widget.capabilities.thinkingModesList,
            )
          : null;
      final ThinkingMenuChoice? checkedChoice = isLegacy
          ? (legacyCheckedId == null ? null : ThinkingMenuChoice.option(legacyCheckedId))
          : (usesProviderDefault
                ? const ThinkingMenuChoice.providerDefault()
                : ThinkingMenuChoice.option(currentSelection!.trim()));

      final selectedOption = descriptor?.options.where((option) => option.id == currentSelection?.trim()).firstOrNull;
      final selectedBudgetAnnotation = selectedOption == null
          ? null
          : _budgetAnnotation(
              l10n: l10n,
              descriptor: descriptor,
              option: selectedOption,
            );

      final menuEntries = _menuEntries(
        l10n: l10n,
        selectorState: selectorState,
        descriptor: descriptor,
      );

      content = PopupMenuButton<ThinkingMenuChoice>(
        key: const Key('route_thinking_mode_selector_button'),
        tooltip: selectedBudgetAnnotation == null
            ? 'Select Thinking Mode'
            : l10n.thinkingModeSelectBudgetTooltip(selectedBudgetAnnotation),
        // Bounded width so a label plus its budget/default annotation stays
        // readable instead of overflowing the menu row.
        constraints: const BoxConstraints(minWidth: 240),
        child: widget.chipBuilder(context, label, enabled: true),
        itemBuilder: (context) {
          final theme = Theme.of(context);
          return menuEntries
              .map(
                (entry) {
                  // Omission and declared options occupy disjoint widget-key
                  // namespaces, so a declared id can never collide with the
                  // omission entry even though every value is typed.
                  final optionKey = entry.choice.isProviderDefault
                      ? 'thinking_mode_omission_entry'
                      : 'thinking_mode_option_${entry.choice.optionId}';
                  final checkKey = entry.choice.isProviderDefault
                      ? 'thinking_mode_omission_check'
                      : 'thinking_mode_check_${entry.choice.optionId}';
                  final isSelected = entry.choice == checkedChoice;
                  final secondaryLabel = entry.secondaryLabel;
                  return PopupMenuItem<ThinkingMenuChoice>(
                    key: Key(optionKey),
                    value: entry.choice,
                    height: secondaryLabel == null ? 32 : 44,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isSelected)
                          Icon(
                            Icons.check,
                            key: Key(checkKey),
                            size: 14,
                            color: theme.colorScheme.primary,
                          )
                        else
                          const SizedBox(
                            key: Key('thinking_mode_check_placeholder'),
                            width: 14,
                          ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.label,
                                key: Key('thinking_mode_title_${entry.choice.optionId ?? 'omission'}'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                                  color: isSelected ? theme.colorScheme.primary : null,
                                ),
                              ),
                              if (secondaryLabel != null)
                                Text(
                                  secondaryLabel,
                                  key: Key(
                                    'thinking_mode_secondary_${entry.choice.optionId ?? 'omission'}',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              )
              .toList(growable: false);
        },
        onSelected: (choice) {
          // Omission clears the explicit selection so the request omits
          // thinking; an explicit choice dispatches its exact declared id.
          unawaited(
            context.read<ConversationInputCubit>().selectThinkingMode(
              scope: widget.capabilities.thinkingModeScope,
              thinkingMode: choice.optionId,
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
        listenWhen: (previous, current) => previous.selectedSession != current.selectedSession,
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
  final ThinkingMenuChoice choice;
  final String label;

  /// Optional annotation under the label: the documented provider default or the
  /// declared token budget of a budget preset.
  final String? secondaryLabel;

  const _ThinkingMenuEntry({
    required this.choice,
    required this.label,
    this.secondaryLabel,
  });
}
