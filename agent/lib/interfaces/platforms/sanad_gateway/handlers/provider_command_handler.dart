import 'dart:async';
import 'package:logging/logging.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/provider_runtime/model_options_service.dart';
import 'package:sanad_agent/core/provider_runtime/model_selection_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_auth_session_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_catalog_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_cache_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_id.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_readiness_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_state_service.dart';
import 'package:sanad_agent/core/provider_runtime/recent_model_selection_service.dart';
import 'package:sanad_agent/core/provider_usage/provider_usage_models.dart';
import 'package:sanad_agent/core/provider_usage/provider_usage_service.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';

import '../sanad_protocol_bridge.dart';

/// Handles provider setup, model selection, credentials, auth, and instance
/// lifecycle commands for the Sanad protocol.
class ProviderCommandHandler {
  final _logger = Logger('ProviderCommandHandler');

  final ProviderCatalogService _catalog;
  final ProviderInstanceService _instanceService;
  final ProviderCredentialService _credentialService;
  final ProviderAuthSessionService _authSession;
  final ProviderModelCacheService _cacheService;
  final ProviderInstanceRepository _repository;
  final RecentModelSelectionService _recentService;
  final ModelOptionsService _modelOptions;
  final ModelSelectionService _modelSelection;
  final ProviderReadinessService _readiness;
  final ProviderStateService _state;
  final SanadProtocolBridge _bridge;
  final Config? _config;
  final AgentRuntimeService? _agentRuntime;
  final ProviderUsageService? _usageService;

  ProviderCommandHandler({
    required ProviderCatalogService catalog,
    required ProviderInstanceService instanceService,
    required ProviderCredentialService credentialService,
    required ProviderAuthSessionService authSession,
    required ProviderModelCacheService cacheService,
    required ProviderInstanceRepository repository,
    required RecentModelSelectionService recentService,
    required ModelOptionsService modelOptions,
    required ModelSelectionService modelSelection,
    required ProviderReadinessService readiness,
    required ProviderStateService state,
    required SanadProtocolBridge bridge,
    Config? config,
    AgentRuntimeService? agentRuntime,
    ProviderUsageService? usageService,
  }) : _catalog = catalog,
       _instanceService = instanceService,
       _credentialService = credentialService,
       _authSession = authSession,
       _cacheService = cacheService,
       _repository = repository,
       _recentService = recentService,
       _modelOptions = modelOptions,
       _modelSelection = modelSelection,
       _readiness = readiness,
       _state = state,
       _bridge = bridge,
       _config = config,
       _agentRuntime = agentRuntime,
       _usageService = usageService;

  Map<String, dynamic> buildProviderReadinessEnvelope(
    CanonicalEvent event, {
    required bool isRuntimeCheck,
  }) {
    final result = isRuntimeCheck
        ? _readiness.runtimeCheck()
        : _readiness.setupStatus();
    final requestId = event.payload['request_id'] as String?;
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.providerReadinessResult,
        payload: {'request_id': requestId, ...result.toMap()},
      ),
    );
  }

  Future<Map<String, dynamic>> buildTemplatesListEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final templates = _catalog.catalogMaps();
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.providerTemplatesResult,
        payload: {'request_id': requestId, 'templates': templates},
      ),
    );
  }

  Future<Map<String, dynamic>> buildInstancesListEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;

    final instances = _instanceService.findAll();
    final list = instances.map((instance) {
      final sum = _credentialService.summary(instance.id);
      return {...instance.toMap(), 'credential': sum.toMap()};
    }).toList();

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.providerInstancesResult,
        payload: {'request_id': requestId, 'instances': list},
      ),
    );
  }

  Future<Map<String, dynamic>> buildInstanceCreateEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final templateId = event.payload['template_id'] as String? ?? '';
    final displayName = event.payload['display_name'] as String? ?? '';
    final authMethod = event.payload['auth_method'] as String? ?? '';
    final isDefault = event.payload['is_default'] as bool? ?? false;
    final defaultModel = event.payload['default_model'] as String?;
    final baseUrl = event.payload['base_url'] as String?;
    final protocol = event.payload['protocol'] as String?;
    final requestsPerMinute = event.payload['requests_per_minute'] as int?;
    final allowAutoFailover = event.payload['allow_auto_failover'] as bool?;

    try {
      final created = _instanceService.create(
        templateId: templateId,
        displayName: displayName,
        authMethod: authMethod,
        protocol: protocol,
        baseUrl: baseUrl,
        defaultModel: defaultModel,
        requestsPerMinute: requestsPerMinute,
        allowAutoFailover: allowAutoFailover ?? true,
        makeDefault: isDefault,
      );

      _invalidateRuntimeCache();

      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.providerInstanceCreated,
          payload: {'request_id': requestId, 'instance': created.toMap()},
        ),
      );
    } catch (e) {
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.providerInstanceCreated,
          payload: {'request_id': requestId, 'error': e.toString()},
        ),
      );
    }
  }

  Future<Map<String, dynamic>> buildInstanceUpdateEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final instanceId = event.payload['provider_instance_id'] as String? ?? '';
    final displayName = event.payload['display_name'] as String?;
    final defaultModel = event.payload['default_model'] as String?;
    final baseUrl = event.payload['base_url'] as String?;
    final protocol = event.payload['protocol'] as String?;

    var current = _instanceService.findById(instanceId);
    if (current == null) {
      throw StateError('Instance not found: $instanceId');
    }

    if (displayName != null &&
        displayName.trim().isNotEmpty &&
        displayName != current.displayName) {
      current = _instanceService.rename(instanceId, displayName);
    }
    if (baseUrl != null || defaultModel != null || protocol != null) {
      current = _instanceService.updateMetadata(
        instanceId,
        baseUrl: baseUrl,
        defaultModel: defaultModel,
        protocol: protocol,
      );
      final cred = _credentialService.summary(instanceId);
      _instanceService.reconcileStatus(
        instanceId,
        credentialConfigured: cred.configured,
      );
      current = _instanceService.findById(instanceId);
    }
    final requestsPerMinute = event.payload['requests_per_minute'] as int?;
    final allowAutoFailover = event.payload['allow_auto_failover'] as bool?;
    if (requestsPerMinute != null || allowAutoFailover != null) {
      current = _instanceService.updateMetadata(
        instanceId,
        requestsPerMinute: requestsPerMinute,
        allowAutoFailover: allowAutoFailover,
      );
    }

    _invalidateRuntimeCache();

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.providerInstanceUpdated,
        payload: {'request_id': requestId, 'instance': current!.toMap()},
      ),
    );
  }

  Future<Map<String, dynamic>> buildInstanceRenameEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final instanceId = event.payload['provider_instance_id'] as String? ?? '';
    final displayName = event.payload['display_name'] as String? ?? '';

    final updated = _instanceService.rename(instanceId, displayName);

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.providerInstanceRenamed,
        payload: {'request_id': requestId, 'instance': updated.toMap()},
      ),
    );
  }

  Future<Map<String, dynamic>> buildInstanceRemoveEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final instanceId = event.payload['provider_instance_id'] as String? ?? '';

    await _credentialService.deleteSecret(instanceId);
    _instanceService.delete(instanceId);

    _invalidateRuntimeCache();

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.providerInstanceRemoved,
        payload: {
          'request_id': requestId,
          'provider_instance_id': instanceId,
          'removed': true,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> buildInstanceSetDefaultEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final instanceId = event.payload['provider_instance_id'] as String? ?? '';

    _instanceService.setDefault(instanceId);

    _invalidateRuntimeCache();

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.providerInstanceDefaultChanged,
        payload: {
          'request_id': requestId,
          'provider_instance_id': instanceId,
          'is_default': true,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> buildInstanceTestEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final instanceId = event.payload['provider_instance_id'] as String? ?? '';

    try {
      final models = await _cacheService.refresh(instanceId, manual: true);

      // Check database cache state immediately after manual refresh
      final cache = _repository.readModelCache(instanceId, 'models');
      if (cache != null) {
        if (cache['last_error'] != null) {
          throw StateError(cache['last_error'].toString());
        }
        if (cache['source'] == 'fallback' || cache['source'] == 'cache_stale') {
          throw StateError(
            'Connection failed: fell back to cached or preset models.',
          );
        }
      }

      final configured = _credentialService.summary(instanceId).configured;
      _instanceService.markReadyIfComplete(
        instanceId,
        credentialConfigured: configured,
      );
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.providerInstanceTestResult,
          payload: {
            'request_id': requestId,
            'provider_instance_id': instanceId,
            'success': true,
            'models_count': models.length,
          },
        ),
      );
    } catch (e) {
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.providerInstanceTestResult,
          payload: {
            'request_id': requestId,
            'provider_instance_id': instanceId,
            'success': false,
            'error': e.toString(),
          },
        ),
      );
    }
  }

  Future<Map<String, dynamic>> buildCredentialUpdateEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final instanceId = event.payload['provider_instance_id'] as String? ?? '';
    final action = event.payload['action'] as String? ?? '';
    final apiKey = event.payload['api_key'] as String?;

    try {
      final summary = await _credentialService.applyApiKeyEdit(
        instanceId,
        action: action,
        newApiKey: apiKey,
      );

      _instanceService.reconcileStatus(
        instanceId,
        credentialConfigured: summary.configured,
      );

      _invalidateRuntimeCache();

      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.providerCredentialUpdated,
          payload: {
            'request_id': requestId,
            'provider_instance_id': instanceId,
            'credential': summary.toMap(),
          },
        ),
      );
    } catch (e) {
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.providerCredentialUpdated,
          payload: {
            'request_id': requestId,
            'provider_instance_id': instanceId,
            'error': e.toString(),
          },
        ),
      );
    }
  }

  Future<Map<String, dynamic>> buildAuthReconnectEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final instanceId = event.payload['provider_instance_id'] as String? ?? '';

    final instance = _instanceService.findById(instanceId);
    if (instance == null) {
      throw StateError('Instance not found: $instanceId');
    }

    try {
      final start = await _authSession.reconnectForInstance(
        instanceId: instanceId,
        templateId: instance.templateId,
        authMethod: instance.authMethod,
      );
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.providerAuthStarted,
          payload: {'request_id': requestId, ...start.toMap()},
        ),
      );
    } catch (e) {
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.providerAuthStarted,
          payload: {'request_id': requestId, 'error': e.toString()},
        ),
      );
    }
  }

  Future<Map<String, dynamic>> buildAuthDisconnectEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final instanceId = event.payload['provider_instance_id'] as String? ?? '';

    await _authSession.disconnectForInstance(instanceId);
    _instanceService.markNeedsAuth(instanceId);

    _invalidateRuntimeCache();

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.providerInstanceUpdated,
        payload: {
          'request_id': requestId,
          'provider_instance_id': instanceId,
          'disconnected': true,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> buildModelSnapshotEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;

    final instances = _instanceService.findAll();
    final defaultInstance = _instanceService.findDefault();

    final list = instances.map((instance) {
      final row = _repository.readModelCache(instance.id, 'models');
      String cacheStatus = 'empty';
      String? fetchedAtStr;
      String? warning;
      List<dynamic> cachedModels = [];

      if (row != null) {
        final configMatch = row['config_revision'] == instance.configRevision;
        final credentialMatch =
            row['credential_revision'] == instance.credentialRevision;

        if (!configMatch || !credentialMatch) {
          cacheStatus = 'stale';
        } else {
          cacheStatus = 'ready';
        }

        final fetchedAt = row['fetched_at'];
        if (fetchedAt is String) {
          fetchedAtStr = fetchedAt;
        } else if (fetchedAt is int) {
          fetchedAtStr = DateTime.fromMillisecondsSinceEpoch(
            fetchedAt,
          ).toIso8601String();
        }

        if (row['last_error'] != null) {
          warning = row['last_error'].toString();
          final models = row['models'] as List?;
          if (models == null || models.isEmpty) {
            cacheStatus = 'error';
          }
        }

        final modelsList = row['models'] as List?;
        if (modelsList != null) {
          cachedModels = modelsList;
        }
      }

      return {
        'id': instance.id,
        'display_name': instance.displayName,
        'default_model': _normalizeModelIdForInstance(
          instance.templateId,
          instance.protocol,
          instance.defaultModel,
        ),
        'status': instance.status,
        'is_default': instance.isDefault,
        'cache_status': cacheStatus,
        'fetched_at': fetchedAtStr,
        'warning': warning,
        'models': _normalizeCachedModels(
          cachedModels,
          templateId: instance.templateId,
          protocol: instance.protocol,
        ),
      };
    }).toList();

    final recent = _recentService.getRecentSelections().map((entry) {
      final instanceId = entry['instance_id']?.toString() ?? '';
      final instance = _instanceService.findById(instanceId);
      if (instance == null) {
        return entry;
      }
      return {
        ...entry,
        'model_id': _normalizeModelIdForInstance(
          instance.templateId,
          instance.protocol,
          entry['model_id']?.toString(),
        ),
      };
    }).toList();

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.modelSnapshotResult,
        payload: {
          'request_id': requestId,
          'instances': list,
          'recent': recent,
          'default_instance_id': defaultInstance?.id,
        },
      ),
    );
  }

  Future<void> handleModelRefreshCommand(
    CanonicalEvent event,
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  ) async {
    final instanceId = event.payload['provider_instance_id'] as String? ?? '';
    final manual = (event.payload['manual'] as bool?) ?? false;
    final requestId = event.payload['request_id'] as String?;

    await emitEnvelope(
      _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.modelCacheUpdated,
          payload: {
            'provider_instance_id': instanceId,
            'status': 'started',
            ...?requestId == null ? null : {'request_id': requestId},
          },
        ),
      ),
    );

    unawaited(
      _completeModelRefresh(
        instanceId: instanceId,
        manual: manual,
        requestId: requestId,
        emitEnvelope: emitEnvelope,
      ),
    );
  }

  Future<void> _completeModelRefresh({
    required String instanceId,
    required bool manual,
    required String? requestId,
    required Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  }) async {
    late final CanonicalEvent terminalEvent;
    try {
      await _cacheService.refresh(instanceId, manual: manual);

      final row = _repository.readModelCache(instanceId, 'models');
      final cachedModels = row?['models'] as List<dynamic>? ?? const [];
      terminalEvent = CanonicalEvent(
        type: CanonicalEventTypes.modelCacheUpdated,
        payload: {
          'provider_instance_id': instanceId,
          'status': 'updated',
          'models': cachedModels,
          ...?requestId == null ? null : {'request_id': requestId},
        },
        delivery: const DeliveryPolicy.platformFamily(
          PlatformFamily.sanadClient,
        ),
      );
    } catch (error, stackTrace) {
      _logger.warning('Model cache refresh failed: $error', error, stackTrace);
      terminalEvent = CanonicalEvent(
        type: CanonicalEventTypes.modelCacheUpdated,
        payload: {
          'provider_instance_id': instanceId,
          'status': 'failed',
          'error': error.toString(),
          ...?requestId == null ? null : {'request_id': requestId},
        },
        delivery: const DeliveryPolicy.platformFamily(
          PlatformFamily.sanadClient,
        ),
      );
    }

    try {
      await emitEnvelope(_bridge.buildAgentEventEnvelope(terminalEvent));
    } catch (error, stackTrace) {
      _logger.warning(
        'Failed to emit terminal model cache refresh event: $error',
        error,
        stackTrace,
      );
    }
  }

  Future<Map<String, dynamic>> buildModelRecentListEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final recent = _recentService.getRecentSelections().map((entry) {
      final instanceId = entry['instance_id']?.toString() ?? '';
      final instance = _instanceService.findById(instanceId);
      if (instance == null) {
        return entry;
      }
      return {
        ...entry,
        'model_id': _normalizeModelIdForInstance(
          instance.templateId,
          instance.protocol,
          entry['model_id']?.toString(),
        ),
      };
    }).toList();

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.modelRecentResult,
        payload: {'request_id': requestId, 'recent': recent},
      ),
    );
  }

  Future<Map<String, dynamic>> buildModelRecentRecordEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final instanceId = event.payload['provider_instance_id'] as String? ?? '';
    final modelId = event.payload['model_id'] as String? ?? '';

    _recentService.selectModel(instanceId: instanceId, modelId: modelId);

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.modelRecentRecorded,
        payload: {
          'request_id': requestId,
          'provider_instance_id': instanceId,
          'model_id': modelId,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> buildProviderAuthStartEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final providerId = event.payload['provider_id'] as String? ?? '';
    final instanceId = event.payload['provider_instance_id'] as String?;
    final templateId = event.payload['template_id'] as String? ?? providerId;
    final authMethod =
        event.payload['auth_method'] as String? ??
        ProviderAuthMethod.deviceCode;

    try {
      if (instanceId == null || instanceId.isEmpty) {
        throw StateError(
          'provider_instance_id is required for provider.auth.start.',
        );
      }
      final start = await _authSession.startForInstance(
        instanceId: instanceId,
        templateId: templateId,
        authMethod: authMethod,
      );

      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.providerAuthStarted,
          payload: {'request_id': requestId, ...start.toMap()},
        ),
      );
    } catch (e) {
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.providerAuthStarted,
          payload: {'request_id': requestId, 'error': e.toString()},
        ),
      );
    }
  }

  Future<Map<String, dynamic>> buildProviderAuthPollEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final sessionId = event.payload['session_id'] as String? ?? '';

    final poll = await _authSession.poll(sessionId);
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.providerAuthPolled,
        payload: {
          'request_id': requestId,
          'session_id': sessionId,
          ...poll.toMap(),
        },
      ),
    );
  }

  Future<Map<String, dynamic>> buildProviderAuthSubmitEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final sessionId = event.payload['session_id'] as String? ?? '';
    final code = event.payload['code'] as String? ?? '';

    final poll = await _authSession.submitCode(sessionId, code);
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.providerAuthPolled,
        payload: {
          'request_id': requestId,
          'session_id': sessionId,
          ...poll.toMap(),
        },
      ),
    );
  }

  Map<String, dynamic> buildProviderAuthCancelEnvelope(CanonicalEvent event) {
    final requestId = event.payload['request_id'] as String?;
    final sessionId = event.payload['session_id'] as String? ?? '';

    _authSession.cancel(sessionId);
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.providerAuthCancelled,
        payload: {
          'request_id': requestId,
          'session_id': sessionId,
          'cancelled': true,
        },
      ),
    );
  }

  Map<String, dynamic> buildProviderAuthStatusEnvelope(CanonicalEvent event) {
    final requestId = event.payload['request_id'] as String?;
    final providerId = event.payload['provider_id'] as String? ?? '';
    final instanceId = event.payload['provider_instance_id'] as String?;

    final status = (instanceId != null && instanceId.isNotEmpty)
        ? _authSession.statusForInstance(instanceId)
        : _authSession.statusFor(providerId);

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.providerAuthStatusResult,
        payload: {
          'request_id': requestId,
          'provider_id': providerId,
          ...?instanceId == null ? null : {'provider_instance_id': instanceId},
          'status': status,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> buildModelOptionsEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final providerId = event.payload['provider_id'] as String?;
    final fetchLive = (event.payload['fetch_live'] as bool?) ?? false;

    if (providerId != null) {
      final result = await _modelOptions.optionsFor(
        providerId,
        fetchLive: fetchLive,
      );
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.modelOptionsResult,
          payload: {
            'request_id': requestId,
            'options': [result.toMap()],
          },
        ),
      );
    }
    final all = await _modelOptions.allOptions(fetchLive: fetchLive);
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.modelOptionsResult,
        payload: {'request_id': requestId, 'options': all},
      ),
    );
  }

  Map<String, dynamic> buildModelRecommendedDefaultEnvelope(
    CanonicalEvent event,
  ) {
    final requestId = event.payload['request_id'] as String?;
    final providerId = event.payload['provider_id'] as String? ?? '';

    final model = _modelSelection.recommendedDefault(providerId);
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.modelRecommendedDefaultResult,
        payload: {
          'request_id': requestId,
          'provider_id': providerId,
          'model': model,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> buildModelSetDefaultEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final providerId = event.payload['provider_id'] as String? ?? '';
    final model = event.payload['model'] as String? ?? '';
    final baseUrl = event.payload['base_url'] as String?;
    final apiKey = event.payload['api_key'] as String?;

    await _modelSelection.setDefault(
      providerId: providerId,
      model: model,
      baseUrl: baseUrl,
      apiKey: apiKey,
    );

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.modelSetDefaultResult,
        payload: {
          'request_id': requestId,
          'provider_id': providerId,
          'model': model,
          'saved': true,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> buildProviderConfiguredOptionsEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final fetchLive = (event.payload['fetch_live'] as bool?) ?? false;

    final configured = _state.configuredStates();
    final groups = <Map<String, dynamic>>[];
    for (final s in configured) {
      try {
        final result = await _modelOptions.optionsFor(
          s.id,
          fetchLive: fetchLive,
        );
        groups.add({
          'provider_id': s.id,
          'display_name': s.displayName,
          'runtime_ready': s.authenticated,
          'models': result.toMap(),
        });
      } catch (_) {
        groups.add({
          'provider_id': s.id,
          'display_name': s.displayName,
          'runtime_ready': s.authenticated,
          'models': const {},
          'live_fetch_failed': true,
        });
      }
    }

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.providerConfiguredOptionsResult,
        payload: {'request_id': requestId, 'groups': groups},
      ),
    );
  }

  Future<Map<String, dynamic>> buildCapabilitiesChangedEnvelope(
    CanonicalEvent event,
  ) async {
    final configured = _state.configuredStates();
    final groups = <Map<String, dynamic>>[];
    for (final s in configured) {
      try {
        final result = await _modelOptions.optionsFor(s.id);
        groups.add({
          'provider_id': s.id,
          'display_name': s.displayName,
          'runtime_ready': s.authenticated,
          'models': result.toMap(),
        });
      } catch (_) {
        groups.add({
          'provider_id': s.id,
          'display_name': s.displayName,
          'runtime_ready': s.authenticated,
          'models': const {},
          'live_fetch_failed': true,
        });
      }
    }

    final activeProvider = _state.resolveActiveProviderId();
    final activeModel = _config?.llmModel ?? '';

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.capabilitiesChanged,
        payload: {
          'configured_providers': groups,
          'active_provider': activeProvider,
          'active_model': activeModel,
        },
        delivery: const DeliveryPolicy.platformFamily(
          PlatformFamily.sanadClient,
        ),
      ),
    );
  }

  Future<Map<String, dynamic>> buildInstancesChangedBroadcastEnvelope() async {
    final instances = _instanceService.findAll();
    final list = instances.map((instance) {
      final sum = _credentialService.summary(instance.id);
      return {...instance.toMap(), 'credential': sum.toMap()};
    }).toList();

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.providerInstancesChanged,
        payload: {'instances': list},
        delivery: const DeliveryPolicy.platformFamily(
          PlatformFamily.sanadClient,
        ),
      ),
    );
  }

  void _invalidateRuntimeCache() {
    _agentRuntime?.invalidate();
  }

  List<dynamic> _normalizeCachedModels(
    List<dynamic> cachedModels, {
    required String templateId,
    required String protocol,
  }) {
    return cachedModels
        .map((entry) {
          if (entry is! Map) {
            return entry;
          }
          final map = Map<String, dynamic>.from(entry);
          final rawValue = map['value']?.toString();
          if (rawValue == null || rawValue.isEmpty) {
            return map;
          }
          return {
            ...map,
            'value': ProviderModelId.normalize(
              templateId: templateId,
              protocol: protocol,
              rawModelId: rawValue,
            ),
          };
        })
        .toList(growable: false);
  }

  // ── Task 55: Provider account usage limits ─────────────────────────────

  /// Builds the `provider.usage.result` envelope for a `provider.usage.get`
  /// command. Delegates to [ProviderUsageService] when registered; otherwise
  /// returns `unsupported` for every instance so the client hides the section
  /// cleanly without an error (Task 55 §3.4).
  Future<Map<String, dynamic>> buildUsageGetEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final instanceId = event.payload['provider_instance_id'] as String? ?? '';

    final result =
        _usageService != null
              ? await _usageService.getUsage(
                  instanceId: instanceId,
                  requestId: requestId,
                )
              : ProviderUsageResult.unsupported(instanceId)
          ..requestId = requestId;

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.providerUsageResult,
        payload: result.toMap(),
      ),
    );
  }

  Future<Map<String, dynamic>> buildUsageResetEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final instanceId = event.payload['provider_instance_id'] as String? ?? '';
    final idempotencyKey = event.payload['idempotency_key'] as String? ?? '';
    final confirmationToken = event.payload['confirmation_token'] as String?;
    final result = _usageService == null
        ? ProviderUsageResetResult(
            status: ProviderUsageResetStatus.unsupported,
            providerInstanceId: instanceId,
            requestId: requestId,
            message: 'Usage resets are not supported for this account.',
          )
        : await _usageService.resetUsage(
            instanceId: instanceId,
            idempotencyKey: idempotencyKey,
            requestId: requestId,
            confirmationToken: confirmationToken,
          );
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.providerUsageResetResult,
        payload: result.toMap(),
      ),
    );
  }

  /// Builds the `provider.usage.support_result` envelope. Returns a per-instance
  /// map of `supported` flags so the client can decide which instances warrant
  /// a `Usage & limits` disclosure without issuing a full fetch for each one
  /// (Task 55 §3.5).
  Future<Map<String, dynamic>> buildUsageSupportEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;

    final instanceIds =
        (event.payload['provider_instance_ids'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];

    final support = <String, bool>{};
    if (_usageService != null) {
      for (final id in instanceIds) {
        support[id] = _usageService.supportsUsage(id);
      }
    }

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.providerUsageSupportResult,
        payload: {'request_id': requestId, 'support': support},
      ),
    );
  }

  String? _normalizeModelIdForInstance(
    String templateId,
    String protocol,
    String? rawModelId,
  ) {
    if (rawModelId == null || rawModelId.isEmpty) {
      return rawModelId;
    }
    return ProviderModelId.normalize(
      templateId: templateId,
      protocol: protocol,
      rawModelId: rawModelId,
    );
  }
}
