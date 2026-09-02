import 'package:flutter/material.dart';

import '../../../../devices/domain/models/device_config.dart';
import '../../../../devices/presentation/utils/device_ui_mapper.dart';

/// Persistent device selector + settings affordance at the top of the sidebar.
///
/// Gate C0 ownership: this widget reads only the device list and active device
/// from [DeviceCubit]. It emits a [onDeviceSelected] intent and a
/// [onSettingsTapped] intent; it never opens screens or mutates cache itself.
/// Device switching is always available — an offline device still shows its
/// cached sidebar (Plan 32c §السلوك).
class SidebarDeviceHeaderBar extends StatelessWidget {
  final List<DeviceConfig> devices;
  final DeviceConfig? activeDevice;
  final ValueChanged<DeviceConfig> onDeviceSelected;
  final VoidCallback onSettingsTapped;
  final bool isDrawerMode;
  final bool isLoadingFromBackend;

  const SidebarDeviceHeaderBar({
    super.key,
    required this.devices,
    required this.activeDevice,
    required this.onDeviceSelected,
    required this.onSettingsTapped,
    this.isDrawerMode = false,
    this.isLoadingFromBackend = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              label: 'Device selector',
              child: _DeviceDropdown(
                devices: devices,
                activeDevice: activeDevice,
                onDeviceSelected: onDeviceSelected,
                onSettingsTapped: onSettingsTapped,
                isLoadingFromBackend: isLoadingFromBackend,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceDropdown extends StatelessWidget {
  final List<DeviceConfig> devices;
  final DeviceConfig? activeDevice;
  final ValueChanged<DeviceConfig> onDeviceSelected;
  final VoidCallback onSettingsTapped;
  final bool isLoadingFromBackend;

  const _DeviceDropdown({
    required this.devices,
    required this.activeDevice,
    required this.onDeviceSelected,
    required this.onSettingsTapped,
    this.isLoadingFromBackend = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Show loading state while fetching from backend
    if (devices.isEmpty && isLoadingFromBackend) {
      return Row(
        children: [
          SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Loading devices…',
            style: TextStyle(
              color: theme.colorScheme.onSurfaceVariant,
              fontSize: 13,
            ),
          ),
        ],
      );
    }

    if (devices.isEmpty) {
      return Text(
        'No devices',
        style: TextStyle(
          color: theme.colorScheme.onSurfaceVariant,
          fontSize: 13,
        ),
      );
    }

    final displayWidget = Row(
      children: [
        if (activeDevice != null) ...[
          activeDevice!.buildIcon(context, size: 16),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            activeDevice?.name ?? 'No devices',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: theme.colorScheme.onSurface,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        if (activeDevice != null && activeDevice!.isOnline) ...[
          const SizedBox(width: 6),
          _DeviceStatusDot(device: activeDevice!),
        ],
        if (activeDevice?.isLocalReachable == true) ...[
          const SizedBox(width: 6),
          const _LocalBadge(),
        ],
        const SizedBox(width: 6),
        Icon(
          Icons.keyboard_arrow_down_rounded,
          color: theme.colorScheme.onSurfaceVariant,
          size: 18,
        ),
      ],
    );

    return PopupMenuButton<Object?>(
      tooltip: '',
      offset: const Offset(0, 26),
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.1)),
      ),
      onSelected: (value) {
        if (value == 'manage_devices') {
          onSettingsTapped();
        } else if (value is DeviceConfig) {
          onDeviceSelected(value);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.4)),
        ),
        child: displayWidget,
      ),
      itemBuilder: (context) {
        return [
          ...devices.map((device) {
            final isSelected = device.id == activeDevice?.id;
            return PopupMenuItem<Object?>(
              key: Key('sidebar_device_item_${device.name}'),
              value: device,
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  device.buildIcon(context, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      device.name,
                      style: TextStyle(
                        color: isSelected ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (device.isOnline) ...[
                    const SizedBox(width: 6),
                    _DeviceStatusDot(device: device),
                  ],
                  if (device.isLocalReachable) ...[
                    const SizedBox(width: 6),
                    const _LocalBadge(),
                  ],
                  if (isSelected) ...[
                    const SizedBox(width: 8),
                    Icon(Icons.check, size: 12, color: theme.colorScheme.primary),
                  ],
                ],
              ),
            );
          }),
          PopupMenuDivider(height: 1, color: theme.colorScheme.outline.withValues(alpha: 0.1)),
          PopupMenuItem<Object?>(
            key: const Key('sidebar_device_management_btn'),
            value: 'manage_devices',
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(
                  Icons.settings_outlined,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  'Device Settings',
                  style: TextStyle(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ];
      },
    );
  }
}

class _DeviceStatusDot extends StatelessWidget {
  final DeviceConfig device;
  const _DeviceStatusDot({required this.device});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: device.isOnline ? Colors.green : Colors.grey,
        shape: BoxShape.circle,
      ),
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
