import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:sanad_client/core/config/app_config.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/devices/domain/models/gateway_connection_status.dart';
import 'package:sanad_client/features/devices/presentation/bloc/gateway_connection_cubit.dart';
import 'package:sanad_client/utils/app_platform.dart';

class DesktopOnlyStatusBar extends StatelessWidget {
  final Widget child;

  const DesktopOnlyStatusBar({
    super.key,
    this.child = const StatusBar(),
  });

  @override
  Widget build(BuildContext context) {
    if (!AppPlatform.isDesktop) return const SizedBox.shrink();
    return child;
  }
}

class StatusBar extends StatelessWidget {
  final String worktreeName;
  final String worktreeBranch;

  const StatusBar({
    super.key,
    this.worktreeName = AppConfig.sanadDevWorktreeName,
    this.worktreeBranch = AppConfig.sanadDevWorktreeBranch,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return BlocBuilder<GatewayConnectionCubit, GatewayConnectionStatus>(
      builder: (context, status) {
        final bool isConnected = status.isLocalConnected || status.isCloudReady;
        final bool hasError =
            status.localGateway == LocalGatewayStatus.needsRepair ||
            (status.localGateway == LocalGatewayStatus.disconnected && status.isDesktop);

        final Color backgroundColor = hasError
            ? (isDark ? const Color(0xFFC74E3E) : const Color(0xFFD32F2F))
            : isConnected
            ? (isDark ? const Color(0xFF2D2D2D) : theme.colorScheme.surfaceContainerHighest)
            : (isDark ? const Color(0xFF007ACC) : const Color(0xFF005FB8));

        final Color foregroundColor = hasError
            ? Colors.white
            : isConnected
            ? (isDark ? Colors.white70 : theme.colorScheme.onSurface)
            : Colors.white;

        return Container(
          height: 24,
          color: backgroundColor,
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    _GatewayStatusButton(
                      status: status,
                      foregroundColor: foregroundColor,
                    ),
                    if (worktreeName.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      Flexible(
                        child: WorktreeRuntimeBadge(
                          worktreeName: worktreeName,
                          branch: worktreeBranch,
                          foregroundColor: foregroundColor,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // Right side: environment details (VS Code style placeholders)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    // if (status.isDesktop) ...[
                    //   Icon(Icons.computer, size: 12, color: foregroundColor),
                    //   const SizedBox(width: 4),
                    //   Text(
                    //     'Desktop Mode',
                    //     style: TextStyle(
                    //       fontSize: 11,
                    //       color: foregroundColor,
                    //       fontWeight: FontWeight.w500,
                    //     ),
                    //   ),
                    //   const SizedBox(width: 12),
                    // ],
                    Icon(Icons.bolt, size: 12, color: foregroundColor),
                    const SizedBox(width: 4),
                    Text(
                      'SanadAgent',
                      style: TextStyle(
                        fontSize: 11,
                        color: foregroundColor,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class WorktreeRuntimeBadge extends StatelessWidget {
  final String worktreeName;
  final String branch;
  final Color foregroundColor;

  const WorktreeRuntimeBadge({
    super.key,
    required this.worktreeName,
    required this.branch,
    required this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final tooltip = branch.isEmpty
        ? 'Isolated worktree: $worktreeName'
        : 'Isolated worktree: $worktreeName\nBranch: $branch';

    return Tooltip(
      message: tooltip,
      child: Semantics(
        label: tooltip,
        child: Container(
          key: const Key('worktree_runtime_badge'),
          constraints: const BoxConstraints(maxWidth: 240),
          height: 20,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: foregroundColor.withAlpha(24),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: foregroundColor.withAlpha(72)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.account_tree_outlined, size: 12, color: foregroundColor),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  worktreeName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foregroundColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GatewayStatusButton extends StatelessWidget {
  final GatewayConnectionStatus status;
  final Color foregroundColor;

  const _GatewayStatusButton({
    required this.status,
    required this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    // Dynamically calculate popup height to offset it perfectly above the status bar
    // 16dp padding + 2 items of 28dp each + (1 divider of 8dp) + (n actions * 28dp each)
    final double menuHeight = 16.0 + 56.0 + (status.actions.isNotEmpty ? 8.0 : 0.0) + (status.actions.length * 28.0);

    return PopupMenuButton<GatewayConnectionAction>(
      tooltip: 'Gateway connection status and actions',
      onSelected: (action) => _handleAction(context, action),
      offset: Offset(0, -menuHeight), // Perfectly aligned above the status bar
      constraints: const BoxConstraints(
        minWidth: 200,
        maxWidth: 240,
      ),
      itemBuilder: (context) => [
        PopupMenuItem<GatewayConnectionAction>(
          enabled: false,
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _GatewayStatusRow(
            label: 'Local Gateway',
            value: status.localGateway.displayLabel,
            connected: status.localGateway == LocalGatewayStatus.connected,
          ),
        ),
        PopupMenuItem<GatewayConnectionAction>(
          enabled: false,
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _GatewayStatusRow(
            label: 'Sanad Cloud Gateway',
            value: status.sanadGateway.displayLabel,
            connected:
                status.sanadGateway == SanadGatewayStatus.connected ||
                status.sanadGateway == SanadGatewayStatus.authenticatedWithDevices,
          ),
        ),
        if (status.actions.isNotEmpty) ...[
          const PopupMenuDivider(height: 8),
          ...status.actions.map(
            (action) => PopupMenuItem<GatewayConnectionAction>(
              value: action,
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                action.label,
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
        ],
      ],
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          height: 24,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                status.isLocalConnected || status.isCloudReady ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                size: 13,
                color: foregroundColor,
              ),
              const SizedBox(width: 6),
              Text(
                status.summary,
                style: TextStyle(
                  color: foregroundColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.arrow_drop_up,
                size: 14,
                color: foregroundColor,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _handleAction(BuildContext context, GatewayConnectionAction action) {
    switch (action) {
      case GatewayConnectionAction.signIn:
        unawaited(context.read<AuthCubit>().login());
      case GatewayConnectionAction.retryCloud:
        unawaited(context.read<GatewayConnectionCubit>().retryCloudGateway());
      case GatewayConnectionAction.startLocalAgent:
      case GatewayConnectionAction.repairLocalAgent:
        unawaited(context.read<GatewayConnectionCubit>().startLocalGateway());
      case GatewayConnectionAction.restartLocalAgent:
        unawaited(context.read<GatewayConnectionCubit>().restartLocalGateway());
      case GatewayConnectionAction.stopLocalAgent:
        unawaited(context.read<GatewayConnectionCubit>().stopLocalGateway());
      case GatewayConnectionAction.addDevice:
        unawaited(context.push(AppRoutes.addAgent));
    }
  }
}

class _GatewayStatusRow extends StatelessWidget {
  final String label;
  final String value;
  final bool connected;

  const _GatewayStatusRow({
    required this.label,
    required this.value,
    required this.connected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(
          connected ? Icons.check_circle : Icons.radio_button_unchecked,
          size: 13,
          color: connected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: theme.colorScheme.onSurface,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: theme.colorScheme.onSurfaceVariant,
            fontSize: 10,
          ),
        ),
      ],
    );
  }
}

extension _GatewayConnectionActionLabel on GatewayConnectionAction {
  String get label {
    return switch (this) {
      GatewayConnectionAction.signIn => 'Sign in',
      GatewayConnectionAction.retryCloud => 'Retry cloud connection',
      GatewayConnectionAction.startLocalAgent => 'Start local agent',
      GatewayConnectionAction.repairLocalAgent => 'Repair local agent',
      GatewayConnectionAction.restartLocalAgent => 'Restart local agent',
      GatewayConnectionAction.stopLocalAgent => 'Stop local agent',
      GatewayConnectionAction.addDevice => 'Add device',
    };
  }
}
