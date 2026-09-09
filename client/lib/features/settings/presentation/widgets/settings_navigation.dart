import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/devices/presentation/utils/device_ui_mapper.dart';

enum SettingsDestination { profile, general, overview, providers, mcp, skills, workspace }

class SettingsNavigation extends StatelessWidget {
  const SettingsNavigation({
    super.key,
    required this.devices,
    required this.activeDeviceId,
    required this.selectedDevice,
    required this.selectedDestination,
    required this.workspaces,
    required this.selectedWorkspaceId,
    required this.showAllWorkspaces,
    required this.onSelectPersonal,
    required this.onSelectDevice,
    required this.onSelectDeviceSection,
    required this.onSelectWorkspace,
    required this.onToggleWorkspaces,
  });

  final List<DeviceConfig> devices;
  final String? activeDeviceId;
  final DeviceConfig? selectedDevice;
  final SettingsDestination selectedDestination;
  final List<DeviceWorkspace> workspaces;
  final String? selectedWorkspaceId;
  final bool showAllWorkspaces;
  final ValueChanged<SettingsDestination> onSelectPersonal;
  final ValueChanged<DeviceConfig> onSelectDevice;
  final ValueChanged<SettingsDestination> onSelectDeviceSection;
  final ValueChanged<DeviceWorkspace> onSelectWorkspace;
  final VoidCallback onToggleWorkspaces;

  @override
  Widget build(BuildContext context) {
    final visibleWorkspaces = showAllWorkspaces ? workspaces : workspaces.take(6).toList();
    return Material(
      color: Colors.transparent, // Background handled by parent container
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 24),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: 'Back to conversations',
                  onPressed: () {
                    if (context.canPop()) {
                      context.pop();
                    } else {
                      context.go(AppRoutes.home);
                    }
                  },
                ),
                Text(
                  'Settings',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          const NavigationLabel('Personal'),
          NavigationTile(
            icon: Icons.person_outline,
            label: 'Profile',
            selected: selectedDestination == SettingsDestination.profile,
            onTap: () => onSelectPersonal(SettingsDestination.profile),
          ),
          NavigationTile(
            icon: Icons.tune,
            label: 'General',
            selected: selectedDestination == SettingsDestination.general,
            onTap: () => onSelectPersonal(SettingsDestination.general),
          ),
          Row(
            children: [
              const Expanded(child: NavigationLabel('Devices')),
              IconButton(
                onPressed: () => context.push(AppRoutes.addAgent),
                icon: const Icon(Icons.add, size: 19),
                tooltip: 'Add device',
              ),
            ],
          ),
          if (devices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('No devices available.'),
            ),
          for (final device in devices)
            DeviceNavigationTile(
              device: device,
              active: device.id == activeDeviceId,
              selected: device.id == selectedDevice?.id,
              onTap: () => onSelectDevice(device),
            ),
          const SizedBox(height: 18),
          if (selectedDevice != null) ...[
            NavigationLabel('${selectedDevice!.name} Settings'),
            for (final item in const [
              (SettingsDestination.overview, Icons.dashboard_outlined, 'Overview'),
              (SettingsDestination.providers, Icons.hub_outlined, 'Providers'),
              (SettingsDestination.mcp, Icons.dns_outlined, 'MCP Servers'),
              (SettingsDestination.skills, Icons.auto_awesome_outlined, 'Skills'),
            ])
              Padding(
                padding: const EdgeInsets.only(left: 0),
                child: NavigationTile(
                  icon: item.$2,
                  label: item.$3,
                  selected: selectedDestination == item.$1,
                  onTap: () => onSelectDeviceSection(item.$1),
                ),
              ),
            const Padding(
              padding: EdgeInsets.only(left: 30),
              child: NavigationLabel('Workspaces'),
            ),
            for (final workspace in visibleWorkspaces)
              Padding(
                padding: const EdgeInsets.only(left: 18),
                child: NavigationTile(
                  key: Key('nav_workspace_${workspace.name}'),
                  icon: Icons.folder_outlined,
                  label: workspace.name,
                  selected: selectedDestination == SettingsDestination.workspace && workspace.id == selectedWorkspaceId,
                  onTap: () => onSelectWorkspace(workspace),
                ),
              ),
            if (workspaces.length > 6)
              Padding(
                padding: const EdgeInsets.only(left: 30),
                child: TextButton(
                  key: const Key('settings_show_all_workspaces_btn'),
                  onPressed: onToggleWorkspaces,
                  child: Text(showAllWorkspaces ? 'Show less' : 'Show all (${workspaces.length})'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class NavigationLabel extends StatelessWidget {
  const NavigationLabel(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 6),
      child: Text(
        label,
        style: TextStyle(
          color: theme.colorScheme.onSurfaceVariant,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class NavigationTile extends StatelessWidget {
  const NavigationTile({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    key: Key('nav_tile_${label.toLowerCase().replaceAll(' ', '_')}'),
    dense: true,
    selected: selected,
    selectedTileColor: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.15),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    leading: Icon(icon, size: 20),
    title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    onTap: onTap,
  );
}

class DeviceNavigationTile extends StatelessWidget {
  const DeviceNavigationTile({
    super.key,
    required this.device,
    required this.active,
    required this.selected,
    required this.onTap,
  });

  final DeviceConfig device;
  final bool active;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textStyle = device.isOnline
        ? null
        : TextStyle(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6));

    return ListTile(
      key: Key('nav_device_${device.name}'),
      dense: true,
      selected: selected,
      selectedTileColor: theme.colorScheme.secondaryContainer.withValues(alpha: 0.15),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      leading: device.buildIcon(context, size: 16),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(
            child: Text(
              device.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textStyle,
            ),
          ),
          if (device.isOnline) ...[
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
          if (device.isLocalReachable) ...[
            const SizedBox(width: 6),
            const _LocalBadge(),
          ],
          if (active) ...[
            const SizedBox(width: 8),
            Icon(Icons.check, size: 12, color: theme.colorScheme.primary),
          ],
        ],
      ),
      trailing: selected ? const Icon(Icons.expand_more) : null,
      onTap: onTap,
    );
  }
}

class _LocalBadge extends StatelessWidget {
  const _LocalBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'local',
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.secondary,
        ),
      ),
    );
  }
}
