import 'dart:async';
import 'dart:convert' hide json;
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
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
      // A single-model inspection is the one place the authority provenance is
      // worth printing: the caller asked about exactly one route.
      final detail = modelQuery.isNotEmpty;
      for (final entry in filteredCatalog) {
        _writeHumanBlock(entry, detail: detail);
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

  void _writeHumanBlock(_ProviderCatalog entry, {bool detail = false}) {
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
      final thinking = _thinkingSummary(model.thinkingControl);
      if (thinking != null) {
        stdoutSink.writeln('      $thinking');
      }
      if (detail) {
        for (final line in _thinkingAuthorityLines(model.thinkingControl)) {
          stdoutSink.writeln('      $line');
        }
      }
    }
  }

  /// One-line summary of the thinking levels this exact route admits.
  ///
  /// Returns `null` when the cached entry carries no descriptor at all, so a
  /// catalog without capability data reads exactly as it did before. A route
  /// that resolved to `unknown` or `unsupported` says so and never lists
  /// levels it does not have.
  String? _thinkingSummary(ThinkingControlDescriptor? control) {
    if (control == null) return null;
    switch (control.status) {
      case ThinkingCapabilityStatus.supported:
        if (control.options.isEmpty) {
          return 'thinking: supported (no declared options)';
        }
        final levels = control.options.map((option) {
          final badges = [
            if (option.isOff) 'off',
            // The effective default is whatever the descriptor names, so a
            // lower layer that filled the default is marked exactly like a
            // native one; the authority is disclosed separately.
            if (option.isProviderDefault ||
                option.id == control.defaultOptionId)
              'default',
          ];
          final id = option.id;
          return badges.isEmpty ? id : '$id [${badges.join(', ')}]';
        }).join(', ');
        final kind = control.kind == null ? '' : ' (${control.kind!.wireValue})';
        return 'thinking: supported$kind — $levels';
      case ThinkingCapabilityStatus.unsupported:
        return 'thinking: unsupported';
      case ThinkingCapabilityStatus.unknown:
        return 'thinking: unknown — no declared levels for this route';
    }
  }

  /// Authority provenance lines, only for a single-model inspection.
  List<String> _thinkingAuthorityLines(ThinkingControlDescriptor? control) {
    if (control == null) {
      return ['thinking source: none recorded for this route'];
    }
    return [
      'thinking source: ${control.source}',
      if (control.defaultOptionId != null)
        'thinking default: ${control.defaultOptionId} '
            '(from ${control.defaultSource ?? control.source})',
      'capability revision: ${control.capabilityRevision}',
    ];
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
///
/// The cached row already carries the thinking capability the daemon resolved
/// for this exact route (five-layer authority, `provider_protocol.md` §2.3).
/// This entry surfaces it instead of dropping it: [thinkingControl] is the
/// stored descriptor, so the CLI reports the same record the Client snapshot
/// does and never re-derives or re-orders any authority layer.
class _ModelEntry {
  final String value;
  final String label;
  final bool supportsReasoning;
  final bool isDefault;
  final ThinkingControlDescriptor? thinkingControl;

  const _ModelEntry({
    required this.value,
    required this.label,
    required this.supportsReasoning,
    required this.isDefault,
    this.thinkingControl,
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
        thinkingControl: _parseThinkingControl(raw['thinking_control']),
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

  /// Parses a cached `thinking_control` member, tolerating a malformed record.
  ///
  /// A catalog read is an inspection path, so one unparsable descriptor must
  /// not fail the whole listing; the entry then reports no control rather than
  /// an invented one.
  static ThinkingControlDescriptor? _parseThinkingControl(Object? raw) {
    if (raw is! Map) return null;
    try {
      return ThinkingControlDescriptor.fromMap(
        raw.map((key, value) => MapEntry(key.toString(), value)),
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> toJson() => {
    'value': value,
    'label': label,
    'supports_reasoning': supportsReasoning,
    'is_default': isDefault,
    if (thinkingControl != null) 'thinking_control': thinkingControl!.toMap(),
  };
}
