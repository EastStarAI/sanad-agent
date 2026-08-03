import 'dart:async';

import 'package:logging/logging.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/sanad_home/loopback_policy.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/interfaces/gateway_manager.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/evolution/cron_scheduler.dart';
import 'package:sanad_agent/evolution/title_service.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_daemon_server_platform.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_security.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/server_sanad_gateway_platform.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';

import 'package:sanad_agent/core/utils/logger.dart';

Future<void> main(List<String> args) async {
  // Must run before DI/config/auth can read or open anything under either
  // configured runtime root. The outer CLI also performs this for supervised
  // launches; keeping it here protects direct daemon entry points and tests.
  await SanadHomeBootstrap.migrateLegacy();
  setupDI();

  final config = getIt<Config>();
  initLogger(config);

  print('--- Sanad Agent Daemon ---');

  await getIt<AuthManager>().initialize();
  final gatewayManager = getIt<GatewayManager>();

  // Register platforms
  if (config.enableGateway) {
    gatewayManager.registerPlatform(getIt<ServerSanadGatewayPlatform>());
  } else {
    print('Sanad Gateway Platform is disabled via configuration.');
  }

  if (config.enableLocalGateway) {
    // SEC-02 / Gate B: load or create the local gateway credential,
    // enforce loopback bind policy, and wire the security helper into
    // the platform so every HTTP and WebSocket request is gated.
    if (!LoopbackPolicy.isLoopbackHost(config.localGatewayHost)) {
      final logger = Logger('DaemonStartup');
      logger.severe(
        'Refusing to start Local Gateway on a non-loopback host. '
        'SEC-02 requires loopback-only.',
      );
      throw LocalGatewayBindViolation(config.localGatewayHost);
    }
    final credential = await LocalGatewayCredentials.loadOrCreate();
    final security = LocalGatewaySecurity(
      config: LocalGatewaySecurityConfig(allowedPort: config.localGatewayPort),
      expectedToken: credential,
    );
    gatewayManager.registerPlatform(
      LocalDaemonServerPlatform(security: security),
    );
  } else {
    print('Local Gateway Platform is disabled via configuration.');
  }

  gatewayManager.registerPlatform(getIt<CronScheduler>());

  // Future: Register more platforms (e.g., SocketPlatform, WebhookPlatform)

  // Gate F.1 — wire the gateway manager to the orchestrator's response +
  // notice streams BEFORE calling `restorePersistedState()` so that any
  // queue-only bootstrap drained during restore (which fires responses and
  // notices asynchronously via `Future.microtask`) is delivered to the
  // registered platforms instead of being dropped on a broadcast stream with
  // zero subscribers.
  gatewayManager.attachOrchestrator();

  await _restoreDurableStateSafely(getIt<SessionRunOrchestrator>());

  print('Starting Gateway Manager...');
  await gatewayManager.start();
  unawaited(_recoverPendingTitlesSafely(getIt<TitleService>()));

  print(
    'Daemon is running. Press Ctrl+C to stop (if not in interactive mode).',
  );

  // Keep the process alive if needed, though CliPlatform has its own loop.
  // ProcessSignal.sigint.watch().listen((_) async {
  //   print('\nShutting down...');
  //   await gatewayManager.stop();
  //   exit(0);
  // });
}

Future<void> _recoverPendingTitlesSafely(TitleService titleService) async {
  final logger = Logger('DaemonStartup');
  try {
    await titleService.recoverPendingTitles();
  } catch (error, stack) {
    logger.warning(
      'Failed to recover pending session titles; sessions remain eligible for a later terminal turn.',
      error,
      stack,
    );
  }
}

/// Gate F.1 — calls `SessionRunOrchestrator.restorePersistedState()` exactly
/// once during startup after Gates C-E ship durable work state, safe
/// continuation checkpoints, and a tested recovery service. Failure is
/// isolated to a logged error: the daemon stays up so the operator can
/// surface a blocked-state UI banner instead of crashing into a silent,
/// empty state where the client cannot reach the orchestrator at all.
Future<void> _restoreDurableStateSafely(
  SessionRunOrchestrator orchestrator,
) async {
  final logger = Logger('DaemonStartup');
  try {
    await orchestrator.restorePersistedState();
    logger.info('Durable state restored from session_work_items.');
  } catch (error, stack) {
    orchestrator.markRestoreFailureAsBlocked(error: error);
    logger.severe(
      'Failed to restore durable state on startup. '
      'Daemon converted persisted work into blocked startup-recovery notices '
      'so the client can retry, change provider, or stop instead of silently '
      'continuing with an unknown state.',
      error,
      stack,
    );
  }
}
