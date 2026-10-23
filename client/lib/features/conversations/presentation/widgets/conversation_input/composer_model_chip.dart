import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/llm_usage_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_state.dart';
import 'package:sanad_client/features/conversations/presentation/utils/provider_route_label.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/context_usage_indicator.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/model_picker_dialog.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_state.dart';

import '../sidebar/sidebar_composition.dart';

/// Model selector chip: the active model label, its usage fill, and the picker.
class ComposerModelChip extends StatefulWidget {
  final ConversationInputAgentSlice agentSlice;
  final ConversationInputSlice inputSlice;
  final Capability capabilities;
  final Color dimTextColor;
  final Color chipBgColor;
  final Color borderColor;

  const ComposerModelChip({
    required this.agentSlice,
    required this.inputSlice,
    required this.capabilities,
    required this.dimTextColor,
    required this.chipBgColor,
    required this.borderColor,
  });

  @override
  State<ComposerModelChip> createState() => _ComposerModelChipState();
}

class _ComposerModelChipState extends State<ComposerModelChip> {
  // (97h) No provider display-name fetch lives in this widget anymore; the
  // resource owner (`ProviderUsageCubit`) resolves `model.snapshot` and
  // `provider.usage.support` once per (device, query) and shares in-flight
  // requests. Widget lifecycle only asks the owner to ensure the logical
  // resource it consumes, which is a no-op when unchanged — rebuild/theme/
  // responsive remounts stay at zero extra Agent requests.
  bool _didSyncInitialResource = false;

  @override
  void initState() {
    super.initState();
    _syncProviderResource();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didSyncInitialResource) return;
    _didSyncInitialResource = true;
    final selectedSession = context.read<SessionCubit>().state.selectedSession;
    _syncProviderResource(selectedSession: selectedSession);
  }

  @override
  void didUpdateWidget(covariant ComposerModelChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    final agentChanged = oldWidget.agentSlice.activeAgent?.id != widget.agentSlice.activeAgent?.id;
    final providerChanged = oldWidget.inputSlice.nextMessageProviderId != widget.inputSlice.nextMessageProviderId;
    if (agentChanged || providerChanged) {
      _syncProviderResource();
    }
  }

  /// Asks the resource owner to ensure the catalog and the active provider's
  /// usage/support are loaded for the current device. The owner dedupes by
  /// (device, query) and shares in-flight requests, so repeated calls from
  /// rebuilds and remounts cost zero Agent requests after the first load.
  void _syncProviderResource({Session? selectedSession}) {
    if (!getIt.isRegistered<ProviderUsageCubit>()) return;
    final cubit = getIt<ProviderUsageCubit>();
    final resolved = selectedSession ?? (mounted ? context.read<SessionCubit>().state.selectedSession : null);
    final activeProviderId = _activeProviderId(resolved);
    if (activeProviderId == null || activeProviderId.isEmpty) return;
    unawaited(cubit.ensureProviderDisplayNames(agent: widget.agentSlice.activeAgent));
    unawaited(
      cubit.ensureInstanceUsage(
        agent: widget.agentSlice.activeAgent,
        instanceId: activeProviderId,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedSession = context.select<SessionCubit, Session?>((cubit) => cubit.state.selectedSession);
    final contextUsage = context.select<SessionMessagesCubit, LlmUsageSnapshot?>(
      (cubit) => latestContextUsage(cubit.state.messages),
    );
    final showProgress = getIt.isRegistered<ProviderUsageCubit>();

    Widget buildChip(
      BuildContext context,
      Map<String, String> providerDisplayNames,
      double? progress,
      Color? progressColor,
    ) {
      final currentModel = _currentModelLabel(
        selectedSession,
        nextMessageModel: widget.inputSlice.nextMessageModel,
        providerDisplayNames: providerDisplayNames,
      );

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
        _syncProviderResource(selectedSession: state.selectedSession);
      },
      child: showProgress
          ? BlocBuilder<ProviderUsageCubit, ProviderUsageState>(
              bloc: getIt<ProviderUsageCubit>(),
              builder: (context, usageState) {
                final theme = Theme.of(context);
                final deviceId = widget.agentSlice.activeAgent?.id ?? getIt<ProviderUsageCubit>().localDeviceId;
                final providerDisplayNames = usageState.displayNamesFor(deviceId);
                final activeProviderId = _activeProviderId(selectedSession);
                double? progress;
                Color? progressColor;

                if (activeProviderId != null && activeProviderId.isNotEmpty) {
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

                return buildChip(context, providerDisplayNames, progress, progressColor);
              },
            )
          : Builder(
              builder: (context) => buildChip(context, const {}, null, null),
            ),
    );
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

