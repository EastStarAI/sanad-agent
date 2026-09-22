import 'dart:async';

import 'package:logging/logging.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/di.dart';

import '../discovery/local_gateway_discovery.dart';

/// Execution mode for CLI operations.
enum CliRuntimeMode {
  /// Connected to running daemon via WebSocket gateway.
  gateway,

  /// Executing directly in-process when daemon is absent or --standalone is passed.
  standalone,
}

/// Helper that determines whether to attach to a daemon or run in standalone mode.
class StandaloneFallbackStrategy {
  final LocalGatewayDiscovery discovery;
  final _logger = Logger('StandaloneFallbackStrategy');

  StandaloneFallbackStrategy({LocalGatewayDiscovery? discovery})
    : discovery = discovery ?? const LocalGatewayDiscovery();

  /// Resolves the runtime mode based on user options and daemon reachability.
  Future<CliRuntimeMode> resolveMode({
    bool forceStandalone = false,
    String? urlOverride,
    int? portOverride,
    String? tokenOverride,
    Duration probeTimeout = const Duration(milliseconds: 300),
  }) async {
    if (forceStandalone) {
      _logger.info('Standalone mode forced by user flag (--standalone).');
      return CliRuntimeMode.standalone;
    }

    try {
      final result = await discovery.discover(
        urlOverride: urlOverride,
        portOverride: portOverride,
        tokenOverride: tokenOverride,
        probeTimeout: probeTimeout,
      );

      if (result.isDaemonRunning) {
        _logger.info('Discovered active Sanad daemon on port ${result.port}.');
        return CliRuntimeMode.gateway;
      }
    } catch (e) {
      _logger.info(
        'Daemon discovery failed ($e), falling back to standalone mode.',
      );
    }

    _logger.info(
      'No running Sanad daemon detected; using standalone in-process fallback.',
    );
    return CliRuntimeMode.standalone;
  }

  /// Verifies whether the local environment is capable of running standalone mode
  /// (e.g. check if configuration/provider is valid).
  bool canRunStandalone() {
    try {
      if (!getIt.isRegistered<Config>()) {
        return false;
      }
      return getIt<Config>().isValid;
    } catch (_) {
      return false;
    }
  }
}
