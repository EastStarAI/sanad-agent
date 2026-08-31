import 'dart:async';

import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/domain/models/runtime_notice.dart';
import 'package:sanad_client/features/conversations/domain/models/llm_usage_snapshot.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/composer_slash_commands_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/composer_slash_commands_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_state.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/conversations/presentation/utils/provider_route_label.dart';
import 'package:sanad_client/features/conversations/presentation/utils/text_utils.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/context_usage_indicator.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_permission_card.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/model_picker_dialog.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/runtime_notice_card.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/route_thinking_mode_selector.dart';
import '../sidebar/sidebar_composition.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/slash_suggestion_surface.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/multiline_submission_shortcuts.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_state.dart';
import 'package:sanad_client/features/devices/data/device_inventory_source.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:flutter/foundation.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_cubit.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_state.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:google_fonts/google_fonts.dart';

class ConversationInputComposer extends StatelessWidget {
  final SlashCommandTextController chatController;
  final FocusNode chatFocusNode;
  final ConversationInputAgentSlice agentSlice;
  final ConversationInputSlice inputSlice;
  final Capability capabilities;
  final Color inputBgColor;
  final Color borderColor;
  final Color dimTextColor;
  final Color chipBgColor;
  final void Function(SlashCommandEntry entry) onSelectSlashSuggestion;
  final void Function({MessageDeliveryIntent intent}) onSendAttempt;
  final VoidCallback? onStop;
  final String? sessionId;
  final Future<bool> Function() onConfirmFullAccess;
  final GlobalKey<PopupMenuButtonState<String>> agentSelectorKey;
  final Future<void> Function(DeviceConfig? activeAgent) onPickAndCreateWorkspace;

  final int maxLines;

  const ConversationInputComposer({
    super.key,
    required this.chatController,
    required this.chatFocusNode,
    required this.agentSlice,
    required this.inputSlice,
    required this.capabilities,
    required this.inputBgColor,
    required this.borderColor,
    required this.dimTextColor,
    required this.chipBgColor,
    required this.onSelectSlashSuggestion,
    required this.onSendAttempt,
    required this.onStop,
    required this.onConfirmFullAccess,
    required this.agentSelectorKey,
    required this.onPickAndCreateWorkspace,
    this.maxLines = 8,
    this.sessionId,
  });

  @override
  Widget build(BuildContext context) {
    final supportsKeyboardSlashNavigation = !kIsWeb
        ? !(defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS)
        : true;

    return BlocBuilder<ComposerSlashCommandsCubit, ComposerSlashCommandsState>(
      builder: (context, slashState) {
        return Column(
          children: [
            if (inputSlice.runtimeNotice != null) ...[
              RuntimeNoticeCard(
                notice: inputSlice.runtimeNotice!,
                borderColor: borderColor,
                inputBgColor: inputBgColor,
                dimTextColor: dimTextColor,
                onStop: inputSlice.runtimeNotice!.actions.contains('stop')
                    ? () => context.read<ConversationInputCubit>().stop()
                    : null,
                onRetry: inputSlice.runtimeNotice!.actions.contains('retry')
                    ? () => context.read<ConversationInputCubit>().retryRuntimeNotice()
                    : null,
                onChangeProvider: _supportsProviderChange(inputSlice.runtimeNotice!)
                    ? () => _showProviderSelection(context)
                    : null,
              ),
              const SizedBox(height: 10),
            ],
            if (slashState.activeQuery != null && slashState.visibleEntries.isNotEmpty) ...[
              SlashSuggestionSurface(
                entries: slashState.visibleEntries,
                onSelected: onSelectSlashSuggestion,
                onHighlightChanged: (index) => context.read<ComposerSlashCommandsCubit>().updateHighlightIndex(index),
                borderColor: borderColor,
                query: slashState.activeQuery?.query ?? '',
                highlightedIndex: slashState.highlightedIndex,
              ),
              const SizedBox(height: 10),
            ],
            _UnifiedComposerContainer(
              chatController: chatController,
              chatFocusNode: chatFocusNode,
              agentSlice: agentSlice,
              inputSlice: inputSlice,
              capabilities: capabilities,
              inputBgColor: inputBgColor,
              borderColor: borderColor,
              dimTextColor: dimTextColor,
              chipBgColor: chipBgColor,
              onSelectSlashSuggestion: onSelectSlashSuggestion,
              onSendAttempt: onSendAttempt,
              onStop: onStop,
              sessionId: sessionId,
              onConfirmFullAccess: onConfirmFullAccess,
              supportsKeyboardSlashNavigation: supportsKeyboardSlashNavigation,
              slashState: slashState,
              context: context,
              agentSelectorKey: agentSelectorKey,
              onPickAndCreateWorkspace: onPickAndCreateWorkspace,
              maxLines: maxLines,
            ),
          ],
        );
      },
    );
  }

  bool _supportsProviderChange(RuntimeNotice notice) {
    return notice.actions.contains('change_provider') || notice.actions.contains('continue_with_provider');
  }

  Future<void> _showProviderSelection(BuildContext context) async {
    final activeAgent = agentSlice.activeAgent;
    final selectedSession = context.read<SessionCubit>().state.selectedSession;
    final activeProviderId = inputSlice.nextMessageProviderId?.trim().isNotEmpty == true
        ? inputSlice.nextMessageProviderId?.trim()
        : selectedSession?.modelProvider?.trim();
    final activeModelId = inputSlice.nextMessageModel?.trim().isNotEmpty == true
        ? inputSlice.nextMessageModel?.trim()
        : selectedSession?.model?.trim();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => ModelPickerDialog(
        agent: activeAgent,
        activeProviderId: activeProviderId,
        activeModelId: activeModelId,
        onSelected: (providerId, modelId) {
          unawaited(
            context.read<ConversationInputCubit>().continueWithProvider(
              providerInstanceId: providerId,
              modelId: modelId,
            ),
          );
        },
      ),
    );
  }
}

class _UnifiedComposerContainer extends StatelessWidget {
  final SlashCommandTextController chatController;
  final FocusNode chatFocusNode;
  final ConversationInputAgentSlice agentSlice;
  final ConversationInputSlice inputSlice;
  final Capability capabilities;
  final Color inputBgColor;
  final Color borderColor;
  final Color dimTextColor;
  final Color chipBgColor;
  final void Function(SlashCommandEntry entry) onSelectSlashSuggestion;
  final void Function({MessageDeliveryIntent intent}) onSendAttempt;
  final VoidCallback? onStop;
  final String? sessionId;
  final Future<bool> Function() onConfirmFullAccess;
  final GlobalKey<PopupMenuButtonState<String>> agentSelectorKey;
  final Future<void> Function(DeviceConfig? activeAgent) onPickAndCreateWorkspace;
  final bool supportsKeyboardSlashNavigation;
  final ComposerSlashCommandsState slashState;
  final BuildContext context;
  final int maxLines;

  const _UnifiedComposerContainer({
    required this.chatController,
    required this.chatFocusNode,
    required this.agentSlice,
    required this.inputSlice,
    required this.capabilities,
    required this.inputBgColor,
    required this.borderColor,
    required this.dimTextColor,
    required this.chipBgColor,
    required this.onSelectSlashSuggestion,
    required this.onSendAttempt,
    required this.onStop,
    required this.onConfirmFullAccess,
    required this.agentSelectorKey,
    required this.onPickAndCreateWorkspace,
    required this.supportsKeyboardSlashNavigation,
    required this.slashState,
    required this.context,
    required this.maxLines,
    this.sessionId,
  });

  @override
  Widget build(BuildContext context) {
    final innerBg = Colors.transparent;

    final composerCard = Container(
      decoration: BoxDecoration(
        color: innerBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (inputSlice.pendingSuspendedRequest != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: ConversationPermissionCard(
                key: ValueKey(inputSlice.pendingSuspendedRequest!.requestId),
                request: inputSlice.pendingSuspendedRequest!,
                borderColor: borderColor,
              ),
            )
          else ...[
            if (inputSlice.requiresWorkspace && inputSlice.selectedWorkspace == null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: _WorkspaceWarning(onRefresh: () => context.read<ConversationInputCubit>().refreshWorkspaces()),
              ),
            ],
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: MultilineSubmissionShortcuts(
                controller: chatController,
                onSubmit: () {
                  if (slashState.activeQuery != null && slashState.visibleEntries.isNotEmpty) {
                    onSelectSlashSuggestion(slashState.visibleEntries[slashState.highlightedIndex]);
                    return;
                  }
                  onSendAttempt(intent: MessageDeliveryIntent.auto);
                },
                additionalDesktopBindings: {
                  if (supportsKeyboardSlashNavigation && slashState.visibleEntries.isNotEmpty)
                    const SingleActivator(LogicalKeyboardKey.arrowDown, includeRepeats: false): () {
                      context.read<ComposerSlashCommandsCubit>().moveHighlight(1);
                    },
                  if (supportsKeyboardSlashNavigation && slashState.visibleEntries.isNotEmpty)
                    const SingleActivator(LogicalKeyboardKey.arrowUp, includeRepeats: false): () {
                      context.read<ComposerSlashCommandsCubit>().moveHighlight(-1);
                    },
                  if (slashState.visibleEntries.isNotEmpty)
                    const SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false): () {
                      context.read<ComposerSlashCommandsCubit>().clear();
                    },
                  const SingleActivator(LogicalKeyboardKey.enter, meta: true, includeRepeats: false): () {
                    onSendAttempt(intent: MessageDeliveryIntent.queue);
                  },
                  const SingleActivator(
                    LogicalKeyboardKey.enter,
                    control: true,
                    includeRepeats: false,
                  ): () {
                    onSendAttempt(intent: MessageDeliveryIntent.queue);
                  },
                },
                child: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: chatController,
                  builder: (context, value, _) {
                    final textDirection = TextUtils.getTextDirection(chatController.exportPlainText());
                    return TextField(
                      key: const Key('chat_input'),
                      controller: chatController,
                      focusNode: chatFocusNode,
                      style: GoogleFonts.inter(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontSize: 15,
                        height: 1.5,
                      ),
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      maxLines: maxLines,
                      minLines: 1,
                      textAlign: textDirection == TextDirection.rtl ? TextAlign.right : TextAlign.left,
                      textDirection: textDirection,
                      decoration: InputDecoration(
                        hintText: 'Ask Sanad anything',
                        hintStyle: GoogleFonts.inter(
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.35),
                          fontSize: 15,
                        ),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    );
                  },
                ),
              ),
            ),
            _buildBottomRow(context),
          ],
        ],
      ),
    );

    return GestureDetector(
      key: const Key('composer_focus_surface'),
      behavior: HitTestBehavior.opaque,
      onTap: chatFocusNode.requestFocus,
      child: composerCard,
    );
  }

  Widget _buildBottomRow(BuildContext context) {
    final hasPendingRequest = inputSlice.pendingSuspendedRequest != null;

    final modelChip = !hasPendingRequest && capabilities.supportsModelChange
        ? _ModelChip(
            agentSlice: agentSlice,
            inputSlice: inputSlice,
            capabilities: capabilities,
            dimTextColor: dimTextColor,
            chipBgColor: chipBgColor,
            borderColor: borderColor,
          )
        : null;

    final thinkingModeChip = !hasPendingRequest
        ? RouteThinkingModeSelector(
            capabilities: capabilities,
            inputSlice: inputSlice,
            activeAgent: agentSlice.activeAgent,
            chipBuilder: (context, label, {required enabled}) {
              return _buildThinkingModeChipShell(
                context,
                label: label,
                enabled: enabled,
              );
            },
          )
        : null;

    final sendStopButton = ValueListenableBuilder<TextEditingValue>(
      valueListenable: chatController,
      builder: (context, value, _) {
        return _SendStopButton(
          agentSlice: agentSlice,
          inputSlice: inputSlice,
          capabilities: capabilities,
          chatController: chatController,
          onSendAttempt: onSendAttempt,
          onStop: onStop,
          dimTextColor: dimTextColor,
          sessionId: sessionId,
        );
      },
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: borderColor),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // TODO: Implement upload file functionality feature later
              // IconButton(
              //   icon: Icon(Icons.add, size: 18, color: dimTextColor),
              //   onPressed: () {},
              //   constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              //   padding: EdgeInsets.zero,
              // ),
              // const SizedBox(width: 8),
              if (!hasPendingRequest &&
                  capabilities.supportsToolPermissions &&
                  inputSlice.selectedWorkspace != null) ...[
                _PermissionModeChip(
                  permissionMode: inputSlice.permissionMode,
                  isLoadingPermissionMode: inputSlice.isLoadingPermissionMode,
                  dimTextColor: dimTextColor,
                  chipBgColor: chipBgColor,
                  borderColor: borderColor,
                  onConfirmFullAccess: onConfirmFullAccess,
                ),
              ],
            ],
          ),
          if (SidebarBreakpoints.isCompact(context))
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                mainAxisSize: MainAxisSize.max,
                children: [
                  Flexible(
                    child: Wrap(
                      direction: Axis.horizontal,
                      alignment: WrapAlignment.center,
                      spacing: 4,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (modelChip != null) modelChip,
                        if (thinkingModeChip != null) thinkingModeChip,
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  sendStopButton,
                ],
              ),
            )
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (modelChip != null) ...[
                  modelChip,
                  const SizedBox(width: 8),
                ],
                if (thinkingModeChip != null) ...[
                  thinkingModeChip,
                  const SizedBox(width: 8),
                ],
                sendStopButton,
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildThinkingModeChipShell(
    BuildContext context, {
    required String label,
    required bool enabled,
  }) {
    final isCompact = SidebarBreakpoints.isCompact(context);
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: isCompact ? 4 : 8, vertical: 4),
        decoration: BoxDecoration(
          color: chipBgColor.withValues(alpha: 0.50),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Symbols.neurology, size: 16, color: dimTextColor),
            const SizedBox(width: 4),
            Text(
              label,
              style: GoogleFonts.inter(color: dimTextColor, fontSize: 12),
            ),
            if (enabled) ...[
              const SizedBox(width: 4),
              Icon(Icons.keyboard_arrow_down, size: 12, color: dimTextColor),
            ],
          ],
        ),
      ),
    );
  }
}

class _PermissionModeChip extends StatelessWidget {
  final WorkspacePermissionMode permissionMode;
  final bool isLoadingPermissionMode;
  final Color dimTextColor;
  final Color chipBgColor;
  final Color borderColor;
  final Future<bool> Function() onConfirmFullAccess;

  const _PermissionModeChip({
    required this.permissionMode,
    required this.isLoadingPermissionMode,
    required this.dimTextColor,
    required this.chipBgColor,
    required this.borderColor,
    required this.onConfirmFullAccess,
  });

  @override
  Widget build(BuildContext context) {
    final label = isLoadingPermissionMode ? 'Loading...' : _modeLabel(permissionMode);

    return PopupMenuButton<WorkspacePermissionMode>(
      tooltip: 'Select Permission Mode',
      enabled: !isLoadingPermissionMode,
      child: _buildChip(context, label),
      itemBuilder: (context) => WorkspacePermissionMode.values
          .map(
            (mode) => PopupMenuItem<WorkspacePermissionMode>(
              value: mode,
              height: 40,
              child: Row(
                children: [
                  Icon(
                    permissionMode == mode ? Icons.check : Icons.shield_outlined,
                    size: 16,
                    color: permissionMode == mode ? Theme.of(context).colorScheme.primary : dimTextColor,
                  ),
                  const SizedBox(width: 8),
                  Text(_modeLabel(mode), style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          )
          .toList(),
      onSelected: (mode) async {
        if (mode == permissionMode) return;
        if (mode == WorkspacePermissionMode.fullAccess) {
          final confirmed = await onConfirmFullAccess();
          if (!context.mounted || !confirmed) return;
        }
        if (!context.mounted) return;
        await context.read<ConversationInputCubit>().setWorkspacePermissionMode(mode);
      },
    );
  }

  String _modeLabel(WorkspacePermissionMode mode) {
    switch (mode) {
      case WorkspacePermissionMode.defaultMode:
        return 'Default';
      case WorkspacePermissionMode.fullAccess:
        return 'Full Access';
    }
  }

  Widget _buildChip(BuildContext context, String text) {
    final theme = Theme.of(context);
    final isFullAccess = !isLoadingPermissionMode && permissionMode == WorkspacePermissionMode.fullAccess;
    final color = isFullAccess ? theme.colorScheme.tertiary : dimTextColor;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: chipBgColor.withValues(alpha: 0.50),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.shield_outlined,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            text,
            style: GoogleFonts.inter(color: color, fontSize: 11),
          ),
          const SizedBox(width: 4),
          Icon(
            Icons.keyboard_arrow_down,
            size: 12,
            color: color,
          ),
        ],
      ),
    );
  }
}

class _ModelChip extends StatefulWidget {
  final ConversationInputAgentSlice agentSlice;
  final ConversationInputSlice inputSlice;
  final Capability capabilities;
  final Color dimTextColor;
  final Color chipBgColor;
  final Color borderColor;

  const _ModelChip({
    required this.agentSlice,
    required this.inputSlice,
    required this.capabilities,
    required this.dimTextColor,
    required this.chipBgColor,
    required this.borderColor,
  });

  @override
  State<_ModelChip> createState() => _ModelChipState();
}

class _ModelChipState extends State<_ModelChip> {
  static const Duration _emptyProviderDisplayRetryCooldown = Duration(seconds: 30);
  final Map<String, Map<String, String>> _providerDisplayNamesByAgent = {};
  final Set<String> _providerDisplayLoadsInFlight = <String>{};
  final Set<String> _providerDisplayLookupAttempts = <String>{};
  final Map<String, DateTime> _emptyProviderDisplayFetchUntilByAgent = {};
  bool _didLoadInitialProviderDisplayNames = false;
  String? _lastLoadedProviderId;
  String? _lastLoadedAgentId;

  @override
  void initState() {
    super.initState();
    unawaited(_ensureProviderDisplayNamesLoaded());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didLoadInitialProviderDisplayNames) return;
    _didLoadInitialProviderDisplayNames = true;
    final selectedSession = context.read<SessionCubit>().state.selectedSession;
    unawaited(_ensureProviderDisplayNamesLoaded(selectedSession: selectedSession));
  }

  @override
  void didUpdateWidget(covariant _ModelChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    final agentChanged = oldWidget.agentSlice.activeAgent?.id != widget.agentSlice.activeAgent?.id;
    final providerChanged = oldWidget.inputSlice.nextMessageProviderId != widget.inputSlice.nextMessageProviderId;
    if (agentChanged || providerChanged) {
      _providerDisplayLookupAttempts.clear();
      unawaited(_ensureProviderDisplayNamesLoaded());
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedSession = context.select<SessionCubit, Session?>((cubit) => cubit.state.selectedSession);
    final contextUsage = context.select<SessionMessagesCubit, LlmUsageSnapshot?>(
      (cubit) => latestContextUsage(cubit.state.messages),
    );
    final providerDisplayNames =
        _providerDisplayNamesByAgent[_providerLookupKey(widget.agentSlice.activeAgent)] ?? const <String, String>{};

    final currentModel = _currentModelLabel(
      selectedSession,
      nextMessageModel: widget.inputSlice.nextMessageModel,
      providerDisplayNames: providerDisplayNames,
    );

    final showProgress = getIt.isRegistered<ProviderUsageCubit>();

    Widget buildChip(BuildContext context, double? progress, Color? progressColor) {
      return InkWell(
        key: const Key('model_selector_btn'),
        onTap: () => _openModelPicker(context),
        borderRadius: BorderRadius.circular(8),
        child: _buildModelChip(context, currentModel, contextUsage, progress, progressColor),
      );
    }

    return BlocListener<SessionCubit, SessionState>(
      listenWhen: (previous, current) => previous.selectedSession != current.selectedSession,
      listener: (context, state) {
        _providerDisplayLookupAttempts.clear();
        unawaited(_ensureProviderDisplayNamesLoaded(selectedSession: state.selectedSession));
      },
      child: showProgress
          ? BlocBuilder<ProviderUsageCubit, ProviderUsageState>(
              bloc: getIt<ProviderUsageCubit>(),
              builder: (context, usageState) {
                final theme = Theme.of(context);
                final activeProviderId = _activeProviderId(selectedSession);
                double? progress;
                Color? progressColor;

                if (activeProviderId != null && activeProviderId.isNotEmpty) {
                  final deviceId = widget.agentSlice.activeAgent?.id ?? DeviceInventoryIds.localDevice;
                  final entry = usageState.entry(deviceId, activeProviderId);
                  final supports = usageState.support.supports(deviceId, activeProviderId);

                  if (supports && entry != null && entry.phase != ProviderUsagePhase.hidden) {
                    final hasSnapshot = entry.hasVisibleSnapshot;
                    if (hasSnapshot && entry.result?.snapshot?.windows != null) {
                      double maxProgress = 0.0;
                      for (final window in entry.result!.snapshot!.windows) {
                        final remaining = window.remainingPercent;
                        final used = window.usedPercent;
                        final p = (used ?? (remaining != null ? 100.0 - remaining : 0.0)) / 100.0;
                        if (p > maxProgress) {
                          maxProgress = p;
                        }
                      }
                      progress = maxProgress.clamp(0.0, 1.0);

                      Color getProgressColor(double value) {
                        if (value >= 0.9) return const Color(0xFFE53935);
                        return theme.colorScheme.primary;
                      }

                      progressColor = getProgressColor(progress);
                    }
                  }
                }

                return buildChip(context, progress, progressColor);
              },
            )
          : Builder(
              builder: (context) => buildChip(context, null, null),
            ),
    );
  }

  String _providerLookupKey(DeviceConfig? agent) => agent?.id ?? '__local__';

  String _providerDisplayLookupAttemptKey(String agentKey, String providerId) => '$agentKey::$providerId';

  Future<void> _ensureProviderDisplayNamesLoaded({Session? selectedSession}) async {
    final activeAgent = widget.agentSlice.activeAgent;
    if (activeAgent == null) return;
    final key = _providerLookupKey(activeAgent);
    final activeProviderId = _activeProviderId(selectedSession);
    if (activeProviderId == null || activeProviderId.isEmpty) return;

    final activeAgentId = activeAgent.id;
    if (activeProviderId != _lastLoadedProviderId || activeAgentId != _lastLoadedAgentId) {
      _lastLoadedProviderId = activeProviderId;
      _lastLoadedAgentId = activeAgentId;
      if (getIt.isRegistered<ProviderUsageCubit>()) {
        unawaited(
          getIt<ProviderUsageCubit>().onInstancesLoaded(
            agent: activeAgent,
            instanceIds: [activeProviderId],
          ),
        );
      }
    }
    final knownDisplays = _providerDisplayNamesByAgent[key];
    if (knownDisplays != null && knownDisplays.isNotEmpty && knownDisplays.containsKey(activeProviderId)) return;

    final retryAfter = _emptyProviderDisplayFetchUntilByAgent[key];
    if (retryAfter != null && DateTime.now().isBefore(retryAfter)) return;
    if (_providerDisplayLoadsInFlight.contains(key)) return;

    final attemptKey = _providerDisplayLookupAttemptKey(key, activeProviderId);
    if (_providerDisplayLookupAttempts.contains(attemptKey)) return;
    _providerDisplayLookupAttempts.add(attemptKey);
    _providerDisplayLoadsInFlight.add(key);
    try {
      final client = getIt<ProviderSetupClient>();
      final names = <String, String>{};

      final snapshot = await client.modelSnapshot(agent: activeAgent);
      for (final instance in snapshot.instances) {
        final id = instance.id.trim();
        final displayName = instance.displayName.trim();
        if (id.isNotEmpty && displayName.isNotEmpty) names[id] = displayName;
      }

      if (names.isEmpty) {
        final instances = await client.listInstances(agent: activeAgent);
        for (final instance in instances) {
          final id = instance.id.trim();
          final displayName = instance.displayName.trim();
          if (id.isNotEmpty && displayName.isNotEmpty) names[id] = displayName;
        }
      }

      if (!mounted) return;

      final previousNames = _providerDisplayNamesByAgent[key] ?? const <String, String>{};
      if (names.isEmpty) {
        _emptyProviderDisplayFetchUntilByAgent[key] = DateTime.now().add(_emptyProviderDisplayRetryCooldown);
        _providerDisplayLookupAttempts.remove(attemptKey);
        if (previousNames.isEmpty) return;
      } else if (_sameProviderDisplayNames(previousNames, names)) {
        return;
      }

      setState(() {
        _providerDisplayNamesByAgent[key] = names;
        if (names.isNotEmpty) _emptyProviderDisplayFetchUntilByAgent.remove(key);
      });
    } catch (_) {
      _providerDisplayLookupAttempts.remove(attemptKey);
    } finally {
      _providerDisplayLoadsInFlight.remove(key);
    }
  }

  bool _sameProviderDisplayNames(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  void _openModelPicker(BuildContext context) {
    final selectedSession = context.read<SessionCubit>().state.selectedSession;
    final activeProviderId = widget.inputSlice.nextMessageProviderId?.trim().isNotEmpty == true
        ? widget.inputSlice.nextMessageProviderId!.trim()
        : selectedSession?.modelProvider?.trim();
    final activeModelId = widget.inputSlice.nextMessageModel?.trim().isNotEmpty == true
        ? widget.inputSlice.nextMessageModel!.trim()
        : selectedSession?.model?.trim();

    unawaited(
      showDialog(
        context: context,
        builder: (dialogContext) => ModelPickerDialog(
          agent: widget.agentSlice.activeAgent,
          activeProviderId: activeProviderId,
          activeModelId: activeModelId,
          onSelected: (providerId, modelId) {
            unawaited(
              context.read<ConversationInputCubit>().selectModel(
                scope: widget.capabilities.modelSelectionScope,
                providerId: providerId,
                model: modelId,
              ),
            );
            unawaited(
              getIt<ProviderSetupClient>().modelRecentRecord(
                providerInstanceId: providerId,
                modelId: modelId,
                agent: widget.agentSlice.activeAgent,
              ),
            );
          },
        ),
      ),
    );
  }

  String? _activeProviderId(Session? session) {
    final nextProviderId = widget.inputSlice.nextMessageProviderId?.trim();
    if (nextProviderId != null && nextProviderId.isNotEmpty) return nextProviderId;
    final sessionProvider = session?.modelProvider?.trim();
    if (sessionProvider != null && sessionProvider.isNotEmpty) return sessionProvider;
    final metadataProvider = session?.metadata?['provider']?.toString().trim();
    if (metadataProvider != null && metadataProvider.isNotEmpty) return metadataProvider;
    final metadataModelProvider = session?.metadata?['model_provider']?.toString().trim();
    if (metadataModelProvider != null && metadataModelProvider.isNotEmpty) return metadataModelProvider;
    return null;
  }

  String _currentModelLabel(
    Session? session, {
    String? nextMessageModel,
    Map<String, String> providerDisplayNames = const {},
  }) {
    final activeProviderId = _activeProviderId(session);
    final activeModelId = nextMessageModel?.trim().isNotEmpty == true
        ? nextMessageModel!.trim()
        : session?.model?.trim();
    if (activeModelId == null || activeModelId.isEmpty) return 'Select model';
    var cleanModelName = activeModelId;
    if (activeProviderId != null && activeProviderId.isNotEmpty) {
      final prefix = '${activeProviderId.toLowerCase()}/';
      if (cleanModelName.toLowerCase().startsWith(prefix)) cleanModelName = cleanModelName.substring(prefix.length);
    }
    if (cleanModelName.contains('/')) cleanModelName = cleanModelName.split('/').last;
    final providerDisplayName = resolveProviderDisplayName(
      session: session,
      providerId: activeProviderId,
      providerDisplayNames: providerDisplayNames,
    );
    if (providerDisplayName != null && providerDisplayName.isNotEmpty) {
      return '$providerDisplayName | $cleanModelName';
    }
    return cleanModelName;
  }

  Widget _buildModelChip(
    BuildContext context,
    String text,
    LlmUsageSnapshot? contextUsage,
    double? progress,
    Color? progressColor,
  ) {
    final parts = text.split(' | ');
    final provider = parts.length > 1 ? parts[0] : null;
    final model = parts.length > 1 ? parts[1] : text;

    final useTwoLineLayout = provider != null && SidebarBreakpoints.isCompact(context);

    return Container(
      decoration: BoxDecoration(
        color: widget.chipBgColor.withValues(alpha: 0.50),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: widget.borderColor),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            if (progress != null && progressColor != null)
              Positioned.fill(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: progress,
                    child: Container(
                      color: progressColor.withValues(alpha: 0.20),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: useTwoLineLayout ? 2 : 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (contextUsage?.usageFraction != null) ...[
                    ContextUsageIndicator(usage: contextUsage!),
                    const SizedBox(width: 6),
                  ],
                  if (useTwoLineLayout)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          model,
                          style: GoogleFonts.inter(
                            color: widget.dimTextColor,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          provider,
                          style: GoogleFonts.inter(
                            color: widget.dimTextColor.withValues(alpha: 0.7),
                            fontSize: 9,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    )
                  else
                    Text(
                      text,
                      style: GoogleFonts.inter(color: widget.dimTextColor, fontSize: 11),
                    ),
                  const SizedBox(width: 4),
                  Icon(Icons.keyboard_arrow_down, size: 12, color: widget.dimTextColor),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SendStopButton extends StatelessWidget {
  final ConversationInputAgentSlice agentSlice;
  final ConversationInputSlice inputSlice;
  final Capability capabilities;
  final SlashCommandTextController chatController;
  final void Function({MessageDeliveryIntent intent}) onSendAttempt;
  final VoidCallback? onStop;
  final Color dimTextColor;
  final String? sessionId;

  const _SendStopButton({
    required this.agentSlice,
    required this.inputSlice,
    required this.capabilities,
    required this.chatController,
    required this.onSendAttempt,
    required this.onStop,
    required this.dimTextColor,
    this.sessionId,
  });

  @override
  Widget build(BuildContext context) {
    final isEmpty = chatController.exportPlainText().trim().isEmpty;

    final hasWorkspace = !inputSlice.requiresWorkspace || inputSlice.selectedWorkspace != null;
    final canSend = agentSlice.isOnline && !isEmpty && hasWorkspace && inputSlice.pendingSuspendedRequest == null;

    final executionSnapshot = inputSlice.executionSnapshot;
    final isStopping = executionSnapshot?.isStopping ?? false;
    final showStopButton = capabilities.supportsStop && (executionSnapshot?.canStop == true || isStopping) && isEmpty;

    final showVoiceButton =
        capabilities.supportsVoiceCall &&
        agentSlice.hasActiveAgent &&
        agentSlice.isOnline &&
        isEmpty &&
        executionSnapshot?.hasActiveWork != true;

    if (showStopButton) {
      return SizedBox(
        width: 32,
        height: 32,
        child: IconButton(
          key: const Key('stop_message_btn'),
          tooltip: isStopping ? 'Stopping response' : 'Stop response',
          onPressed: isStopping ? null : onStop,
          style: IconButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error.withValues(alpha: 0.1),
            side: BorderSide(
              color: Theme.of(context).colorScheme.error.withValues(alpha: 0.2),
            ),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: EdgeInsets.zero,
          ),
          icon: isStopping
              ? SizedBox(
                  key: const Key('stop_message_progress_indicator'),
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Theme.of(context).colorScheme.error,
                  ),
                )
              : Icon(
                  Icons.stop_circle_outlined,
                  size: 16,
                  color: Theme.of(context).colorScheme.error,
                ),
        ),
      );
    }

    if (inputSlice.isAwaitingMessageAcceptance) {
      return SizedBox(
        width: 32,
        height: 32,
        child: IconButton(
          key: const Key('send_message_acceptance_indicator'),
          tooltip: 'Waiting for message acceptance',
          onPressed: null,
          style: IconButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.onSurface,
            disabledBackgroundColor: Theme.of(context).colorScheme.onSurface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: EdgeInsets.zero,
          ),
          icon: const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.black,
            ),
          ),
        ),
      );
    }

    if (showVoiceButton) {
      return SizedBox(
        width: 32,
        height: 32,
        child: BlocBuilder<VoiceStreamCubit, VoiceStreamState>(
          builder: (context, voiceState) {
            final isActive = voiceState.isSessionActive;
            final isConnecting = voiceState.status == VoiceSessionStatus.connecting;
            return IconButton(
              key: const Key('voice_chat_btn'),
              tooltip: isActive ? 'Stop voice session' : 'Start voice session',
              onPressed: () async {
                final voiceCubit = context.read<VoiceStreamCubit>();
                if (isActive) {
                  await voiceCubit.stopVoiceSession();
                } else {
                  final activeAgent = agentSlice.activeAgent;
                  if (activeAgent != null) {
                    await voiceCubit.startVoiceSession(
                      agent: activeAgent,
                      sessionId: sessionId ?? 'default',
                    );
                  }
                }
              },
              style: IconButton.styleFrom(
                backgroundColor: isActive
                    ? (isConnecting ? Colors.orange.withValues(alpha: 0.1) : Colors.red.withValues(alpha: 0.1))
                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: EdgeInsets.zero,
              ),
              icon: Icon(
                isConnecting ? Icons.hourglass_empty : Symbols.earthquake,
                size: 16,
                color: isActive ? (isConnecting ? Colors.orange : Colors.red) : Theme.of(context).colorScheme.primary,
              ),
            );
          },
        ),
      );
    }

    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        key: const Key('send_message_btn'),
        tooltip: executionSnapshot?.isExecuting == true
            ? 'Press Enter to steer • Ctrl/Cmd+Enter to queue'
            : 'Send message',
        onPressed: canSend ? () => onSendAttempt(intent: MessageDeliveryIntent.auto) : null,
        style: IconButton.styleFrom(
          backgroundColor: canSend ? Theme.of(context).colorScheme.onSurface : dimTextColor.withValues(alpha: 0.1),
          disabledBackgroundColor: dimTextColor.withValues(alpha: 0.1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: EdgeInsets.zero,
        ),
        icon: Icon(
          Icons.arrow_upward_rounded,
          size: 16,
          color: canSend ? Theme.of(context).colorScheme.surface : dimTextColor.withValues(alpha: 0.3),
        ),
      ),
    );
  }
}

class _WorkspaceWarning extends StatelessWidget {
  final VoidCallback onRefresh;

  const _WorkspaceWarning({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onRefresh,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: colorScheme.error.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colorScheme.error.withValues(alpha: 0.18)),
        ),
        child: Row(
          children: [
            Icon(Icons.folder_open_outlined, size: 16, color: colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Select a workspace before your first Sanad Agent message.',
                style: GoogleFonts.inter(
                  color: colorScheme.onSurface,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(Icons.arrow_forward_ios, size: 12, color: colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
