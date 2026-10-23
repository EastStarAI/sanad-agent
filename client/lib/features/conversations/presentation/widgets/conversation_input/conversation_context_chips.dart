import 'dart:async';

import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/presentation/utils/device_ui_mapper.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/composer_workspace_chip.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

class ConversationContextChips extends StatelessWidget {
  final GlobalKey<PopupMenuButtonState<String>> agentSelectorKey;
  final ConversationInputAgentSlice agentSlice;
  final ConversationInputSlice inputSlice;
  final Capability capabilities;
  final String? sessionId;
  final Color inputBgColor;
  final Color chipBgColor;
  final Color borderColor;
  final Color dimTextColor;
  final Future<void> Function(DeviceConfig? activeAgent) onPickAndCreateWorkspace;

  const ConversationContextChips({
    super.key,
    required this.agentSelectorKey,
    required this.agentSlice,
    required this.inputSlice,
    required this.capabilities,
    required this.sessionId,
    required this.inputBgColor,
    required this.chipBgColor,
    required this.borderColor,
    required this.dimTextColor,
    required this.onPickAndCreateWorkspace,
  });

  @override
  Widget build(BuildContext context) {
    final agents = agentSlice.agents;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          agents.isEmpty ? _buildNoAgentsFoundChip(context) : _buildAgentSelectorChip(context),
          if (capabilities.supportsWorkspaces || capabilities.workspaceRequired) ...[
            const SizedBox(width: 8),
            ComposerWorkspaceChip(
              availableWorkspaces: inputSlice.availableWorkspaces,
              selectedWorkspace: inputSlice.selectedWorkspace,
              isLoadingWorkspaces: inputSlice.isLoadingWorkspaces,
              requiresWorkspace: inputSlice.requiresWorkspace,
              hasActiveAgent: agentSlice.hasActiveAgent,
              isLocked: sessionId != null && sessionId!.isNotEmpty && inputSlice.selectedWorkspace != null,
              chipBgColor: chipBgColor,
              borderColor: borderColor,
              dimTextColor: dimTextColor,
              onRefreshWorkspaces: () => unawaited(context.read<ConversationInputCubit>().refreshWorkspaces()),
              onWorkspaceSelected: (workspace) => context.read<ConversationInputCubit>().selectWorkspace(workspace),
              onWorkspaceCleared: () => context.read<ConversationInputCubit>().clearWorkspace(),
              onAddNewWorkspace: () => unawaited(onPickAndCreateWorkspace(agentSlice.activeAgent)),
            ),
          ],
          const SizedBox(width: 8),
          // todo : will be implemented in future
          // _buildChip(
          //   context,
          //   Icons.account_tree_outlined,
          //   'main',
          //   trailing: Container(
          //     width: 12,
          //     height: 12,
          //     margin: const EdgeInsets.only(left: 6),
          //     decoration: BoxDecoration(
          //       color: dimTextColor.withValues(alpha: 0.5),
          //       borderRadius: BorderRadius.circular(2),
          //     ),
          //   ),
          // ),
          // const SizedBox(width: 8),
          // _buildIconButton(Icons.add),
        ],
      ),
    );
  }

  Widget _buildNoAgentsFoundChip(BuildContext context) {
    return GestureDetector(
      onTap: () {
        unawaited(context.push(AppRoutes.settings));
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: chipBgColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Theme.of(context).colorScheme.error.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded, size: 13, color: Theme.of(context).colorScheme.tertiary),
            const SizedBox(width: 6),
            Text(
              'No Agents Found',
              style: GoogleFonts.inter(
                color: Theme.of(context).colorScheme.error.withValues(alpha: 0.8),
                fontSize: 12,
                fontWeight: FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAgentSelectorChip(BuildContext context) {
    final activeAgent = agentSlice.activeAgent;
    final agents = agentSlice.agents;

    return PopupMenuButton<String>(
      key: agentSelectorKey,
      tooltip: 'Select Device',
      offset: const Offset(0, 32),
      color: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: borderColor),
      ),
      onSelected: (value) {
        if (value == 'manage') {
          unawaited(context.push(AppRoutes.settings));
        } else {
          final selectedAgent = _agentById(agents, value);
          if (selectedAgent == null) return;
          unawaited(context.read<SessionCubit>().startNewChat(selectedAgent));
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: chipBgColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            activeAgent == null
                ? Icon(Icons.smart_toy, size: 13, color: dimTextColor)
                : activeAgent.buildIcon(context, size: 13),
            const SizedBox(width: 6),
            Text(
              activeAgent?.name ?? 'Select Device',
              style: GoogleFonts.inter(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.8),
                fontSize: 12,
                fontWeight: FontWeight.w400,
              ),
            ),
            if (activeAgent != null && activeAgent.isOnline) ...[
              const SizedBox(width: 6),
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(
                  color: Colors.green,
                  shape: BoxShape.circle,
                ),
              ),
            ],
            if (activeAgent?.isLocalReachable == true) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'local',
                  style: GoogleFonts.inter(
                    color: Theme.of(context).colorScheme.secondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 2),
            Icon(Icons.keyboard_arrow_down, size: 13, color: dimTextColor),
          ],
        ),
      ),
      itemBuilder: (context) {
        return [
          ...agents.map((agent) {
            final isSelected = agent.id == activeAgent?.id;
            return PopupMenuItem<String>(
              value: agent.id,
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  agent.buildIcon(context, size: 14),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      agent.name,
                      style: TextStyle(
                        color: isSelected
                            ? Theme.of(context).colorScheme.onSurface
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (agent.isOnline) ...[
                    const SizedBox(width: 6),
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: Colors.green,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                  if (agent.isLocalReachable) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'local',
                        style: GoogleFonts.inter(
                          color: Theme.of(context).colorScheme.secondary,
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                  if (isSelected) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.check, size: 12, color: Theme.of(context).colorScheme.primary),
                  ],
                ],
              ),
            );
          }),
          PopupMenuDivider(height: 1, color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.1)),
          PopupMenuItem<String>(
            value: 'manage',
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(Icons.settings_outlined, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  'Manage Agents',
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
                ),
              ],
            ),
          ),
        ];
      },
    );
  }

  DeviceConfig? _agentById(List<DeviceConfig> agents, String id) {
    for (final agent in agents) {
      if (agent.id == id) return agent;
    }
    return null;
  }

  // Widget _buildIconButton(IconData icon, {double size = 16}) {
  //   return Container(
  //     padding: const EdgeInsets.all(5),
  //     decoration: BoxDecoration(
  //       color: chipBgColor,
  //       borderRadius: BorderRadius.circular(6),
  //       border: Border.all(color: borderColor),
  //     ),
  //     child: Icon(icon, size: size, color: dimTextColor),
  //   );
  // }
}
