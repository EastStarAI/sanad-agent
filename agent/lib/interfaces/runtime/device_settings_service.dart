import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/provider_runtime/env_file_service.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/infrastructure/stt/dictation_service.dart';

class DeviceSettingsUpdate {
  const DeviceSettingsUpdate({
    required this.snapshot,
    required this.restartRequired,
  });

  final Map<String, dynamic> snapshot;
  final bool restartRequired;
}

/// Whitelisted, agent-owned runtime settings exposed through the Sanad
/// protocol. Secrets are accepted for mutation but never returned.
class DeviceSettingsService {
  DeviceSettingsService({
    required Config config,
    required EnvFileService envFileService,
    required RuntimeRecoveryService runtimeRecovery,
    DictationService? dictation,
  }) : _config = config,
       _envFileService = envFileService,
       _runtimeRecovery = runtimeRecovery,
       _dictation = dictation;

  static const supportedWebSearchProviders = {'ddg', 'serper'};

  final Config _config;
  final EnvFileService _envFileService;
  final RuntimeRecoveryService _runtimeRecovery;

  /// The same daemon dictation owner the mic and the hosted relay use, so the
  /// settings page reports the readiness the user actually has.
  final DictationService? _dictation;

  Map<String, dynamic> snapshot() => {
    'cloud_connection': {
      'enabled': _config.enableGateway,
      'managed_externally': _config.isProcessManaged('ENABLE_GATEWAY'),
    },
    'computer_use': {
      'enabled': _config.computerUse,
      'managed_externally': _config.isProcessManaged('COMPUTER_USE'),
    },
    'web_search': {
      'provider': _config.webSearchProvider,
      'serper_configured': _config.serperApiKey.isNotEmpty,
      'provider_managed_externally': _config.isProcessManaged(
        'WEB_SEARCH_PROVIDER',
      ),
      'serper_key_managed_externally': _config.isProcessManaged(
        'SERPER_API_KEY',
      ),
    },
    'provider_auto_failover': {
      'enabled': _runtimeRecovery.autoFailoverEnabled,
      'managed_externally': _config.isProcessManaged('PROVIDER_AUTO_FAILOVER'),
    },
    // Additive block inside the existing settings family: the dictation runtime
    // is daemon-owned, so the page reads its enabled/model/size/reason here
    // instead of reading agent configuration itself.
    if (_dictation != null) 'dictation': _dictation.settingsSnapshot(),
  };

  Future<DeviceSettingsUpdate> update(Map<String, dynamic> changes) async {
    if (changes.isEmpty) {
      throw const FormatException('At least one setting change is required.');
    }

    const allowed = {
      'cloud_connection_enabled',
      'computer_use_enabled',
      'web_search_provider',
      'serper_api_key',
      'provider_auto_failover_enabled',
      'dictation_enabled',
      'dictation_model_id',
    };
    final unknown = changes.keys.where((key) => !allowed.contains(key));
    if (unknown.isNotEmpty) {
      throw FormatException('Unsupported device setting: ${unknown.first}');
    }

    final updates = <String, String>{};
    var restartRequired = false;

    void requireWritable(String setting, String envKey) {
      if (_config.isProcessManaged(envKey)) {
        throw StateError('$setting is managed by the process environment.');
      }
    }

    bool requireBool(String key) {
      final value = changes[key];
      if (value is! bool) {
        throw FormatException('$key must be a boolean.');
      }
      return value;
    }

    if (changes.containsKey('cloud_connection_enabled')) {
      requireWritable('Cloud Connection', 'ENABLE_GATEWAY');
      updates['ENABLE_GATEWAY'] = requireBool(
        'cloud_connection_enabled',
      ).toString();
      restartRequired = true;
    }
    if (changes.containsKey('computer_use_enabled')) {
      requireWritable('Computer Use', 'COMPUTER_USE');
      updates['COMPUTER_USE'] = requireBool('computer_use_enabled').toString();
    }
    if (changes.containsKey('web_search_provider')) {
      requireWritable('Web Search provider', 'WEB_SEARCH_PROVIDER');
      final provider = changes['web_search_provider'];
      if (provider is! String ||
          !supportedWebSearchProviders.contains(provider.toLowerCase())) {
        throw const FormatException(
          'web_search_provider must be ddg or serper.',
        );
      }
      updates['WEB_SEARCH_PROVIDER'] = provider.toLowerCase();
    }
    if (changes.containsKey('serper_api_key')) {
      requireWritable('Serper API key', 'SERPER_API_KEY');
      final apiKey = changes['serper_api_key'];
      if (apiKey is! String) {
        throw const FormatException('serper_api_key must be a string.');
      }
      updates['SERPER_API_KEY'] = apiKey.trim();
    }
    if (changes.containsKey('provider_auto_failover_enabled')) {
      requireWritable('Provider Auto Failover', 'PROVIDER_AUTO_FAILOVER');
      updates['PROVIDER_AUTO_FAILOVER'] = requireBool(
        'provider_auto_failover_enabled',
      ).toString();
    }

    // Dictation is persisted by its own owner (never by hand-editing the agent
    // configuration), so its changes are applied before the environment file is
    // touched and cannot partially land with an invalid mixed request.
    final dictationEnabled = changes.containsKey('dictation_enabled')
        ? requireBool('dictation_enabled')
        : null;
    final dictationModelId = changes.containsKey('dictation_model_id')
        ? changes['dictation_model_id']
        : null;
    if (changes.containsKey('dictation_model_id') &&
        (dictationModelId is! String || dictationModelId.trim().isEmpty)) {
      throw const FormatException('dictation_model_id must be a model id.');
    }
    final dictation = _dictation;
    if (dictationEnabled != null || dictationModelId != null) {
      if (dictation == null) {
        throw StateError('This agent does not run dictation.');
      }
      if (dictationEnabled != null) {
        await dictation.applyEnabled(dictationEnabled);
      }
      if (dictationModelId is String) {
        await dictation.selectModel(dictationModelId.trim());
      }
    }

    // Validation completes before the single environment-file mutation so an
    // invalid mixed request cannot partially apply. A dictation-only change
    // writes no environment key, so it never touches the file.
    if (updates.isNotEmpty) {
      await _envFileService.upsert(updates);
      _config.reload();
    }
    if (changes.containsKey('provider_auto_failover_enabled')) {
      _runtimeRecovery.autoFailoverEnabled =
          changes['provider_auto_failover_enabled'] as bool;
    }

    return DeviceSettingsUpdate(
      snapshot: snapshot(),
      restartRequired: restartRequired,
    );
  }
}
