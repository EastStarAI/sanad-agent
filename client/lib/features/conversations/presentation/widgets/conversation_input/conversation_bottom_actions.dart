import 'dart:async';

import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_state.dart';
import 'package:sanad_client/features/conversations/presentation/utils/provider_route_label.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/model_picker_dialog.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';

class ConversationBottomActions extends StatefulWidget {
  final DeviceConfig? activeAgent;
  final ConversationInputSlice inputSlice;
  final Capability capabilities;
  final Color dimTextColor;
  final Color chipBgColor;
  final Color borderColor;
  final Future<bool> Function() onConfirmFullAccess;

  const ConversationBottomActions({
    super.key,
    required this.activeAgent,
    required this.inputSlice,
    required this.capabilities,
    required this.dimTextColor,
    required this.chipBgColor,
    required this.borderColor,
    required this.onConfirmFullAccess,
  });

  @override
  State<ConversationBottomActions> createState() => _ConversationBottomActionsState();
}

class _ConversationBottomActionsState extends State<ConversationBottomActions> {
  static const Duration _emptyProviderDisplayRetryCooldown = Duration(
    seconds: 30,
  );

  final Map<String, Map<String, String>> _providerDisplayNamesByAgent = {};
  final Set<String> _providerDisplayLoadsInFlight = <String>{};
  final Set<String> _providerDisplayLookupAttempts = <String>{};
  final Map<String, DateTime> _emptyProviderDisplayFetchUntilByAgent = {};
  bool _didLoadInitialProviderDisplayNames = false;

  @override
  void initState() {
    super.initState();
    unawaited(_ensureProviderDisplayNamesLoaded());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didLoadInitialProviderDisplayNames) {
      return;
    }
    _didLoadInitialProviderDisplayNames = true;
    final selectedSession = context.read<SessionCubit>().state.selectedSession;
    unawaited(_ensureProviderDisplayNamesLoaded(selectedSession: selectedSession));
  }

  @override
  void didUpdateWidget(covariant ConversationBottomActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    final agentChanged = oldWidget.activeAgent?.id != widget.activeAgent?.id;
    final providerChanged = oldWidget.inputSlice.nextMessageProviderId != widget.inputSlice.nextMessageProviderId;
    if (agentChanged || providerChanged) {
      _providerDisplayLookupAttempts.clear();
      unawaited(_ensureProviderDisplayNamesLoaded());
    }
  }

  @override
  Widget build(BuildContext context) {
    final capabilities = widget.capabilities;
    final inputSlice = widget.inputSlice;
    return Row(
      children: [
        if (capabilities.supportsToolPermissions && inputSlice.selectedWorkspace != null)
          _buildPermissionModeSelector(context),
        const SizedBox(width: 16),
        if (capabilities.supportsAttachments) ...[
          const SizedBox(width: 12),
          _buildSmallIcon(Icons.add),
        ],
        if (capabilities.supportsVoiceMessage) ...[
          const SizedBox(width: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildSmallIcon(Icons.mic_none_outlined),
              Icon(Icons.keyboard_arrow_down, size: 14, color: widget.dimTextColor.withValues(alpha: 0.5)),
            ],
          ),
        ],
        const Spacer(),
        if (capabilities.supportsModelChange) ...[
          const SizedBox(width: 12),
          _buildModelSelector(context),
        ],
        if (capabilities.supportsThinkingModeChange) ...[
          const SizedBox(width: 12),
          _buildThinkingModeSelector(context),
        ],
      ],
    );
  }

  Widget _buildModelSelector(BuildContext context) {
    final selectedSession = context.select<SessionCubit, Session?>((cubit) => cubit.state.selectedSession);
    final providerDisplayNames =
        _providerDisplayNamesByAgent[_providerLookupKey(widget.activeAgent)] ?? const <String, String>{};

    final currentModel = _currentModelLabel(
      selectedSession,
      nextMessageModel: widget.inputSlice.nextMessageModel,
      providerDisplayNames: providerDisplayNames,
    );
    return BlocListener<SessionCubit, SessionState>(
      listenWhen: (previous, current) => previous.selectedSession != current.selectedSession,
      listener: (context, state) {
        _providerDisplayLookupAttempts.clear();
        unawaited(_ensureProviderDisplayNamesLoaded(selectedSession: state.selectedSession));
      },
      child: InkWell(
        onTap: () => _openModelPicker(context),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildActionText(currentModel),
              const SizedBox(width: 2),
              Icon(Icons.keyboard_arrow_down, size: 14, color: widget.dimTextColor.withValues(alpha: 0.5)),
            ],
          ),
        ),
      ),
    );
  }

  String _providerLookupKey(DeviceConfig? agent) => agent?.id ?? '__local__';

  String _providerDisplayLookupAttemptKey(String agentKey, String providerId) => '$agentKey::$providerId';

  Future<void> _ensureProviderDisplayNamesLoaded({Session? selectedSession}) async {
    final key = _providerLookupKey(widget.activeAgent);
    final activeProviderId = _activeProviderId(selectedSession);
    if (activeProviderId == null || activeProviderId.isEmpty) {
      return;
    }

    final knownDisplays = _providerDisplayNamesByAgent[key];
    if (knownDisplays != null && knownDisplays.isNotEmpty && knownDisplays.containsKey(activeProviderId)) {
      return;
    }

    final retryAfter = _emptyProviderDisplayFetchUntilByAgent[key];
    if (retryAfter != null && DateTime.now().isBefore(retryAfter)) {
      return;
    }
    if (_providerDisplayLoadsInFlight.contains(key)) {
      return;
    }

    final attemptKey = _providerDisplayLookupAttemptKey(key, activeProviderId);
    if (_providerDisplayLookupAttempts.contains(attemptKey)) {
      return;
    }
    _providerDisplayLookupAttempts.add(attemptKey);
    _providerDisplayLoadsInFlight.add(key);
    try {
      final client = getIt<ProviderSetupClient>();
      final names = <String, String>{};

      final snapshot = await client.modelSnapshot(agent: widget.activeAgent);
      for (final instance in snapshot.instances) {
        final id = instance.id.trim();
        final displayName = instance.displayName.trim();
        if (id.isNotEmpty && displayName.isNotEmpty) {
          names[id] = displayName;
        }
      }

      if (names.isEmpty) {
        final instances = await client.listInstances(agent: widget.activeAgent);
        for (final instance in instances) {
          final id = instance.id.trim();
          final displayName = instance.displayName.trim();
          if (id.isNotEmpty && displayName.isNotEmpty) {
            names[id] = displayName;
          }
        }
      }

      if (!mounted) {
        return;
      }

      final previousNames = _providerDisplayNamesByAgent[key] ?? const <String, String>{};
      if (names.isEmpty) {
        _emptyProviderDisplayFetchUntilByAgent[key] = DateTime.now().add(
          _emptyProviderDisplayRetryCooldown,
        );
        _providerDisplayLookupAttempts.remove(attemptKey);
        if (previousNames.isEmpty) {
          return;
        }
      } else if (_sameProviderDisplayNames(previousNames, names)) {
        return;
      }

      setState(() {
        _providerDisplayNamesByAgent[key] = names;
        if (names.isNotEmpty) {
          _emptyProviderDisplayFetchUntilByAgent.remove(key);
        }
      });
    } catch (_) {
      _providerDisplayLookupAttempts.remove(attemptKey);
      // Keep the chip functional even if the provider-name lookup fails.
    } finally {
      _providerDisplayLoadsInFlight.remove(key);
    }
  }

  bool _sameProviderDisplayNames(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) {
      return false;
    }
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }

  void _openModelPicker(BuildContext context) {
    final selectedSession = context.read<SessionCubit>().state.selectedSession;

    String? activeModelId = widget.inputSlice.nextMessageModel?.trim();
    if (activeModelId == null || activeModelId.isEmpty) {
      activeModelId = selectedSession?.model?.trim();
    }

    String? activeProviderId = widget.inputSlice.nextMessageProviderId?.trim();
    if (activeProviderId == null || activeProviderId.isEmpty) {
      activeProviderId = selectedSession?.modelProvider?.trim();
    }

    unawaited(
      showDialog(
        context: context,
        builder: (dialogContext) => ModelPickerDialog(
          agent: widget.activeAgent,
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
                agent: widget.activeAgent,
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildThinkingModeSelector(BuildContext context) {
    final selectedSession = context.select<SessionCubit, Session?>((cubit) => cubit.state.selectedSession);
    final currentMode = _currentThinkingModeLabel(
      selectedSession,
      nextMessageThinkingMode: widget.inputSlice.nextMessageThinkingMode,
    );
    return PopupMenuButton<String>(
      tooltip: 'Select Thinking Mode',
      child: _buildActionText(currentMode),
      itemBuilder: (context) => widget.capabilities.thinkingModesList
          .map(
            (m) => PopupMenuItem(
              value: m,
              height: 32,
              child: Text(m, style: const TextStyle(fontSize: 12)),
            ),
          )
          .toList(),
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

  Widget _buildPermissionModeSelector(BuildContext context) {
    final isLoading = widget.inputSlice.isLoadingPermissionMode;
    final label = isLoading ? 'Loading...' : _permissionModeLabel(widget.inputSlice.permissionMode);

    return PopupMenuButton<WorkspacePermissionMode>(
      tooltip: 'Select Permission Mode',
      enabled: !isLoading,
      child: _buildActionText(label),
      itemBuilder: (context) => WorkspacePermissionMode.values
          .map(
            (mode) => PopupMenuItem<WorkspacePermissionMode>(
              value: mode,
              height: 40,
              child: Row(
                children: [
                  Icon(
                    widget.inputSlice.permissionMode == mode ? Icons.check : Icons.shield_outlined,
                    size: 16,
                    color: widget.inputSlice.permissionMode == mode
                        ? Theme.of(context).colorScheme.primary
                        : widget.dimTextColor,
                  ),
                  const SizedBox(width: 8),
                  Text(_permissionModeLabel(mode), style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          )
          .toList(),
      onSelected: (mode) async {
        if (mode == widget.inputSlice.permissionMode) {
          return;
        }

        if (mode == WorkspacePermissionMode.fullAccess) {
          final confirmed = await widget.onConfirmFullAccess();
          if (!context.mounted || !confirmed) {
            return;
          }
        }

        if (!context.mounted) {
          return;
        }

        await context.read<ConversationInputCubit>().setWorkspacePermissionMode(mode);
      },
    );
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

    if (activeModelId == null || activeModelId.isEmpty) {
      return _firstModelLabel();
    }

    var cleanModelName = activeModelId;
    if (activeProviderId != null && activeProviderId.isNotEmpty) {
      final prefix = '${activeProviderId.toLowerCase()}/';
      if (cleanModelName.toLowerCase().startsWith(prefix)) {
        cleanModelName = cleanModelName.substring(prefix.length);
      }
    }
    if (cleanModelName.contains('/')) {
      cleanModelName = cleanModelName.split('/').last;
    }

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

  String? _activeProviderId(Session? session) {
    final nextProviderId = widget.inputSlice.nextMessageProviderId?.trim();
    if (nextProviderId != null && nextProviderId.isNotEmpty) {
      return nextProviderId;
    }

    final sessionProvider = session?.modelProvider?.trim();
    if (sessionProvider != null && sessionProvider.isNotEmpty) {
      return sessionProvider;
    }

    final metadataProvider = session?.metadata?['provider']?.toString().trim();
    if (metadataProvider != null && metadataProvider.isNotEmpty) {
      return metadataProvider;
    }

    final metadataModelProvider = session?.metadata?['model_provider']?.toString().trim();
    if (metadataModelProvider != null && metadataModelProvider.isNotEmpty) {
      return metadataModelProvider;
    }

    return null;
  }

  String _currentThinkingModeLabel(
    Session? session, {
    String? nextMessageThinkingMode,
  }) {
    if (widget.capabilities.thinkingModeScope == CapabilityValueScope.message) {
      final mode = nextMessageThinkingMode?.trim();
      if (mode != null && mode.isNotEmpty) {
        return mode;
      }
      return _firstThinkingMode();
    }

    final mode = session?.thinkingMode;
    if (mode != null && mode.isNotEmpty) {
      return mode;
    }

    final savedMode = nextMessageThinkingMode?.trim();
    if (savedMode != null && savedMode.isNotEmpty) {
      return savedMode;
    }

    return _firstThinkingMode();
  }

  String _firstModelLabel() {
    return 'Select model';
  }

  String _firstThinkingMode() {
    if (widget.capabilities.thinkingModesList.isEmpty) {
      return 'balanced';
    }
    return widget.capabilities.thinkingModesList.first;
  }

  String _permissionModeLabel(WorkspacePermissionMode mode) {
    switch (mode) {
      case WorkspacePermissionMode.defaultMode:
        return 'Default';
      case WorkspacePermissionMode.fullAccess:
        return 'Full Access';
    }
  }

  Widget _buildActionText(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: widget.chipBgColor,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: widget.borderColor),
      ),
      child: Text(
        text,
        style: GoogleFonts.inter(color: widget.dimTextColor, fontSize: 11),
      ),
    );
  }

  Widget _buildSmallIcon(IconData icon) {
    return Icon(icon, size: 18, color: widget.dimTextColor);
  }
}
