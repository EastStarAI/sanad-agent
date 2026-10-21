import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sanad_client/features/devices/data/daemon/local_daemon_controller.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Informational notice for the local agent's last lifecycle outcome.
///
/// Today it renders only when an installed agent newer than this client was
/// kept and is in use; every other outcome renders nothing.
class LocalAgentLifecycleNotice extends StatefulWidget {
  const LocalAgentLifecycleNotice({super.key, required this.coordinator});

  final DeviceConnectionCoordinator coordinator;

  @override
  State<LocalAgentLifecycleNotice> createState() => _LocalAgentLifecycleNoticeState();
}

class _LocalAgentLifecycleNoticeState extends State<LocalAgentLifecycleNotice> {
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _changes = widget.coordinator.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.coordinator.localAgentLifecycle;
    if (result?.status != AgentLifecycleStatus.newerAgentInUse) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final message = AppLocalizations.of(context)!.newerAgentInUseNotice(
      result!.agentVersion ?? '',
      widget.coordinator.expectedVersion,
    );
    return Padding(
      key: const Key('local_agent_newer_notice'),
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(child: Text(message, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}
