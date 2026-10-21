import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sanad_client/features/devices/data/device_command_client.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/settings/data/workspace_security_client.dart';
import 'package:sanad_client/features/settings/presentation/widgets/settings_widgets.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/utils/toast_utils.dart';

/// Workspace execution and host-discovery controls.
///
/// Shows the Agent's stored policy and sends one explicit mutation per
/// change with the revision on screen. The Agent decides what this
/// connection may loosen; choices it would reject are disabled, and any
/// rejection or stale revision reloads the Agent's current truth.
class WorkspaceSecurityCard extends StatefulWidget {
  const WorkspaceSecurityCard({
    super.key,
    required this.device,
    required this.workspaceId,
    required this.client,
  });

  final DeviceConfig device;
  final String workspaceId;
  final WorkspaceSecurityClient client;

  @override
  State<WorkspaceSecurityCard> createState() => _WorkspaceSecurityCardState();
}

class _WorkspaceSecurityCardState extends State<WorkspaceSecurityCard> {
  WorkspacePolicy? _policy;
  bool _loadFailed = false;
  bool _saving = false;
  StreamSubscription<WorkspacePolicy>? _changes;

  @override
  void initState() {
    super.initState();
    _watch();
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  /// Follows changes made elsewhere (another client or the CLI). The
  /// broadcast has no `canWiden`, so the last read answer is kept.
  void _watch() {
    unawaited(_changes?.cancel());
    _changes = widget.client
        .watch(widget.device, widget.workspaceId)
        .listen(
          (policy) {
            if (!mounted) return;
            setState(
              () => _policy = policy.copyWith(
                canWiden: _policy?.canWiden ?? false,
              ),
            );
          },
          onError: (_) {},
        );
  }

  @override
  void didUpdateWidget(WorkspaceSecurityCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspaceId != widget.workspaceId ||
        oldWidget.device.id != widget.device.id) {
      _watch();
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    setState(() => _loadFailed = false);
    try {
      final policy = await widget.client.read(widget.device, widget.workspaceId);
      if (!mounted) return;
      setState(() => _policy = policy);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadFailed = true);
    }
  }

  Future<void> _update({
    WorkspaceExecutionMode? executionMode,
    WorkspaceHostDiscoveryPolicy? hostDiscoveryPolicy,
  }) async {
    final current = _policy;
    if (current == null || _saving) return;
    setState(() => _saving = true);
    try {
      final updated = await widget.client.update(
        widget.device,
        widget.workspaceId,
        expectedRevision: current.revision,
        executionMode: executionMode,
        hostDiscoveryPolicy: hostDiscoveryPolicy,
      );
      if (!mounted) return;
      setState(() => _policy = updated);
    } catch (error) {
      if (!mounted) return;
      ToastUtils.showError(
        context,
        error is DeviceCommandException && error.code == 'stale_revision'
            ? AppLocalizations.of(context)!.workspacePolicyChangedRetry
            : _reason(error),
      );
      await _load();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static String _reason(Object error) =>
      error is StateError ? error.message : error.toString();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final policy = _policy;

    if (policy == null) {
      return SettingsCard(
        child: _loadFailed
            ? Row(
                children: [
                  Expanded(child: Text(l10n.workspaceSecurityLoadFailed)),
                  TextButton(
                    key: const Key('workspace_security_retry'),
                    onPressed: _load,
                    child: Text(l10n.workspaceSecurityRetry),
                  ),
                ],
              )
            : const Center(child: CircularProgressIndicator()),
      );
    }

    final canWiden = policy.canWiden;
    final enabled = !_saving;
    final hintStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.4,
    );

    return SettingsCard(
      child: Column(
        key: const Key('workspace_security_card'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.workspaceSecurityTitle, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(l10n.workspaceSecuritySubtitle, style: hintStyle),
          const SizedBox(height: 16),
          Text(l10n.workspaceExecutionModeLabel, style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<WorkspaceExecutionMode>(
            key: const Key('workspace_execution_mode_selector'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: WorkspaceExecutionMode.direct,
                label: _SegmentLabel(
                  keyName: 'workspace_security_mode_direct',
                  text: l10n.workspaceExecutionModeDirect,
                  selected: policy.executionMode == WorkspaceExecutionMode.direct,
                ),
                enabled:
                    canWiden ||
                    policy.executionMode == WorkspaceExecutionMode.direct,
              ),
              ButtonSegment(
                value: WorkspaceExecutionMode.protected,
                label: _SegmentLabel(
                  keyName: 'workspace_security_mode_protected',
                  text: l10n.workspaceExecutionModeProtected,
                  selected: policy.executionMode == WorkspaceExecutionMode.protected,
                ),
              ),
            ],
            selected: {policy.executionMode},
            onSelectionChanged: enabled
                ? (selection) {
                    final mode = selection.single;
                    if (mode != policy.executionMode) {
                      unawaited(_update(executionMode: mode));
                    }
                  }
                : null,
          ),
          const SizedBox(height: 6),
          Text(
            policy.executionMode == WorkspaceExecutionMode.direct
                ? l10n.workspaceExecutionModeDirectHint
                : l10n.workspaceExecutionModeProtectedHint,
            style: hintStyle,
          ),
          const SizedBox(height: 16),
          Text(l10n.workspaceHostDiscoveryLabel, style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          SegmentedButton<WorkspaceHostDiscoveryPolicy>(
            key: const Key('workspace_host_discovery_selector'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: WorkspaceHostDiscoveryPolicy.ownerOnly,
                label: _SegmentLabel(
                  keyName: 'workspace_security_discovery_owner_only',
                  text: l10n.workspaceHostDiscoveryOwnerOnly,
                  selected: policy.hostDiscoveryPolicy == WorkspaceHostDiscoveryPolicy.ownerOnly,
                ),
                enabled:
                    canWiden ||
                    policy.hostDiscoveryPolicy ==
                        WorkspaceHostDiscoveryPolicy.ownerOnly,
              ),
              ButtonSegment(
                value: WorkspaceHostDiscoveryPolicy.disabled,
                label: _SegmentLabel(
                  keyName: 'workspace_security_discovery_disabled',
                  text: l10n.workspaceHostDiscoveryDisabled,
                  selected: policy.hostDiscoveryPolicy == WorkspaceHostDiscoveryPolicy.disabled,
                ),
              ),
            ],
            selected: {policy.hostDiscoveryPolicy},
            onSelectionChanged: enabled
                ? (selection) {
                    final value = selection.single;
                    if (value != policy.hostDiscoveryPolicy) {
                      unawaited(_update(hostDiscoveryPolicy: value));
                    }
                  }
                : null,
          ),
          const SizedBox(height: 6),
          Text(l10n.workspaceHostDiscoveryHint, style: hintStyle),
          if (!canWiden) ...[
            const SizedBox(height: 16),
            Text(
              l10n.workspaceSecurityStricterOnly,
              key: const Key('workspace_security_stricter_only'),
              style: hintStyle,
            ),
          ],
        ],
      ),
    );
  }
}

/// Segment label carrying the driver key and the selected state, which
/// [SegmentedButton] does not expose to driver snapshots on its own.
class _SegmentLabel extends StatelessWidget {
  const _SegmentLabel({
    required this.keyName,
    required this.text,
    required this.selected,
  });

  final String keyName;
  final String text;
  final bool selected;

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: Key(keyName),
    child: Semantics(selected: selected, child: Text(text)),
  );
}
