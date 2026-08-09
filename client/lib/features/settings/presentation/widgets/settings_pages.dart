import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/presentation/bloc/theme/theme_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_state.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/utils/device_ui_mapper.dart';
import 'package:sanad_client/features/mcp/presentation/screens/mcp_server_management_screen.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_setup_flow.dart';
import 'package:sanad_client/features/settings/data/device_settings_client.dart';
import 'package:sanad_client/features/settings/data/device_skills_client.dart';
import 'package:sanad_client/infrastructure/platform/auto_update_service.dart';
import 'package:sanad_client/utils/app_platform.dart';

import 'settings_widgets.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthCubit>().state;
    return PageFrame(
      title: 'Profile',
      subtitle: 'Your Sanad account and session.',
      child: SettingsCard(
        child: auth is AuthAuthenticated
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 28,
                    child: Text(auth.username.characters.first.toUpperCase()),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    auth.username,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(
                    auth.email,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    onPressed: () => context.read<AuthCubit>().logout(),
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign out'),
                  ),
                ],
              )
            : auth is AuthLoading
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: CircularProgressIndicator(),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Sign in to manage your Sanad account.'),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(context.read<AuthCubit>().login()),
                    icon: const Icon(Icons.login),
                    label: const Text('Sign in'),
                  ),
                ],
              ),
      ),
    );
  }
}

class GeneralPage extends StatefulWidget {
  const GeneralPage({super.key});

  @override
  State<GeneralPage> createState() => _GeneralPageState();
}

class _GeneralPageState extends State<GeneralPage> {
  bool _checking = false;
  String? _updateMessage;

  Future<void> _checkForUpdates() async {
    setState(() {
      _checking = true;
      _updateMessage = null;
    });
    final result = await getIt<AutoUpdateService>().checkForUpdates();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _updateMessage =
          result.message ??
          switch (result.status) {
            ClientUpdateStatus.updateOpened =>
              'The official Linux release was opened. Download, replace, and restart Sanad manually.',
            ClientUpdateStatus.upToDate => 'Sanad Client is up to date.',
            ClientUpdateStatus.sourceManaged => 'This source build is updated from its developer checkout.',
            ClientUpdateStatus.artifactUnavailable =>
              'A newer release exists, but no matching Linux package is available.',
            ClientUpdateStatus.launchFailed => 'The official release was found, but the browser could not be opened.',
            _ => 'The update check has started.',
          };
    });
  }

  @override
  Widget build(BuildContext context) {
    final mode = context.watch<ThemeCubit>().state;
    return PageFrame(
      title: 'General',
      subtitle: 'Preferences for this Sanad app.',
      child: SettingsCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Appearance',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              'Choose how Sanad looks on this device.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  label: Text('System'),
                  icon: Icon(Icons.settings_brightness_outlined),
                ),
                ButtonSegment(
                  value: ThemeMode.light,
                  label: Text('Light'),
                  icon: Icon(Icons.light_mode_outlined),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  label: Text('Dark'),
                  icon: Icon(Icons.dark_mode_outlined),
                ),
              ],
              selected: {mode},
              onSelectionChanged: (selection) => context.read<ThemeCubit>().updateTheme(selection.first),
            ),
            if (AppPlatform.isDesktop) ...[
              const Divider(height: 40),
              Text(
                'Updates',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                AppPlatform.isLinux
                    ? 'Linux updates are manual. Sanad only opens a newer official package after validating its release manifest.'
                    : 'Automatic update checks run in the background. Use this action to check the signed update feed now.',
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _checking ? null : _checkForUpdates,
                icon: _checking
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.system_update_alt),
                label: const Text('Check for Updates'),
              ),
              if (_updateMessage != null) ...[
                const SizedBox(height: 10),
                Text(_updateMessage!),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class EmptyDevicePage extends StatelessWidget {
  const EmptyDevicePage({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.devices_other_outlined, size: 52),
        const SizedBox(height: 12),
        Text('Select a device', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        const Text('Device settings will appear here.'),
      ],
    ),
  );
}

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
  final _coordinator = getIt<DeviceConnectionCoordinator>();
  final _serperKeyController = TextEditingController();
  DeviceSettingsSnapshot? _settings;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Setting saved. The agent is restarting…'),
          ),
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
                      ? const Chip(label: Text('Active'))
                      : FilledButton.tonal(
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
                if (route == ConnectionScope.local)
                  Align(
                    alignment: Alignment.centerRight,
                    child: OutlinedButton.icon(
                      onPressed: _saving ? null : () => _coordinator.serviceManager.restartDaemon(),
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('Restart agent'),
                    ),
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

class DeviceNameEditor extends StatelessWidget {
  const DeviceNameEditor({
    super.key,
    required this.device,
    required this.onRename,
  });

  final DeviceConfig device;
  final Future<void> Function(String name) onRename;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Flexible(
          child: Text(
            device.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (device.accountDeviceId != null) ...[
          const SizedBox(width: 4),
          IconButton(
            key: const Key('device_name_edit_button'),
            tooltip: 'Rename device',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.edit_outlined, size: 18),
            onPressed: () {
              unawaited(
                showDialog<void>(
                  context: context,
                  builder: (context) => DeviceRenameDialog(
                    currentName: device.name,
                    onRename: onRename,
                  ),
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}

class DeviceRenameDialog extends StatefulWidget {
  const DeviceRenameDialog({
    super.key,
    required this.currentName,
    required this.onRename,
  });

  final String currentName;
  final Future<void> Function(String name) onRename;

  @override
  State<DeviceRenameDialog> createState() => _DeviceRenameDialogState();
}

class _DeviceRenameDialogState extends State<DeviceRenameDialog> {
  late final TextEditingController _controller;
  String? _requestError;
  bool _saving = false;

  String get _name => _controller.text.trim();
  bool get _canSubmit =>
      !_saving && _name.isNotEmpty && _name != widget.currentName.trim() && _name.length <= DeviceConfig.maxNameLength;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentName)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.currentName.length,
      );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _saving = true;
      _requestError = null;
    });
    try {
      await widget.onRename(_name);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _requestError = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename device'),
      content: SizedBox(
        width: 420,
        child: TextField(
          key: const Key('device_name_field'),
          controller: _controller,
          autofocus: true,
          enabled: !_saving,
          maxLength: DeviceConfig.maxNameLength,
          decoration: InputDecoration(
            labelText: 'Device name',
            errorText: _requestError,
          ),
          onChanged: (_) => setState(() => _requestError = null),
          onSubmitted: (_) => unawaited(_submit()),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('device_name_rename_button'),
          onPressed: _canSubmit ? () => unawaited(_submit()) : null,
          child: _saving
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Rename'),
        ),
      ],
    );
  }
}

class ProvidersPage extends StatefulWidget {
  const ProvidersPage({super.key, required this.device});
  final DeviceConfig device;

  @override
  State<ProvidersPage> createState() => _ProvidersPageState();
}

class _ProvidersPageState extends State<ProvidersPage> {
  final _settingsClient = getIt<DeviceSettingsClient>();
  DeviceSettingsSnapshot? _settings;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final value = await _settingsClient.load(widget.device);
      if (mounted) setState(() => _settings = value);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _toggleFailover(bool enabled) async {
    try {
      final value = await _settingsClient.update(widget.device, {
        'provider_auto_failover_enabled': enabled,
      });
      if (mounted) setState(() => _settings = value);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    return PageFrame(
      title: 'Providers',
      subtitle: 'Models, credentials, and recovery policy for ${widget.device.name}.',
      child: Column(
        children: [
          SettingsCard(
            child: settings == null
                ? (_error == null ? const LinearProgressIndicator() : Text(_error!))
                : SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Provider Auto Failover'),
                    subtitle: const Text(
                      'Allow eligible provider instances to replace a failed provider. Per-provider preferences are preserved while this is off.',
                    ),
                    value: settings.providerAutoFailover.enabled,
                    onChanged: settings.providerAutoFailover.managedExternally ? null : _toggleFailover,
                  ),
          ),
          const SizedBox(height: 16),
          SettingsCard(
            child: ProviderSetupFlow(
              device: widget.device,
              showReadyState: false,
              globalAutoFailoverEnabled: settings?.providerAutoFailover.enabled ?? true,
            ),
          ),
        ],
      ),
    );
  }
}

class SkillsPage extends StatelessWidget {
  const SkillsPage({super.key, required this.device, this.workspace});
  final DeviceConfig device;
  final DeviceWorkspace? workspace;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<DeviceSkillEntry>>(
    future: getIt<DeviceSkillsClient>().list(
      device,
      workspaceId: workspace?.id,
    ),
    builder: (context, snapshot) {
      final title = workspace == null ? 'Skills' : '${workspace!.name} Skills';
      final subtitle = workspace == null
          ? 'User-level skills available on ${device.name}.'
          : 'Workspace and inherited device skills. Workspace skills take precedence when names match.';
      return PageFrame(
        title: title,
        subtitle: subtitle,
        child: snapshot.connectionState != ConnectionState.done
            ? const LinearProgressIndicator()
            : snapshot.hasError
            ? SettingsCard(child: Text(snapshot.error.toString()))
            : SkillList(
                skills: snapshot.data ?? const [],
                workspaceScoped: workspace != null,
              ),
      );
    },
  );
}

class SkillList extends StatelessWidget {
  const SkillList({
    super.key,
    required this.skills,
    required this.workspaceScoped,
  });
  final List<DeviceSkillEntry> skills;
  final bool workspaceScoped;

  @override
  Widget build(BuildContext context) {
    if (skills.isEmpty) {
      return const SettingsCard(child: Text('No skills found.'));
    }
    return Column(
      children: [
        for (final skill in skills) ...[
          SettingsCard(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                skill.active ? Icons.auto_awesome : Icons.visibility_off_outlined,
              ),
              title: Text(skill.name),
              subtitle: Text(
                skill.description ?? (skill.shadowedBy == null ? 'No description' : 'Shadowed by ${skill.shadowedBy}'),
              ),
              trailing: Chip(
                label: Text(_originLabel(skill.origin, workspaceScoped)),
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  String _originLabel(String origin, bool workspaceScoped) {
    final normalized = origin.toLowerCase();
    if (workspaceScoped && normalized.contains('workspace')) return 'Workspace';
    return 'Device';
  }
}

class WorkspacePage extends StatelessWidget {
  const WorkspacePage({
    super.key,
    required this.device,
    required this.workspace,
    required this.onRename,
    required this.onChangePath,
  });
  final DeviceConfig device;
  final DeviceWorkspace workspace;
  final VoidCallback onRename;
  final VoidCallback onChangePath;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Column(
      children: [
        Material(
          color: Theme.of(context).colorScheme.surface,
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
                  Tab(text: 'Overview'),
                  Tab(text: 'MCP Servers'),
                  Tab(text: 'Skills'),
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
                child: SettingsCard(
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
                          FilledButton.icon(
                            onPressed: onChangePath,
                            icon: const Icon(
                              Icons.drive_folder_upload_outlined,
                            ),
                            label: const Text('Change Path'),
                          ),
                        ],
                      ),
                    ],
                  ),
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
