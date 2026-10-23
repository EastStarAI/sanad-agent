import 'package:flutter/material.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/mcp/presentation/screens/mcp_server_management_screen.dart';
import 'package:sanad_client/features/settings/data/workspace_security_client.dart';
import 'package:sanad_client/features/settings/presentation/widgets/workspace_security_card.dart';

import '../settings_widgets.dart';
import 'skills_page.dart';

class WorkspacePage extends StatelessWidget {
  const WorkspacePage({
    super.key,
    required this.device,
    required this.workspace,
    required this.onRename,
    required this.onChangePath,
    required this.onRemove,
  });
  final DeviceConfig device;
  final DeviceWorkspace workspace;
  final VoidCallback onRename;
  final VoidCallback? onChangePath;
  final Future<void> Function()? onRemove;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Column(
      children: [
        Material(
          color: Colors.transparent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 24, 28, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: 'Workspace: ',
                            style: TextStyle(
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          TextSpan(text: workspace.name),
                        ],
                      ),
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      workspace.path,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(key: Key('workspace_tab_overview'), text: 'Overview'),
                  Tab(key: Key('workspace_tab_mcp_servers'), text: 'MCP Servers'),
                  Tab(key: Key('workspace_tab_skills'), text: 'Skills'),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            children: [
              PageFrame(
                title: 'Workspace Overview',
                subtitle: 'Configuration scope on ${device.name}.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SettingsCard(
                  child: Column(
                    children: [
                      DetailRow(label: 'Name', value: workspace.name),
                      DetailRow(label: 'Path', value: workspace.path),
                      DetailRow(
                        label: 'Status',
                        value: workspace.isAvailable ? 'Available' : 'Folder missing',
                      ),
                      DetailRow(label: 'Trust', value: workspace.trustState),
                      const Divider(height: 32),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: onRename,
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('Rename Workspace'),
                          ),
                          if (onChangePath != null)
                            FilledButton.icon(
                              onPressed: onChangePath,
                              icon: const Icon(
                                Icons.drive_folder_upload_outlined,
                              ),
                              label: const Text('Change Path'),
                            ),
                          WorkspaceRemovalButton(onRemove: onRemove),
                        ],
                      ),
                    ],
                  ),
                ),
                    const SizedBox(height: 16),
                    WorkspaceSecurityCard(
                      device: device,
                      workspaceId: workspace.id,
                      client: getIt<WorkspaceSecurityClient>(),
                    ),
                  ],
                ),
              ),
              McpServerManagementScreen(
                device: device,
                workspaceId: workspace.id,
                workspaceName: workspace.name,
                embedded: true,
              ),
              SkillsPage(device: device, workspace: workspace),
            ],
          ),
        ),
      ],
    ),
  );
}

class WorkspaceRemovalButton extends StatelessWidget {
  const WorkspaceRemovalButton({super.key, required this.onRemove});

  final Future<void> Function()? onRemove;

  Future<void> _confirmRemoval(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove workspace?'),
        content: const Text(
          'This removes only the workspace record from Sanad. The folder and '
          'its files will not be deleted, and existing conversations will '
          'remain in the database.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm_remove_workspace_button'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove workspace'),
          ),
        ],
      ),
    );
    if (confirmed == true) await onRemove?.call();
  }

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    key: const Key('remove_workspace_button'),
    onPressed: onRemove == null ? null : () => _confirmRemoval(context),
    style: OutlinedButton.styleFrom(
      foregroundColor: Theme.of(context).colorScheme.error,
    ),
    icon: const Icon(Icons.delete_outline),
    label: const Text('Remove workspace'),
  );
}
