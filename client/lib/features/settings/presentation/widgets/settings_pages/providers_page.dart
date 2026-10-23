import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_setup_flow.dart';
import 'package:sanad_client/features/settings/data/device_settings_client.dart';

import '../settings_widgets.dart';

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
