import 'package:sanad_agent/core/provider_runtime/env_file_service.dart';
import 'package:sanad_agent/infrastructure/platform/automation_service_factory.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';

import 'support/agent_event_envelope.dart';

/// Handles computer-use permission checks and the computer-use toggle.
class ComputerUseCommandHandler {
  final EnvFileService? _envFileService;

  ComputerUseCommandHandler({EnvFileService? envFileService})
    : _envFileService = envFileService;

  Future<Map<String, dynamic>> buildCheckComputerUsePermissionsEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final service = AutomationServiceFactory.instance;
    final granted = await service.checkPermissions();

    return buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.systemCheckComputerUsePermissionsResult,
        payload: {'request_id': requestId, 'granted': granted},
      ),
    );
  }

  Future<Map<String, dynamic>> buildRequestComputerUsePermissionsEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final service = AutomationServiceFactory.instance;
    final granted = await service.requestPermissions();

    return buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.systemRequestComputerUsePermissionsResult,
        payload: {'request_id': requestId, 'granted': granted},
      ),
    );
  }

  Future<Map<String, dynamic>> buildToggleComputerUseEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final value = event.payload['enabled'] as bool? ?? false;

    await _envFileService?.upsert({'COMPUTER_USE': value.toString()});

    return buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.systemToggleComputerUseResult,
        payload: {'request_id': requestId, 'enabled': value, 'saved': true},
      ),
    );
  }
}
