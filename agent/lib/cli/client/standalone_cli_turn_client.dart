import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../core/auth/auth_manager.dart';
import '../../core/constants.dart';
import '../../core/di.dart';
import '../../core/models/message.dart';
import '../../core/provider_runtime/runtime_recovery_service.dart';
import '../../core/provider_runtime/provider_model_cache_service.dart';
import '../../core/sanad_home/runtime_ownership.dart';
import '../../core/sanad_home/sanad_home_bootstrap.dart';
import '../../evolution/db/agent_state_database.dart';
import '../../evolution/session_manager.dart';
import '../../interfaces/models/agent_turn_request.dart';
import '../../interfaces/models/delivery/models.dart';
import '../../interfaces/models/gateway_event.dart';
import '../../interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import '../../interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import '../../interfaces/runtime/local_workspace_runtime_service.dart';
import '../../interfaces/runtime/platform_runtime_bridge.dart';
import '../../interfaces/runtime/session_run_orchestrator.dart';
import '../models/cli_events.dart';
import 'cli_turn_client.dart';

/// Executes CLI turns directly through the canonical runtime without opening a
/// socket or starting daemon-only transports and schedulers.
class StandaloneCliTurnClient implements CliTurnClient {
  StandaloneCliTurnClient._(
    this._orchestrator,
    this._responseSubscription,
    this._runtimeOwnership,
  );

  static const _platformId = 'standalone_cli';
  static const _descriptor = PlatformDescriptor(
    platformFamily: PlatformFamily.cli,
    transport: PlatformTransport.cli,
    platformInstanceId: _platformId,
  );

  final SessionRunOrchestrator _orchestrator;
  final SanadHomeFileLockLease _runtimeOwnership;
  final StreamController<CliEvent> _events =
      StreamController<CliEvent>.broadcast();
  final Map<String, String> _permissionSessions = {};
  late final StreamSubscription<GatewayResponse> _responseSubscription;
  bool _disposed = false;

  static Future<StandaloneCliTurnClient> start({
    String? sanadHomeOverride,
  }) async {
    if (sanadHomeOverride != null && sanadHomeOverride.trim().isNotEmpty) {
      setSanadHomeOverride(sanadHomeOverride.trim());
    }
    await SanadHomeBootstrap.prepareAll();
    final ownership = await SanadRuntimeOwnership.acquire();
    try {
      if (!getIt.isRegistered<SessionRunOrchestrator>()) {
        setupDI();
      }
      await getIt<AuthManager>().initialize();
      SessionManager();

      final orchestrator = getIt<SessionRunOrchestrator>();
      late final StandaloneCliTurnClient client;
      final subscription = orchestrator.responses.listen((response) {
        client._acceptResponse(response);
      });
      client = StandaloneCliTurnClient._(orchestrator, subscription, ownership);
      getIt<PlatformRuntimeBridge>().attachResponseSink(client._acceptResponse);
      if (getIt.isRegistered<RuntimeRecoveryService>()) {
        getIt<RuntimeRecoveryService>().attachNoticeSink(
          client._acceptRuntimeNotice,
        );
      }
      return client;
    } catch (_) {
      await ownership.release();
      rethrow;
    }
  }

  @override
  Stream<CliEvent> get eventStream => _events.stream;

  @override
  Stream<CliConnectionState> get stateStream => const Stream.empty();

  @override
  Stream<CliAssistantChunkEvent> get assistantStream => eventStream
      .where((event) => event is CliAssistantChunkEvent)
      .cast<CliAssistantChunkEvent>();

  @override
  Stream<CliReasoningDeltaEvent> get reasoningStream => eventStream
      .where((event) => event is CliReasoningDeltaEvent)
      .cast<CliReasoningDeltaEvent>();

  @override
  Stream<CliToolCallEvent> get toolCallStream => eventStream
      .where((event) => event is CliToolCallEvent)
      .cast<CliToolCallEvent>();

  @override
  Stream<CliToolResultEvent> get toolResultStream => eventStream
      .where((event) => event is CliToolResultEvent)
      .cast<CliToolResultEvent>();

  @override
  Stream<CliPermissionRequestEvent> get permissionStream => eventStream
      .where((event) => event is CliPermissionRequestEvent)
      .cast<CliPermissionRequestEvent>();

  @override
  Stream<CliTurnCompleteEvent> get turnCompleteStream => eventStream
      .where((event) => event is CliTurnCompleteEvent)
      .cast<CliTurnCompleteEvent>();

  @override
  Future<String> dispatchTurnRequest(AgentTurnRequest request) async {
    if (_disposed) {
      throw StateError('Standalone CLI runtime is already disposed.');
    }
    final requestId = request.requestId ?? const Uuid().v4();
    final effectiveRequest = request.requestId == null
        ? AgentTurnRequest(
            sessionId: request.sessionId,
            message: request.message,
            workspaceId: request.workspaceId,
            model: request.model,
            providerInstanceId: request.providerInstanceId,
            providerId: request.providerId,
            thinkingMode: request.thinkingMode,
            requestId: requestId,
            deliveryIntent: request.deliveryIntent,
            metadata: request.metadata,
          )
        : request;
    final payload = <String, dynamic>{
      'session_id': effectiveRequest.sessionId,
      'message': effectiveRequest.message,
      'workspace_id': ?effectiveRequest.workspaceId,
      'model': ?effectiveRequest.model,
      'provider_instance_id': ?effectiveRequest.providerInstanceId,
      'provider_id': ?effectiveRequest.providerId,
      'thinking_mode': ?effectiveRequest.thinkingMode,
      'request_id': requestId,
      'delivery_intent': effectiveRequest.deliveryIntent.name,
      if (effectiveRequest.metadata.isNotEmpty)
        'session_metadata': effectiveRequest.metadata,
      if (effectiveRequest.platformTools.isNotEmpty)
        'platform_tools': effectiveRequest.platformTools,
    };
    final origin = OriginContext(
      platformFamily: _descriptor.platformFamily,
      transport: _descriptor.transport,
      platformInstanceId: _platformId,
      platformId: _platformId,
      requestId: requestId,
      sessionId: effectiveRequest.sessionId,
    );
    getIt<PlatformRuntimeBridge>().registerSessionOrigin(
      effectiveRequest.sessionId,
      origin,
    );
    unawaited(
      _orchestrator
          .handleEvent(
            GatewayEvent(
              sessionId: effectiveRequest.sessionId,
              platformId: _platformId,
              message: Message(
                role: MessageRole.user,
                content: effectiveRequest.message,
              ),
              metadata: {'payload': payload},
              runId: requestId,
              turnRequest: effectiveRequest,
              origin: origin,
            ),
          )
          .catchError((Object error, StackTrace stack) {
            if (!_events.isClosed) {
              _events.add(
                CliErrorEvent(
                  message: error.toString(),
                  code: 'standalone_runtime_error',
                  isFatal: true,
                  sessionId: effectiveRequest.sessionId,
                ),
              );
            }
          }),
    );
    return requestId;
  }

  @override
  Future<void> stop({required String sessionId, String? runId}) {
    return _orchestrator.requestStop(
      sessionId,
      forceEmitStopped: true,
      stopRequestId: runId,
    );
  }

  @override
  Future<void> respondPermission({
    required String requestId,
    required bool allowed,
    String scope = 'once',
    String? decision,
    String? answer,
    String? comment,
    String? sessionId,
  }) async {
    final mappedSessionId = _permissionSessions.remove(requestId);
    final effectiveSessionId = sessionId ?? mappedSessionId;
    getIt<PlatformRuntimeBridge>().handleProtocolEvent(
      CanonicalEvent(
        type: CanonicalEventTypes.toolPermissionResponse,
        sessionId: effectiveSessionId,
        payload: {
          'request_id': requestId,
          'allowed': allowed,
          'scope': scope,
          'decision': ?decision,
          'answer': ?answer,
          'comment': ?comment,
          'session_id': ?effectiveSessionId,
        },
      ),
    );
  }

  void _acceptRuntimeNotice(Map<String, dynamic> payload) {
    final sessionId = payload['session_id']?.toString();
    if (_events.isClosed || sessionId == null || sessionId.isEmpty) return;
    _acceptResponse(
      GatewayResponse(
        sessionId: sessionId,
        message: Message(
          role: MessageRole.assistant,
          metadata: {
            'canonical_event_type': payload['status'] == 'cleared'
                ? 'session.runtime_notice_cleared'
                : 'session.runtime_notice',
            'canonical_payload': payload,
          },
        ),
      ),
    );
  }

  void _acceptResponse(GatewayResponse response) {
    if (_events.isClosed) return;
    final canonical = SanadProtocolBridge()
        .translateResponse(response)
        .toJson();
    final event = CliEvent.fromJson(canonical);
    if (event is CliPermissionRequestEvent && event.sessionId != null) {
      _permissionSessions[event.requestId] = event.sessionId!;
    }
    _events.add(event);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    getIt<PlatformRuntimeBridge>().detachResponseSink();
    if (getIt.isRegistered<RuntimeRecoveryService>()) {
      getIt<RuntimeRecoveryService>().attachNoticeSink(null);
    }
    try {
      await _responseSubscription.cancel();
      _orchestrator.dispose();
      await getIt<LocalWorkspaceRuntimeService>().dispose();
      getIt<ProviderModelCacheService>().dispose();
      getIt<AgentStateDatabase>().dispose();
      await _events.close();
    } finally {
      await _runtimeOwnership.release();
    }
  }
}
