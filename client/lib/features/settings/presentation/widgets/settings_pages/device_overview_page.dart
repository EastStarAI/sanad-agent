import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/utils/device_ui_mapper.dart';
import 'package:sanad_client/features/devices/presentation/widgets/local_agent_lifecycle_notice.dart';
import 'package:sanad_client/features/settings/data/device_control_client.dart';
import 'package:sanad_client/features/settings/data/device_settings_client.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/utils/toast_utils.dart';

import '../settings_widgets.dart';
import 'agent_restart_confirmation_dialog.dart';
import 'device_rename_dialog.dart';

class DeviceOverviewPage extends StatefulWidget {
  const DeviceOverviewPage({
    super.key,
    required this.device,
    required this.isActive,
  });
  final DeviceConfig device;
  final bool isActive;

  @override
  State<DeviceOverviewPage> createState() => _DeviceOverviewPageState();
}

class _DeviceOverviewPageState extends State<DeviceOverviewPage> {
  static const _knownWebSearchProviders = {'ddg', 'serper'};

  final _client = getIt<DeviceSettingsClient>();
  final _runtimeClient = getIt<DeviceControlClient>();
  final _coordinator = getIt<DeviceConnectionCoordinator>();
  final _serperKeyController = TextEditingController();
  DeviceSettingsSnapshot? _settings;
  DeviceUpdateCheckSnapshot? _updateCheck;
  String? _error;
  String? _runtimeStatus;
  bool _saving = false;
  bool _runtimeBusy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(DeviceOverviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.device.id != widget.device.id) {
      _updateCheck = null;
      _runtimeStatus = null;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _serperKeyController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _error = null);
    try {
      final value = await _client.load(widget.device);
      if (mounted) setState(() => _settings = value);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _checkForAgentUpdates() async {
    if (_runtimeBusy || !widget.device.isOnline) return;
    setState(() {
      _runtimeBusy = true;
      _runtimeStatus = AppLocalizations.of(context)!.checkingForUpdates;
      _error = null;
    });
    try {
      final result = await _runtimeClient.checkForUpdates(widget.device);
      if (!mounted) return;
      setState(() {
        _updateCheck = result;
        _runtimeStatus = _checkStatusLabel(result);
      });
    } catch (error) {
      if (mounted) {
        setState(() => _runtimeStatus = null);
        ToastUtils.showError(context, error.toString());
      }
    } finally {
      if (mounted) setState(() => _runtimeBusy = false);
    }
  }

  Future<void> _applyAgentUpdate() async {
    if (_runtimeBusy || !widget.device.isOnline) return;
    var check = _updateCheck;
    if (check == null || !check.updateAvailable) {
      await _checkForAgentUpdates();
      check = _updateCheck;
    }
    if (!mounted || check == null) return;
    if (check.sourceManaged) {
      ToastUtils.showError(
        context,
        check.message ?? AppLocalizations.of(context)!.sourceManagedAgent,
      );
      return;
    }
    if (!check.updateAvailable) {
      ToastUtils.showSuccess(
        context,
        check.message ?? 'The agent is already up to date.',
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Update agent'),
        content: Text(
          'Install version ${check!.availableVersion} on ${widget.device.name}? '
          'The agent will wait for a safe checkpoint, then the connection will drop until it comes back online.',
        ),
        actions: [
          TextButton(
            key: const Key('dialog_cancel_update_button'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('dialog_confirm_update_button'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Update'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _runtimeBusy = true;
      _runtimeStatus = 'Applying update…';
    });
    try {
      await _runtimeClient.applyUpdate(widget.device, check: check);
      await _runtimeClient.waitForReconnect(
        inventory: context.read<DeviceCubit>().agentRepository,
        deviceId: widget.device.id,
        expectedVersion: check.availableVersion,
      );
      if (!mounted) return;
      setState(() {
        _updateCheck = null;
        _runtimeStatus = 'Updated to ${check!.availableVersion}.';
      });
      ToastUtils.showSuccess(context, 'Agent updated to ${check.availableVersion}.');
    } catch (error) {
      if (mounted) ToastUtils.showError(context, error.toString());
    } finally {
      if (mounted) setState(() => _runtimeBusy = false);
    }
  }

  Future<void> _restartRemoteAgent() async {
    if (_runtimeBusy || !widget.device.isOnline) return;
    final mode = await showDialog<AgentRestartMode>(
      context: context,
      builder: (context) => AgentRestartConfirmationDialog(
        deviceName: widget.device.name,
      ),
    );
    if (mode == null || !mounted) return;
    final force = mode == AgentRestartMode.force;

    setState(() {
      _runtimeBusy = true;
      _runtimeStatus = force ? 'Force restarting agent…' : 'Restarting agent…';
    });
    try {
      await _runtimeClient.restartAgent(widget.device, force: force);
      await _runtimeClient.waitForReconnect(
        inventory: context.read<DeviceCubit>().agentRepository,
        deviceId: widget.device.id,
      );
      if (!mounted) return;
      setState(() => _runtimeStatus = 'Agent is online again.');
      ToastUtils.showSuccess(context, 'Agent restarted.');
    } catch (error) {
      if (mounted) ToastUtils.showError(context, error.toString());
    } finally {
      if (mounted) setState(() => _runtimeBusy = false);
    }
  }

  String _checkStatusLabel(DeviceUpdateCheckSnapshot result) {
    if (result.sourceManaged) {
      return result.message ?? 'This agent runs from source.';
    }
    if (result.updateAvailable) {
      return 'Update available: ${result.currentVersion} → ${result.availableVersion}.';
    }
    if (result.upToDate) {
      return 'Up to date (${result.currentVersion}).';
    }
    return result.message ?? 'Update check finished (${result.status}).';
  }

  Future<void> _update(Map<String, dynamic> changes) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final value = await _client.update(widget.device, changes);
      if (!mounted) return;
      setState(() => _settings = value);
      if (value.restartRequired) {
        ToastUtils.showSuccess(
          context,
          'Setting saved. The agent is restarting…',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleComputerUse(bool enabled) async {
    if (enabled && !(_settings?.computerUsePermissionsGranted ?? false)) {
      final granted = await _client.requestComputerUsePermissions(
        widget.device,
      );
      if (!granted) {
        if (mounted) {
          setState(
            () => _error = 'Accessibility or screen-recording permission was not granted.',
          );
        }
        return;
      }
    }
    await _update({'computer_use_enabled': enabled});
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final route = _coordinator.resolve(widget.device).scope;
    return PageFrame(
      title: widget.device.name,
      subtitle: 'Device overview and runtime preferences.',
      child: Column(
        children: [
          SettingsCard(
            child: Column(
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: widget.device.iconBackground(context),
                    child: widget.device.buildIcon(context, size: 16),
                  ),
                  title: DeviceNameEditor(
                    device: widget.device,
                    onRename: (name) => context.read<DeviceCubit>().renameAgent(
                      widget.device,
                      name,
                    ),
                  ),
                  subtitle: Text(
                    '${widget.device.isOnline ? 'Online' : 'Offline'} · ${route == ConnectionScope.local ? 'Local connection' : 'Sanad Gateway'}',
                  ),
                  trailing: widget.isActive
                      ? const Chip(
                          key: Key('device_active_chip'),
                          label: Text('Active'),
                        )
                      : FilledButton.tonal(
                          key: const Key('device_set_active_btn'),
                          onPressed: () => context.read<DeviceCubit>().setActiveAgent(widget.device.id),
                          child: const Text('Set as active'),
                        ),
                ),
                const Divider(),
                DetailRow(
                  label: 'Device ID',
                  value: widget.device.hardwareId ?? widget.device.id,
                ),
                DetailRow(
                  label: 'Agent version',
                  value: widget.device.metadata?['version']?.toString() ?? _coordinator.expectedVersion,
                ),
                DetailRow(
                  label: 'Current route',
                  value: route == ConnectionScope.local ? 'Local' : 'Cloud',
                ),
                if (route == ConnectionScope.local) LocalAgentLifecycleNotice(coordinator: _coordinator),
                if (_runtimeStatus != null) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _runtimeStatus!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.end,
                  children: [
                    OutlinedButton.icon(
                      key: const Key('device_check_updates_button'),
                      onPressed: !widget.device.isOnline || _runtimeBusy ? null : _checkForAgentUpdates,
                      icon: const Icon(Icons.system_update_alt),
                      label: const Text('Check for updates'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('device_apply_update_button'),
                      onPressed: !widget.device.isOnline || _runtimeBusy ? null : _applyAgentUpdate,
                      icon: const Icon(Icons.upgrade),
                      label: const Text('Update agent'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('device_restart_agent_button'),
                      onPressed: !widget.device.isOnline || _runtimeBusy ? null : _restartRemoteAgent,
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('Restart agent'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (settings == null && _error == null) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: MaterialBanner(
                content: Text(_error!),
                actions: [
                  TextButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
            ),
          if (settings != null) ...[
            SettingsCard(
              child: Column(
                children: [
                  if (route == ConnectionScope.local)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Cloud Connection'),
                      subtitle: Text(
                        settings.cloudConnection.managedExternally
                            ? 'Managed by the process environment.'
                            : 'Allow this agent to connect through Sanad Gateway. Changing this restarts the agent.',
                      ),
                      value: settings.cloudConnection.enabled,
                      onChanged: _saving || settings.cloudConnection.managedExternally
                          ? null
                          : (value) => _update({'cloud_connection_enabled': value}),
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Computer Use'),
                    subtitle: Text(
                      settings.computerUsePermissionsGranted
                          ? 'OS permissions are granted.'
                          : 'Accessibility and screen-recording permissions are required.',
                    ),
                    value: settings.computerUse.enabled,
                    onChanged: _saving || settings.computerUse.managedExternally ? null : _toggleComputerUse,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SettingsCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Web Search',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    // Guard against providers the client does not yet know about
                    // (e.g. the agent reports 'brave' but the client build only
                    // ships ddg/serper). Dropping the unknown initialValue keeps
                    // the dropdown usable instead of tripping Flutter's
                    // "exactly one item" assertion.
                    initialValue:
                        _knownWebSearchProviders.contains(
                          settings.webSearchProvider,
                        )
                        ? settings.webSearchProvider
                        : null,
                    decoration: const InputDecoration(
                      labelText: 'Provider',
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'ddg', child: Text('DuckDuckGo')),
                      DropdownMenuItem(value: 'serper', child: Text('Serper')),
                    ],
                    onChanged: _saving || settings.webSearchProviderManagedExternally
                        ? null
                        : (value) {
                            if (value != null) {
                              unawaited(
                                _update({'web_search_provider': value}),
                              );
                            }
                          },
                  ),
                  if (settings.webSearchProvider == 'serper') ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _serperKeyController,
                      onChanged: (_) => setState(() {}),
                      obscureText: true,
                      enabled: !_saving && !settings.serperKeyManagedExternally,
                      decoration: InputDecoration(
                        labelText: 'Serper API key',
                        hintText: settings.serperConfigured ? 'Configured — enter a replacement' : 'Enter API key',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (settings.serperConfigured)
                          TextButton(
                            onPressed: _saving || settings.serperKeyManagedExternally
                                ? null
                                : () => _update({'serper_api_key': ''}),
                            child: const Text('Clear key'),
                          ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed:
                              _saving || settings.serperKeyManagedExternally || _serperKeyController.text.trim().isEmpty
                              ? null
                              : () => _update({
                                  'serper_api_key': _serperKeyController.text.trim(),
                                }),
                          child: const Text('Save key'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 24),
          SettingsCard(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Danger zone',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: const Text(
                'Remove this device from your Sanad account.',
              ),
              trailing: OutlinedButton(
                onPressed: () => _confirmDelete(context),
                child: const Text('Remove device'),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove device?'),
        content: Text(
          '${widget.device.name} will be removed from your account.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      context.read<DeviceCubit>().deleteAgent(widget.device.id);
    }
  }
}
