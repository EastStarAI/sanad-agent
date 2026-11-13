import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

extension DeviceConfigUI on DeviceConfig {
  /// The name to show for this device.
  ///
  /// A row the Client synthesized for its own machine carries
  /// [DeviceConfig.localPlaceholderName] instead of an Agent-reported name, so
  /// it is the one name the interface must translate: every other device name
  /// is the user's own text and is shown exactly as the Agent stored it.
  String displayName(AppLocalizations localizations) =>
      name == DeviceConfig.localPlaceholderName
          ? localizations.devicesThisDevice
          : name;

  IconData get icon {
    final platform = metadata?['platform'] as String?;
    switch (platform?.toLowerCase()) {
      case 'macos':
        return Icons.apple;
      case 'windows':
        return Icons.window;
      case 'linux':
        return Icons.terminal;
      default:
        return Icons.computer;
    }
  }

  Widget buildIcon(BuildContext context, {double size = 16, Color? color}) {
    final platform = metadata?['platform'] as String?;
    final resolvedColor = color ?? this.color(context);
    if (platform?.toLowerCase() == 'linux') {
      return SvgPicture.asset(
        'assets/linux.svg',
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(resolvedColor, BlendMode.srcIn),
      );
    }
    return Icon(
      icon,
      size: size,
      color: resolvedColor,
    );
  }

  Color color(BuildContext context) {
    return isOnline ? Theme.of(context).colorScheme.primary : const Color(0xFF9E9E9E);
  }

  Color iconBackground(BuildContext context) => color(context).withValues(alpha: 0.2);
}
