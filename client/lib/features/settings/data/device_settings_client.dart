import 'package:sanad_client/features/devices/data/device_command_client.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';

class ManagedToggleSetting {
  const ManagedToggleSetting({required this.enabled, required this.managedExternally});

  final bool enabled;
  final bool managedExternally;

  factory ManagedToggleSetting.fromJson(Map<String, dynamic> json) => ManagedToggleSetting(
    enabled: json['enabled'] == true,
    managedExternally: json['managed_externally'] == true,
  );
}

class DeviceSettingsSnapshot {
  const DeviceSettingsSnapshot({
    required this.cloudConnection,
    required this.computerUse,
    required this.computerUsePermissionsGranted,
    required this.webSearchProvider,
    required this.serperConfigured,
    required this.webSearchProviderManagedExternally,
    required this.serperKeyManagedExternally,
    required this.providerAutoFailover,
    this.dictation,
    this.restartRequired = false,
  });

  final ManagedToggleSetting cloudConnection;
  final ManagedToggleSetting computerUse;
  final bool computerUsePermissionsGranted;
  final String webSearchProvider;
  final bool serperConfigured;
  final bool webSearchProviderManagedExternally;
  final bool serperKeyManagedExternally;
  final ManagedToggleSetting providerAutoFailover;

  /// Daemon-owned dictation runtime projection.
  ///
  /// Null when the Agent does not serve this block at all (older Agent), which
  /// is why the section is hidden rather than shown empty.
  final DictationSettingsSetting? dictation;
  final bool restartRequired;

  factory DeviceSettingsSnapshot.fromJson(Map<String, dynamic> json) {
    final webSearch = Map<String, dynamic>.from(json['web_search'] as Map? ?? const {});
    return DeviceSettingsSnapshot(
      cloudConnection: ManagedToggleSetting.fromJson(
        Map<String, dynamic>.from(json['cloud_connection'] as Map? ?? const {}),
      ),
      computerUse: ManagedToggleSetting.fromJson(
        Map<String, dynamic>.from(json['computer_use'] as Map? ?? const {}),
      ),
      computerUsePermissionsGranted: json['computer_use_permissions_granted'] == true,
      webSearchProvider: webSearch['provider']?.toString().trim().toLowerCase() ?? 'ddg',
      serperConfigured: webSearch['serper_configured'] == true,
      webSearchProviderManagedExternally: webSearch['provider_managed_externally'] == true,
      serperKeyManagedExternally: webSearch['serper_key_managed_externally'] == true,
      providerAutoFailover: ManagedToggleSetting.fromJson(
        Map<String, dynamic>.from(json['provider_auto_failover'] as Map? ?? const {}),
      ),
      dictation: json['dictation'] is Map
          ? DictationSettingsSetting.fromJson(
              Map<String, dynamic>.from(json['dictation'] as Map),
            )
          : null,
      restartRequired: json['restart_required'] == true,
    );
  }
}

/// Dictation runtime state as the settings page renders it.
///
/// The page never reads agent configuration itself: enabled, the selected model,
/// readiness, the catalog and the busy flag all come from the daemon, so the
/// page cannot disagree with the mic button.
class DictationSettingsSetting {
  const DictationSettingsSetting({
    required this.enabled,
    required this.managedExternally,
    required this.supported,
    required this.ready,
    required this.busy,
    this.selectedModelId,
    this.reason,
    this.hasModelPath = false,
    this.models = const [],
  });

  final bool enabled;

  /// `stt.enabled` is named by the owner's `config.yaml`, so the page can only
  /// explain the setting instead of changing it.
  final bool managedExternally;
  final bool supported;
  final bool ready;
  final bool busy;
  final String? selectedModelId;
  final String? reason;

  /// True when the Agent's owner pinned `stt.model_path`. The path itself never
  /// leaves the Agent host, so no surface can render or store it.
  final bool hasModelPath;
  final List<DictationModelSizeSetting> models;

  DictationModelSizeSetting? get selectedModel {
    for (final model in models) {
      if (model.id == selectedModelId) return model;
    }
    return null;
  }

  factory DictationSettingsSetting.fromJson(Map<String, dynamic> json) {
    final rawModels = json['models'];
    final models = <DictationModelSizeSetting>[];
    if (rawModels is List) {
      for (final entry in rawModels) {
        if (entry is! Map) continue;
        models.add(
          DictationModelSizeSetting.fromJson(Map<String, dynamic>.from(entry)),
        );
      }
    }
    return DictationSettingsSetting(
      enabled: json['enabled'] == true,
      managedExternally: json['managed_externally'] == true,
      supported: json['supported'] != false,
      ready: json['ready'] == true,
      busy: json['busy'] == true,
      selectedModelId: json['selected_model_id'] as String?,
      reason: json['reason'] as String?,
      hasModelPath: json['has_model_path'] == true,
      models: models,
    );
  }
}

/// One catalog row as the settings page needs it: identity, label code, size.
class DictationModelSizeSetting {
  const DictationModelSizeSetting({
    required this.id,
    this.label,
    this.labelCode,
    this.totalBytes,
    this.installed = false,
  });

  final String id;
  final String? label;
  final String? labelCode;
  final int? totalBytes;
  final bool installed;

  factory DictationModelSizeSetting.fromJson(Map<String, dynamic> json) {
    return DictationModelSizeSetting(
      id: json['id']?.toString() ?? '',
      label: json['label'] as String?,
      labelCode: json['label_code'] as String?,
      totalBytes: (json['total_bytes'] as num?)?.toInt(),
      installed: json['installed'] == true,
    );
  }
}

class DeviceSettingsClient {
  DeviceSettingsClient(this._commands);

  final DeviceCommandClient _commands;

  Future<DeviceSettingsSnapshot> load(DeviceConfig device) async {
    final payload = await _commands.request(
      device: device,
      command: 'device.settings.get',
      expectedEvent: 'device.settings.snapshot',
    );
    return DeviceSettingsSnapshot.fromJson(payload);
  }

  Future<DeviceSettingsSnapshot> update(DeviceConfig device, Map<String, dynamic> changes) async {
    final payload = await _commands.request(
      device: device,
      command: 'device.settings.update',
      expectedEvent: 'device.settings.updated',
      payload: {'changes': changes},
    );
    return DeviceSettingsSnapshot.fromJson(payload);
  }

  Future<bool> requestComputerUsePermissions(DeviceConfig device) async {
    final payload = await _commands.request(
      device: device,
      command: 'system.request_computer_use_permissions',
      expectedEvent: 'system_request_computer_use_permissions_result',
    );
    return payload['granted'] == true;
  }
}
