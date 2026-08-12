import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/settings/domain/account_lifecycle.dart';
import 'package:sanad_client/features/settings/presentation/bloc/account_lifecycle_cubit.dart';
import 'package:sanad_client/utils/toast_utils.dart';

class SessionsDevicesPage extends StatefulWidget {
  const SessionsDevicesPage({
    super.key,
    required this.devices,
    required this.onOpenDevice,
  });

  final List<DeviceConfig> devices;
  final ValueChanged<DeviceConfig> onOpenDevice;

  @override
  State<SessionsDevicesPage> createState() => _SessionsDevicesPageState();
}

class _SessionsDevicesPageState extends State<SessionsDevicesPage> {
  @override
  void initState() {
    super.initState();
    unawaited(context.read<AccountLifecycleCubit>().load());
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<AccountLifecycleCubit, AccountLifecycleState>(
      listenWhen: (previous, current) => previous.error != current.error && current.error != null,
      listener: (context, state) => ToastUtils.showError(context, state.error!),
      builder: (context, state) {
        final snapshot = state.snapshot;
        if (snapshot == null && state.loading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot == null) {
          return _CenteredMessage(
            message: state.error ?? 'No sessions are available.',
            action: TextButton(
              onPressed: state.loading ? null : context.read<AccountLifecycleCubit>().load,
              child: const Text('Retry'),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: context.read<AccountLifecycleCubit>().load,
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('Sessions & Devices', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 6),
              const Text('Review signed-in Sanad Clients and connected Agent devices.'),
              if (state.error != null) ...[
                const SizedBox(height: 12),
                Text(state.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 24),
              _SectionTitle(title: 'Client Sessions', loading: state.loading),
              if (snapshot.clientSessions.isEmpty)
                const _EmptySection('No Client sessions are available.')
              else
                for (final session in snapshot.clientSessions)
                  _PrincipalCard(
                    principal: session,
                    busy: state.inFlightIds.contains(session.id),
                    onRevoke: () => _confirmRevoke(session),
                  ),
              const SizedBox(height: 24),
              _SectionTitle(title: 'Connected Agents', loading: state.loading),
              if (widget.devices.isEmpty)
                const _EmptySection('No connected Agents are available.')
              else
                for (final device in widget.devices)
                  _AgentCard(
                    device: device,
                    projection: snapshot.agent(device.accountDeviceId ?? device.id),
                    busy: state.inFlightIds.contains(device.accountDeviceId ?? device.id),
                    onOpen: () => widget.onOpenDevice(device),
                    onRevoke: device.accountDeviceId == null
                        ? null
                        : () {
                            final projection = snapshot.agent(device.accountDeviceId!);
                            if (projection != null) {
                              unawaited(_confirmRevoke(projection));
                            }
                          },
                  ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmRevoke(AccountPrincipal principal) async {
    final current = principal.isCurrent;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(current ? 'Sign out this Client?' : 'Revoke access?'),
        content: Text(
          current
              ? 'This will sign out the current Client.'
              : 'This Client or Agent will lose access until it is authorized again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(current ? 'Sign out' : 'Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final revokedCurrent = await context.read<AccountLifecycleCubit>().revoke(principal);
    if (revokedCurrent && mounted) await context.read<AuthCubit>().logout();
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.loading});
  final String title;
  final bool loading;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
      if (loading) const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
    ],
  );
}

class _PrincipalCard extends StatelessWidget {
  const _PrincipalCard({required this.principal, required this.busy, required this.onRevoke});
  final AccountPrincipal principal;
  final bool busy;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final platform = principal.metadata['platform_family'] ?? 'Unknown platform';
    final version = principal.metadata['app_version'];
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: const Icon(Icons.devices_outlined),
        title: Text('$platform${principal.isCurrent ? ' · Current' : ''}'),
        subtitle: Text(
          [
            if (version != null) 'Sanad $version',
            _lastActive(principal.lastActiveAt),
          ].join(' · '),
        ),
        trailing: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _PresenceBadge(principal.status),
            const SizedBox(width: 8),
            IconButton(
              tooltip: principal.isCurrent ? 'Sign out current Client' : 'Revoke Client session',
              onPressed: busy ? null : onRevoke,
              icon: busy
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.logout_outlined),
            ),
          ],
        ),
      ),
    );
  }
}

class _AgentCard extends StatelessWidget {
  const _AgentCard({
    required this.device,
    required this.projection,
    required this.busy,
    required this.onOpen,
    required this.onRevoke,
  });
  final DeviceConfig device;
  final AccountPrincipal? projection;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback? onRevoke;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: const Icon(Icons.memory_outlined),
      title: Text(device.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(_lastActive(projection?.lastActiveAt)),
      onTap: onOpen,
      trailing: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _PresenceBadge(projection?.status ?? AccountPresenceStatus.unavailable),
          IconButton(
            tooltip: 'Open Agent overview',
            onPressed: onOpen,
            icon: const Icon(Icons.open_in_new),
          ),
          if (onRevoke != null)
            IconButton(
              tooltip: 'Revoke Agent device',
              onPressed: busy ? null : onRevoke,
              icon: busy
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.link_off_outlined),
            ),
        ],
      ),
    ),
  );
}

class _PresenceBadge extends StatelessWidget {
  const _PresenceBadge(this.status);
  final AccountPresenceStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      AccountPresenceStatus.online => ('Online', Colors.green),
      AccountPresenceStatus.offline => ('Offline', Theme.of(context).colorScheme.outline),
      AccountPresenceStatus.unavailable => ('Status unavailable', Colors.orange),
    };
    return Semantics(
      label: 'Connection status: $label',
      child: Chip(
        visualDensity: VisualDensity.compact,
        avatar: Icon(Icons.circle, size: 9, color: color),
        label: Text(label),
      ),
    );
  }
}

String _lastActive(DateTime? value) {
  if (value == null) return 'Last active unavailable';
  final local = value.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return 'Last active ${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

class _EmptySection extends StatelessWidget {
  const _EmptySection(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Text(message),
  );
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage({required this.message, required this.action});
  final String message;
  final Widget action;
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(message, textAlign: TextAlign.center),
        action,
      ],
    ),
  );
}
