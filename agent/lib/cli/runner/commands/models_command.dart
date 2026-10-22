import 'dart:async';
import 'dart:convert' hide json;
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';

import '../../models/provider_selector.dart';
import '../sanad_command.dart';

/// Command to list and inspect available AI models across configured providers.
///
/// `--provider` narrows the report to one configured instance and `--model`
/// narrows it to one cached model inside that selection; both fail closed with
/// a usage error instead of silently reporting an unrelated catalog.
class ModelsCommand extends SanadCommand {
  final ProviderInstanceRepository? repositoryOverride;

  ModelsCommand({super.customAction, this.repositoryOverride}) {
    addCommonOptions(argParser);
  }

  @override
  String get name => 'models';

  @override
  String get description => 'List and inspect available AI models';

  @override
  String get invocation => 'sanad models [options]';

  @override
  Future<int> execute() async {
    final stateHome = getSanadStateHome();
    final dbFile = File(p.join(stateHome, 'state.db'));

    AgentStateDatabase? db;
    try {
      final ProviderInstanceRepository repo;
      if (repositoryOverride != null) {
        repo = repositoryOverride!;
      } else if (dbFile.existsSync()) {
        db = AgentStateDatabase.atPath(stateHome);
        repo = ProviderInstanceRepository(db);
      } else {
        stdoutSink.writeln(
          'No local state database found. Run "sanad setup" to configure providers.',
        );
        return 0;
      }

      final configuredInstances = repo.findAll();
      if (configuredInstances.isEmpty) {
        stdoutSink.writeln('No AI providers configured.');
        stdoutSink.writeln(
          'Run "sanad setup" to add and configure an AI provider.',
        );
        return 0;
      }

      final selected = _selectInstances(configuredInstances);
      if (selected == null) return 2;

      final catalog = <_ProviderCatalog>[
        for (final instance in selected) _buildCatalog(repo, instance),
      ];

      final modelQuery = model?.trim() ?? '';
      final filteredCatalog = modelQuery.isEmpty
          ? catalog
          : _filterByModel(catalog, modelQuery);
      if (filteredCatalog == null) {
        stderrSink.writeln(
          'Error: --model "$modelQuery" is not in the cached catalog for '
          '${catalog.map((entry) => entry.instance.templateId).join(', ')}.',
        );
        return 2;
      }

      if (json) {
        stdoutSink.writeln(
          jsonEncode({
            'schema': 'sanad.models.v1',
            'providers': [
              for (final entry in filteredCatalog) entry.toJson(),
            ],
          }),
        );
        return 0;
      }

      if (!quiet) {
        stdoutSink.writeln('Configured Providers & Available Models:');
      }
      for (final entry in filteredCatalog) {
        _writeHumanBlock(entry);
      }
      return 0;
    } catch (e) {
      stderrSink.writeln('Failed to read model catalog: $e');
      return 1;
    } finally {
      db?.dispose();
    }
  }

  /// Applies `--provider`, or returns every configured instance when unset.
  ///
  /// Returns `null` after reporting a usage error so the caller can exit `2`.
  List<ProviderInstance>? _selectInstances(
    List<ProviderInstance> configuredInstances,
  ) {
    final selector = provider?.trim() ?? '';
    if (selector.isEmpty) return configuredInstances;

    final resolution = ProviderSelector.resolve(configuredInstances, selector);
    switch (resolution) {
      case ProviderSelectorMatch(:final instance):
        return [instance];
      case ProviderSelectorAmbiguous(:final candidates):
        stderrSink.writeln(
          'Error: --provider "$selector" matches ${candidates.length} '
          'providers: ${candidates.map((instance) => instance.displayName).join(', ')}. '
          'Pass one of: ${candidates.map((instance) => instance.id).join(', ')}.',
        );
        return null;
      case ProviderSelectorUnknown(:final acceptedSelectors):
        stderrSink.writeln(
          'Error: --provider "$selector" does not match any configured '
          'provider.',
        );
        stderrSink.writeln(
          'Accepted selectors: ${acceptedSelectors.join(', ')}.',
        );
        return null;
    }
  }

  /// Keeps only providers whose cached catalog contains [modelQuery].
  ///
  /// Returns `null` when no provider serves that model.
  List<_ProviderCatalog>? _filterByModel(
    List<_ProviderCatalog> catalog,
    String modelQuery,
  ) {
    final needle = modelQuery.toLowerCase();
    final matches = <_ProviderCatalog>[];
    for (final entry in catalog) {
      final models = entry.models
          .where((model) => model.value.toLowerCase() == needle)
          .toList(growable: false);
      if (models.isNotEmpty) {
        matches.add(
          _ProviderCatalog(
            instance: entry.instance,
            models: models,
            source: entry.source,
            fetchedAt: entry.fetchedAt,
          ),
        );
      }
    }
    return matches.isEmpty ? null : matches;
  }

  _ProviderCatalog _buildCatalog(
    ProviderInstanceRepository repo,
    ProviderInstance instance,
  ) {
    final cache =
        repo.readModelCache(instance.id, 'models') ??
        repo.readModelCache(instance.id, 'all') ??
        repo.readModelCache(instance.id, 'default');

    final rawModels = cache?['models'];
    if (rawModels is List) {
      return _ProviderCatalog(
        instance: instance,
        models: [
          for (final raw in rawModels) _ModelEntry.fromRaw(raw, instance),
        ],
        source: cache?['source']?.toString(),
        fetchedAt: cache?['fetched_at']?.toString(),
      );
    }

    final defaultModel = instance.defaultModel;
    return _ProviderCatalog(
      instance: instance,
      models: [
        if (defaultModel != null && defaultModel.isNotEmpty)
          _ModelEntry(
            value: defaultModel,
            label: '',
            supportsReasoning: false,
            isDefault: true,
          ),
      ],
      source: cache?['source']?.toString(),
      fetchedAt: cache?['fetched_at']?.toString(),
    );
  }

  void _writeHumanBlock(_ProviderCatalog entry) {
    final instance = entry.instance;
    final defaultBadge = instance.isDefault ? ' [DEFAULT]' : '';
    stdoutSink.writeln(
      '\n• Provider: ${instance.displayName} (${instance.templateId})$defaultBadge',
    );
    final defaultModel = instance.defaultModel;
    if (defaultModel != null && defaultModel.isNotEmpty) {
      stdoutSink.writeln('  Default Model: $defaultModel');
    }
    if (entry.models.isEmpty) {
      stdoutSink.writeln('  Available Models: none cached');
      return;
    }
    stdoutSink.writeln('  Available Models (${entry.models.length}):');
    for (final model in entry.models) {
      final reasoning = model.supportsReasoning ? ' [reasoning]' : '';
      final active = model.isDefault ? ' (active default)' : '';
      if (model.label.isNotEmpty && model.label != model.value) {
        stdoutSink.writeln(
          '    - ${model.value} (${model.label})$reasoning$active',
        );
      } else {
        stdoutSink.writeln('    - ${model.value}$reasoning$active');
      }
    }
  }
}

/// One provider instance plus the models cached for it.
class _ProviderCatalog {
  final ProviderInstance instance;
  final List<_ModelEntry> models;
  final String? source;
  final String? fetchedAt;

  const _ProviderCatalog({
    required this.instance,
    required this.models,
    this.source,
    this.fetchedAt,
  });

  Map<String, dynamic> toJson() => {
    'id': instance.id,
    'template_id': instance.templateId,
    'display_name': instance.displayName,
    'default_model': instance.defaultModel,
    'is_default': instance.isDefault,
    'status': instance.status,
    'catalog_source': source,
    'catalog_fetched_at': fetchedAt,
    'models': [for (final model in models) model.toJson()],
  };
}

/// A single catalog entry, normalized from the cached provider payload.
class _ModelEntry {
  final String value;
  final String label;
  final bool supportsReasoning;
  final bool isDefault;

  const _ModelEntry({
    required this.value,
    required this.label,
    required this.supportsReasoning,
    required this.isDefault,
  });

  factory _ModelEntry.fromRaw(Object? raw, ProviderInstance instance) {
    if (raw is Map) {
      final value = (raw['value'] ?? raw['id'] ?? raw['name'] ?? '').toString();
      final label = (raw['label'] ?? raw['display_name'] ?? '').toString();
      return _ModelEntry(
        value: value,
        label: label == value ? '' : label,
        supportsReasoning: raw['supports_reasoning'] == true,
        isDefault: value == instance.defaultModel,
      );
    }
    final value = raw?.toString() ?? '';
    return _ModelEntry(
      value: value,
      label: '',
      supportsReasoning: false,
      isDefault: value == instance.defaultModel,
    );
  }

  Map<String, dynamic> toJson() => {
    'value': value,
    'label': label,
    'supports_reasoning': supportsReasoning,
    'is_default': isDefault,
  };
}
