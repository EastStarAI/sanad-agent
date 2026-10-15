import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/repositories/conversation_repository.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/full_access_confirmation_dialog.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/utils/toast_utils.dart';

/// Settings card for viewing and configuring Workspace security policies:
/// Execution backend (Direct vs Protected), Host capability discovery, and Permission mode.
///
/// Under Plan 83 (Task 83h / Gate H2), settings are authoritative to the daemon state
/// database and apply to subsequent executions in the same session.
class WorkspaceSecurityCard extends StatefulWidget {
  final DeviceConfig device;
  final DeviceWorkspace workspace;

  const WorkspaceSecurityCard({
    super.key,
    required this.device,
    required this.workspace,
  });

  @override
  State<WorkspaceSecurityCard> createState() => _WorkspaceSecurityCardState();
}

class _WorkspaceSecurityCardState extends State<WorkspaceSecurityCard> {
  WorkspacePolicy? _policy;
  bool _isLoading = true;
  bool _isSaving = false;
  String? _errorMessage;
  StreamSubscription<WorkspacePolicy>? _policySubscription;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPolicy());
    _subscribePolicy();
  }

  @override
  void didUpdateWidget(covariant WorkspaceSecurityCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspace.id != widget.workspace.id ||
        oldWidget.device.id != widget.device.id) {
      unawaited(_policySubscription?.cancel());
      unawaited(_loadPolicy());
      _subscribePolicy();
    }
  }

  @override
  void dispose() {
    unawaited(_policySubscription?.cancel());
    super.dispose();
  }

  void _subscribePolicy() {
    if (!getIt.isRegistered<ConversationRepository>()) return;
    final repo = getIt<ConversationRepository>();
    _policySubscription = repo
        .watchWorkspacePolicy(widget.device, widget.workspace.id)
        .listen((policy) {
      if (mounted) {
        setState(() {
          _policy = policy;
          _isLoading = false;
        });
      }
    });
  }

  Future<void> _loadPolicy() async {
    if (!getIt.isRegistered<ConversationRepository>()) {
      setState(() {
        _isLoading = false;
        _policy = const WorkspacePolicy();
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final repo = getIt<ConversationRepository>();
      final policy = await repo.getWorkspacePolicy(
        widget.device,
        widget.workspace.path,
      );
      if (mounted) {
        setState(() {
          _policy = policy;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _updatePolicy({
    WorkspacePermissionMode? permissionMode,
    ExecutionMode? executionMode,
    HostDiscoveryPolicy? hostDiscoveryPolicy,
  }) async {
    final current = _policy;
    if (current == null || _isSaving) return;

    if (permissionMode == WorkspacePermissionMode.fullAccess &&
        current.permissionMode != WorkspacePermissionMode.fullAccess) {
      final confirmed = await FullAccessConfirmationDialog.show(context);
      if (!confirmed || !mounted) return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final repo = getIt<ConversationRepository>();
      final updated = await repo.setWorkspaceSecurityPolicy(
        widget.device,
        workspaceId: widget.workspace.id,
        workspacePath: widget.workspace.path,
        permissionMode: permissionMode,
        executionMode: executionMode,
        hostDiscoveryPolicy: hostDiscoveryPolicy,
        expectedRevision: current.revision,
      );

      if (mounted) {
        setState(() {
          _policy = updated;
          _isSaving = false;
        });
        ToastUtils.showSuccess(context, 'Security policy updated.');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
        ToastUtils.showError(
          context,
          'Could not update security policy: $e',
        );
        unawaited(_loadPolicy());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (_isLoading) {
      return Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colorScheme.outline.withValues(alpha: 0.2)),
        ),
        child: const Padding(
          padding: EdgeInsets.all(24),
          child: Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }

    if (_errorMessage != null) {
      return Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: colorScheme.error.withValues(alpha: 0.3)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: colorScheme.error),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  _errorMessage!,
                  style: TextStyle(color: colorScheme.error, fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: _loadPolicy,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final policy = _policy ?? const WorkspacePolicy();
    final isEditable = policy.editableByOwner && !_isSaving;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.shield_outlined,
                  size: 20,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Workspace Security & Execution',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (_isSaving)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Authoritative policy settings applied by the daemon for this workspace.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            if (!policy.editableByOwner) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.lock_outline,
                      size: 16,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Only the device owner can modify these security settings.',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const Divider(height: 28),

            // 1. Execution Backend
            Text(
              'Execution Backend',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Controls command execution containment.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SegmentedButton<ExecutionMode>(
              key: const Key('execution_mode_selector'),
              segments: const [
                ButtonSegment(
                  value: ExecutionMode.direct,
                  icon: Icon(Icons.code_outlined, size: 16),
                  label: Text('Direct Developer'),
                ),
                ButtonSegment(
                  value: ExecutionMode.protected,
                  icon: Icon(Icons.security_outlined, size: 16),
                  label: Text('Protected'),
                ),
              ],
              selected: {policy.executionMode},
              onSelectionChanged: isEditable
                  ? (selection) {
                      if (selection.isNotEmpty &&
                          selection.first != policy.executionMode) {
                        unawaited(_updatePolicy(executionMode: selection.first));
                      }
                    }
                  : null,
            ),
            const SizedBox(height: 6),
            Text(
              policy.executionMode == ExecutionMode.direct
                  ? 'Runs commands directly on the host using your local developer tools (FVM, Flutter, Java, Git, etc.).'
                  : 'Runs commands in an isolated environment without host tool access.',
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const Divider(height: 28),

            // 2. Host Capability Discovery
            Text(
              'Host Capability Discovery',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Controls executable visibility on the host PATH. Does not grant execution.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SegmentedButton<HostDiscoveryPolicy>(
              key: const Key('host_discovery_policy_selector'),
              segments: const [
                ButtonSegment(
                  value: HostDiscoveryPolicy.ownerOnly,
                  icon: Icon(Icons.visibility_outlined, size: 16),
                  label: Text('Owner Only'),
                ),
                ButtonSegment(
                  value: HostDiscoveryPolicy.disabled,
                  icon: Icon(Icons.visibility_off_outlined, size: 16),
                  label: Text('Disabled'),
                ),
              ],
              selected: {policy.hostDiscoveryPolicy},
              onSelectionChanged: isEditable
                  ? (selection) {
                      if (selection.isNotEmpty &&
                          selection.first != policy.hostDiscoveryPolicy) {
                        unawaited(_updatePolicy(hostDiscoveryPolicy: selection.first));
                      }
                    }
                  : null,
            ),
            const SizedBox(height: 6),
            Text(
              policy.hostDiscoveryPolicy == HostDiscoveryPolicy.ownerOnly
                  ? 'Permits inspecting whether specific tools exist on host PATH for the owner session.'
                  : 'Host tool discovery is completely disabled for this workspace.',
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const Divider(height: 28),

            // 3. Permission Mode
            Text(
              'Permission Mode',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Controls interactive confirmation prompts for privileged tool actions.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SegmentedButton<WorkspacePermissionMode>(
              key: const Key('permission_mode_selector'),
              segments: const [
                ButtonSegment(
                  value: WorkspacePermissionMode.defaultMode,
                  icon: Icon(Icons.check_circle_outline, size: 16),
                  label: Text('Default'),
                ),
                ButtonSegment(
                  value: WorkspacePermissionMode.fullAccess,
                  icon: Icon(Icons.bolt_outlined, size: 16),
                  label: Text('Full Access'),
                ),
              ],
              selected: {policy.permissionMode},
              onSelectionChanged: isEditable
                  ? (selection) {
                      if (selection.isNotEmpty &&
                          selection.first != policy.permissionMode) {
                        unawaited(_updatePolicy(permissionMode: selection.first));
                      }
                    }
                  : null,
            ),
            const SizedBox(height: 6),
            Text(
              policy.permissionMode == WorkspacePermissionMode.defaultMode
                  ? 'Asks for approval before running privileged tools.'
                  : 'Runs tools in this workspace without asking before each operation.',
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
