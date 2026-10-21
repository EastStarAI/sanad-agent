import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/thinking_control.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
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

  /// The conversation the route identity was last resolved for. A change here
  /// keeps the route (and its resolved descriptor) but needs its own admission.
  String? _lastSessionId;

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
      unawaited(_loadSnapshot());
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
      _checkRouteChanged(session: session, activeAgent: widget.activeAgent);
    }
  }

  @override
  void didUpdateWidget(RouteThinkingModeSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    final session = _currentSession();
    _checkRouteChanged(session: session, activeAgent: widget.activeAgent);
  }

  /// Reads the owning composer cubit, or `null` when this control is mounted
  /// without one (isolated legacy surfaces), so route resolution still renders
  /// without inventing a selection owner.
  ConversationInputCubit? _inputCubit() {
    try {
      return context.read<ConversationInputCubit>();
    } catch (_) {
      return null;
    }
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

    final activeSessionId = session?.id;
    final conversationChanged = _lastSessionId != activeSessionId;
    _lastSessionId = activeSessionId;

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
        unawaited(_loadSnapshot());
      } else {
        _loadToken = null;
        setState(() {
          _isLoading = false;
          _hasFetchError = false;
        });
      }
    } else if (conversationChanged && usesModelControls) {
      // Same route, another conversation: the descriptor already resolved for
      // this setup still describes it, so admit *this* conversation's own
      // effective selection. Without this a fresh conversation would stay unset
      // even though its route declares a native default, and inheriting the
      // previous conversation's value is never an option.
      unawaited(_applyEffectiveSelection(_snapshot));
    }
  }

  Future<void> _loadSnapshot() async {
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
      await _applyEffectiveSelection(snapshot);
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

  /// A deferred admission waits until the composer owns the conversation it was
  /// resolved for, so the composer's own ownership change is what retries it.
  /// Its published state is passed with it: that state is fresher than the slice
  /// this widget was last built with.
  Future<void> _admitForComposerOwnershipChange(ConversationInputState composerState) {
    return _applyEffectiveSelection(_snapshot, composerState: composerState);
  }

  /// Admits the exact selection this route must carry for the conversation the
  /// composer currently owns, after an authoritative snapshot resolved its
  /// descriptor.
  ///
  /// A valid explicit user choice is kept verbatim, including an exact `Off`.
  /// With no valid explicit choice the route's own known native default is
  /// admitted as an ordinary option through the real composer selection path,
  /// so the rendered choice and the value the next send carries cannot diverge.
  /// A route with no known native default, or one whose declaration no longer
  /// matches a current option, admits no selection at all: the menu stays open
  /// for the user and the request simply omits thinking instead of guessing a
  /// tier. Unknown evidence is never treated as capability proof.
  ///
  /// Resolution always reads the *currently* selected conversation, so a
  /// resolver that finishes after a conversation switch can never write onto the
  /// conversation it started for. Admitting is skipped while the composer still
  /// owns a different conversation, because that write would land on that other
  /// conversation; the deferred admission is retried from the composer's own
  /// ownership change instead of an older captured owner.
  ///
  /// [composerState] is the published state of that ownership change. It is the
  /// authority for the value this route already carries, because this widget's
  /// own slice is a projection built for the previous frame and can still hold
  /// the conversation the composer just left.
  Future<void> _applyEffectiveSelection(
    ModelCacheSnapshotDto? snapshot, {
    ConversationInputState? composerState,
  }) async {
    final cubit = _inputCubit();
    if (cubit == null) {
      return;
    }
    final session = _currentSession();
    final composerSessionId = cubit.state.activeSessionId;
    final sessionId = session?.id;
    if (composerSessionId != null && composerSessionId.isNotEmpty && composerSessionId != sessionId) {
      return;
    }
    final descriptor = _descriptorForSession(session, snapshot);
    _publishRouteAdmission(cubit, session: session, descriptor: descriptor);
    if (descriptor != null && descriptor.status == ThinkingCapabilityStatus.unknown) {
      // Unknown evidence is not capability proof: keep the user's explicit
      // choice instead of rewriting it on a guess.
      return;
    }
    final currentSelection = _currentSelectionId(session, composerState: composerState)?.trim();
    final targetSelectionId = RouteThinkingControl.resolveSelectionId(
      descriptor: descriptor,
      selectionId: currentSelection,
    );
    if (targetSelectionId == currentSelection) {
      // Already admitted: never rewrite an unchanged value, so resolution can
      // never loop through the composer state.
      return;
    }
    if (sessionId != null && sessionId.isNotEmpty) {
      // Opening or hydrating an existing conversation is not a user choice:
      // show the effective value and carry it on the next send, but never
      // write it to the session or the device (live acceptance 106b r2 G2).
      cubit.admitRouteThinkingMode(targetSelectionId);
      return;
    }
    // A new-conversation draft has no session to write: the composer's own
    // selection path keeps the admitted value and the next send in step.
    await cubit.selectThinkingMode(
      scope: widget.capabilities.thinkingModeScope,
      thinkingMode: targetSelectionId,
    );
  }

  /// Tells the composer whether this route's resolved control can carry a
  /// selection. Only an authoritative resolution is published, and only from
  /// resolution (never from `build`), so rendering stays side-effect-free.
  void _publishRouteAdmission(
    ConversationInputCubit cubit, {
    required Session? session,
    required ThinkingControlDescriptorDto? descriptor,
  }) {
    if (!widget.capabilities.usesModelThinkingControls || !_isAuthoritativeSnapshot) {
      return;
    }
    final state = RouteThinkingControl.selectorState(
      capabilities: widget.capabilities,
      descriptor: descriptor,
    );
    cubit.reportRouteThinkingAdmission(
      providerId: RouteThinkingControl.activeProviderId(session: session, inputSlice: widget.inputSlice),
      modelId: RouteThinkingControl.activeModelId(session: session, inputSlice: widget.inputSlice),
      admitsSelection: state != RouteThinkingSelectorState.noControl && state != RouteThinkingSelectorState.unknown,
    );
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

  /// The selection this route already carries for [session].
  ///
  /// The composer cubit owns the pending value, so its published state is used
  /// when it is supplied; otherwise the value comes from this widget's slice.
  String? _currentSelectionId(
    Session? session, {
    ConversationInputState? composerState,
  }) {
    final pending = composerState != null
        ? composerState.nextMessageThinkingMode
        : widget.inputSlice.nextMessageThinkingMode;
    if (widget.capabilities.thinkingModeScope == CapabilityValueScope.message) {
      return pending ?? session?.thinkingMode?.trim();
    }
    final sessionMode = session?.thinkingMode?.trim();
    if (sessionMode != null && sessionMode.isNotEmpty) {
      return sessionMode;
    }
    return pending;
  }

  List<_ThinkingMenuEntry> _menuEntries({
    required AppLocalizations l10n,
    required RouteThinkingSelectorState selectorState,
    required ThinkingControlDescriptorDto? descriptor,
  }) {
    // Choices render strongest-first: the declared order is reversed for display
    // only, so exact native ids, the finite set, dispatch values and native
    // metadata stay untouched. This is a display reversal, never a strength
    // ladder, sort heuristic or provider remapping.
    if (selectorState == RouteThinkingSelectorState.legacy) {
      return widget.capabilities.thinkingModesList.reversed
          .map(
            (mode) => _ThinkingMenuEntry(optionId: mode, label: mode),
          )
          .toList(growable: false);
    }
    if (selectorState != RouteThinkingSelectorState.selectable) {
      return const [];
    }
    final nativeDefaultId = RouteThinkingControl.nativeDefaultOption(descriptor)?.id;
    // Every row is one exact declared native option. There is no synthetic
    // Default row: the route's known native default is auto-selected as its own
    // ordinary option, and only that option carries the menu-only hint. An
    // unknown default marks no row at all rather than guessing one.
    return <_ThinkingMenuEntry>[
      ...?descriptor?.options.reversed.map(
        (option) => _ThinkingMenuEntry(
          optionId: option.id,
          label: option.label,
          secondaryLabel: _budgetAnnotation(
            l10n: l10n,
            descriptor: descriptor,
            option: option,
          ),
          isNativeDefault: option.id == nativeDefaultId,
        ),
      ),
    ];
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
        child: widget.chipBuilder(
          context,
          l10n.thinkingModeLoadingLabel,
          enabled: false,
        ),
      );
    } else if (selectorState == RouteThinkingSelectorState.fetchFailure) {
      content = KeyedSubtree(
        key: const Key('route_thinking_mode_fetch_failure'),
        child: InkWell(
          onTap: () => unawaited(_loadSnapshot()),
          child: Tooltip(
            message: l10n.thinkingModeFetchFailureTooltip,
            child: widget.chipBuilder(
              context,
              l10n.thinkingModeRetryLabel,
              enabled: true,
            ),
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
      final storedSelection = _currentSelectionId(session)?.trim();
      final isLegacy = selectorState == RouteThinkingSelectorState.legacy;
      // The control shows the conversation's stored selection, or the route's
      // own effective selection (its known native default) when nothing valid
      // is stored. That is exactly what the next send carries, and showing it
      // never writes it (live acceptance 106b r2 G2).
      final currentSelection = isLegacy || descriptor == null
          ? storedSelection
          : RouteThinkingControl.resolveSelectionId(descriptor: descriptor, selectionId: storedSelection);
      final legacyCheckedId = isLegacy
          ? RouteThinkingControl.checkedMenuEntryId(
              selectionId: currentSelection,
              legacyModes: widget.capabilities.thinkingModesList,
            )
          : null;
      final checkedOptionId = isLegacy
          ? legacyCheckedId
          : RouteThinkingControl.checkedMenuEntryId(
              selectionId: currentSelection,
              legacyModes: const [],
            );
      // The control always shows a selected value (user rule 2026-10-21): the
      // exact admitted option, a legacy device-list match, or — when nothing
      // valid is stored and no layer declares a valid default — the selected
      // "Provider default" state, which sends no thinking field. There is no
      // empty or "not selected" state, and the menu still lists only the
      // declared native options.
      final label =
          RouteThinkingControl.labelForSelection(
            descriptor: descriptor,
            selectionId: currentSelection,
          ) ??
          legacyCheckedId ??
          l10n.thinkingModeProviderDefaultSelectedLabel;

      final selectedOption = descriptor?.options.where((option) => option.id == currentSelection).firstOrNull;
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

      content = PopupMenuButton<String>(
        key: const Key('route_thinking_mode_selector_button'),
        tooltip: selectedBudgetAnnotation == null
            ? l10n.thinkingModeSelectTooltip
            : l10n.thinkingModeSelectBudgetTooltip(selectedBudgetAnnotation),
        // Bounded width so a label plus its budget annotation stays readable
        // instead of overflowing the menu row.
        constraints: const BoxConstraints(minWidth: 240),
        child: widget.chipBuilder(context, label, enabled: true),
        itemBuilder: (context) {
          final theme = Theme.of(context);
          return menuEntries
              .map(
                (entry) {
                  final isSelected = entry.optionId == checkedOptionId;
                  final secondaryLabel = entry.secondaryLabel;
                  // The native-default hint is a menu-only annotation below the
                  // default's own option: it never reaches the chip, and a route
                  // without a known native default shows no hint at all.
                  final defaultHint = entry.isNativeDefault ? l10n.thinkingModeProviderDefaultHint : null;
                  final annotationCount = (secondaryLabel == null ? 0 : 1) + (defaultHint == null ? 0 : 1);
                  return PopupMenuItem<String>(
                    key: Key('thinking_mode_option_${entry.optionId}'),
                    value: entry.optionId,
                    height: annotationCount == 0 ? 32 : (annotationCount == 1 ? 44 : 56),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isSelected)
                          Icon(
                            Icons.check,
                            key: Key('thinking_mode_check_${entry.optionId}'),
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
                                key: Key('thinking_mode_title_${entry.optionId}'),
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
                                  key: Key('thinking_mode_secondary_${entry.optionId}'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              if (defaultHint != null)
                                Text(
                                  defaultHint,
                                  key: Key('thinking_mode_default_hint_${entry.optionId}'),
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
        onSelected: (optionId) {
          // Every choice dispatches its exact declared option id; the route's
          // own native default is a real option id, never a reserved string.
          unawaited(
            context.read<ConversationInputCubit>().selectThinkingMode(
              scope: widget.capabilities.thinkingModeScope,
              thinkingMode: optionId,
            ),
          );
        },
      );
    }

    if (!usesModelControls) {
      return content;
    }

    Widget wrapped = content;
    // A deferred admission waits until the composer owns the conversation it was
    // resolved for, so the composer's own ownership change is what retries it.
    try {
      context.read<ConversationInputCubit>();
      wrapped = BlocListener<ConversationInputCubit, ConversationInputState>(
        listenWhen: (previous, current) => previous.activeSessionId != current.activeSessionId,
        listener: (context, state) {
          unawaited(_admitForComposerOwnershipChange(state));
        },
        child: wrapped,
      );
    } catch (_) {}
    try {
      context.read<SessionCubit>();
      wrapped = BlocListener<SessionCubit, SessionState>(
        listenWhen: (previous, current) => previous.selectedSession != current.selectedSession,
        listener: (context, state) {
          _checkRouteChanged(
            session: state.selectedSession,
            activeAgent: widget.activeAgent,
          );
        },
        child: wrapped,
      );
    } catch (_) {}
    return wrapped;
  }
}

class _ThinkingMenuEntry {
  final String optionId;
  final String label;

  /// Optional annotation under the label: the declared token budget of a budget
  /// preset.
  final String? secondaryLabel;

  /// True only for the one option the descriptor declared as this route's native
  /// default, which carries the menu-only provider-default hint.
  final bool isNativeDefault;

  const _ThinkingMenuEntry({
    required this.optionId,
    required this.label,
    this.secondaryLabel,
    this.isNativeDefault = false,
  });
}
