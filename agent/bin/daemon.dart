import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:sanad_agent/core/auth/secret_vault.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/sanad_home/loopback_policy.dart';
import 'package:sanad_agent/core/sanad_home/runtime_ownership.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/core/sanad_home/test_runtime_isolation.dart';
import 'package:sanad_agent/interfaces/gateway_manager.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/evolution/cron_scheduler.dart';
import 'package:sanad_agent/evolution/db/agent_state_maintenance_service.dart';
import 'package:sanad_agent/evolution/title_service.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/delivery_presence_controller.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_daemon_server_platform.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_endpoint_record.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_security.dart';
import 'package:sanad_agent/engine/adapters/models_dev_service.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/server_sanad_gateway_platform.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:sanad_agent/core/termination_cleanup.dart';

import 'package:sanad_agent/core/utils/logger.dart';

SanadHomeFileLockLease? _runtimeOwnership;

Future<void> main(List<String> args) async {
  // The daemon keeps the normal macOS Keychain prompt at every entry point: it
  // is the process that migrates legacy secret files, an operator starts it, and
  // its authorization dialog is the intended way to grant access. It therefore
  // never inherits the CLI's stdio-shaped detection, and a vault that closes
  // here is reported through the log and the local gateway `/health` payload.
  SecretVaultPolicy.apply(
    SecretVaultPolicy.daemonEntryDecision,
    vaultSkipped: false,
  );
  // Must run before DI/config/auth can read or open anything under either
  // configured runtime root. The outer CLI also performs this for supervised
  // launches; keeping it here protects direct daemon entry points and tests.
  requireSanadE2eTestIsolation();
  await SanadHomeBootstrap.prepareAll();
  _runtimeOwnership ??= await SanadRuntimeOwnership.acquire();
  setupDI();

  final config = getIt<Config>();
  initLogger(config);

  // Plan 83: open the Agent vault (migrating legacy secret files) after
  // logging starts and before any service resolves a secret, replay vault
  // events a CLI recorded without a log, and follow other processes' writes.
  final vaults = await SecretVaults.open();
  vaults.startWatching();
  SecretVaults.drainStartupEvents();
  if (!vaults.available) {
    Logger('DaemonStartup').warning(_agentVaultUnavailableMessage(vaults));
  }

  print('--- Sanad Agent Daemon ---');

  await getIt<AuthManager>().initialize();
  try {
    await getIt<ModelsDevService>().ensureLoaded();
  } catch (e) {
    Logger('DaemonStartup').warning('Failed to hydrate models.dev catalog: $e');
  }
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
    //
    // This is the only rotation point in the system, and it runs here on
    // purpose: after `SanadRuntimeOwnership.acquire()` above, so this process
    // provably owns the Home, and before the listener serves, so rotating a
    // cloned or legacy credential cannot invalidate a credential another live
    // daemon is still using. No CLI, login, or sanad-dev path may rotate.
    if (!LoopbackPolicy.isLoopbackHost(config.localGatewayHost)) {
      final logger = Logger('DaemonStartup');
      logger.severe(
        'Refusing to start Local Gateway on a non-loopback host. '
        'SEC-02 requires loopback-only.',
      );
      throw LocalGatewayBindViolation(config.localGatewayHost);
    }
    final credential =
        await LocalGatewayCredentials.loadOrCreateForDaemonStart();
    final security = LocalGatewaySecurity(
      config: LocalGatewaySecurityConfig(allowedPort: config.localGatewayPort),
      expectedToken: credential,
    );
    gatewayManager.registerPlatform(
      LocalDaemonServerPlatform(
        security: security,
        deliveryPresence: getIt<DeliveryPresenceController>(),
        viewImageMediaHistoryLoader: getIt<SessionManager>().getMessages,
      ),
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
  _installEndpointRecordCleanup();
  unawaited(_recoverPendingTitlesSafely(getIt<TitleService>()));

  print(
    'Daemon is running. Press Ctrl+C to stop (if not in interactive mode).',
  );

  // Task 65 — maintenance starts only after durable restore, transports, and
  // the readiness signal. It waits for a grace period and runtime idleness,
  // then yields between bounded delete batches.
  unawaited(runAgentStateMaintenanceSafely());

  // Keep the process alive if needed, though CliPlatform has its own loop.
  // ProcessSignal.sigint.watch().listen((_) async {
  //   print('\nShutting down...');
  //   await gatewayManager.stop();
  //   exit(0);
  // });
}

/// Removes this Home's published endpoint record when the daemon stops.
///
/// The daemon had no termination hook, so `sanad-dev stop` (SIGTERM) or Ctrl+C
/// left `.local_gateway_endpoint.json` naming a pid that no longer existed.
/// The same hook is the coordinator's pre-exit cleanup, so a managed pause or
/// stop removes the record as well. Removal is ownership-checked, so a
/// successor runtime that already republished the record keeps it.
void _installEndpointRecordCleanup() {
  TerminationCleanup(
    cleanup: LocalGatewayEndpointRecord.removeOwnedOnExit,
  ).install();
}

/// Resolves and runs deferred database maintenance without allowing any
/// maintenance-specific failure to affect the ready daemon.
Future<void> runAgentStateMaintenanceSafely({
  AgentStateMaintenanceService Function()? resolveService,
  bool Function()? hasRuntimeActivity,
  Logger? logger,
}) async {
  try {
    final service =
        (resolveService ?? () => getIt<AgentStateMaintenanceService>())();
    final activity =
        hasRuntimeActivity ??
        () => getIt<SessionRunOrchestrator>().hasMaintenanceBlockingActivity;
    await service.runAfterReady(hasRuntimeActivity: activity);
  } catch (error, stack) {
    (logger ?? Logger('DaemonStartup')).warning(
      'Deferred agent state maintenance failed; daemon remains available.',
      error,
      stack,
    );
  }
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
  if (getIt.isRegistered<CompactionBoundaryRepository>()) {
    try {
      final recovered = getIt<CompactionBoundaryRepository>()
          .reconcileOrphanedStartedOperations();
      if (recovered > 0) {
        logger.info(
          'Reconciled $recovered orphaned compaction operation(s) on startup.',
        );
      }
    } catch (error, stack) {
      logger.warning(
        'Failed to reconcile orphaned compaction operations on startup; continuing.',
        error,
        stack,
      );
    }
  }
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

/// The actionable message the daemon logs when the Agent vault is closed.
///
/// It states what is unreadable, why, and how to recover, so an operator who
/// upgraded the Agent never has to discover a silent loss of provider keys and
/// the Device Credential from a single line. It never carries a secret value.
String _agentVaultUnavailableMessage(SecretVaults vaults) {
  final reason = vaults.unavailableReason ?? 'unavailable';
  final diagnostic = vaults.unavailableMessage;
  final recovery = Platform.isMacOS
      ? 'Recovery: quit the Agent, then start it again from a desktop session so '
            'macOS can show the one-time Keychain authorization dialog and you '
            'can approve it; if no dialog appears, open Keychain Access, select '
            'the $agentVaultKeychainService items under the login keychain, and '
            'add the running Agent binary to Access Control.'
      : 'Recovery: quit the Agent, then start it again in a session where the '
            'operating-system credential store is unlocked (Windows DPAPI or the '
            'Linux Secret Service).';
  return [
    'The Agent vault is closed ($reason); provider keys, MCP secrets, user '
        'secrets and the Device Credential cannot be read.',
    if (diagnostic != null && diagnostic.isNotEmpty) diagnostic,
    recovery,
    'No secret is deleted while the vault is closed.',
  ].join(' ');
}
