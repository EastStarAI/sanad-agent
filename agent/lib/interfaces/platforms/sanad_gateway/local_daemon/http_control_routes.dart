import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:sanad_release_contract/release_contract.dart';
import 'package:sanad_agent/core/app_config.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/auth/colocated_auth_coupling.dart';
import 'package:sanad_agent/core/auth/device_authorization_client.dart';
import 'package:sanad_agent/core/auth/secret_vault.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_identity.dart';
import 'package:sanad_agent/core/update/agent_update_service.dart';
import 'package:sanad_agent/core/utils/logger.dart';
import 'package:sanad_agent/interfaces/runtime/daemon_restart_coordinator.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';

import '../capabilities_loader.dart';

/// Renders one local daemon JSON control response.
typedef LocalDaemonJsonResponseWriter =
    Future<void> Function(
      HttpResponse response,
      Map<String, dynamic> data, {
      int statusCode,
    });

/// Owns the local daemon's HTTP control surface: the credential-free `/auth/*`
/// enrollment and logout routes, and the `/health`, `/update`, `/logs`,
/// `/restart`, `/shutdown`, `/stop`, `/authentication-exchange`, and
/// `/capabilities` control routes.
///
/// The platform keeps the socket lifecycle, the authentication gate that runs
/// before any route, response fan-out, delivery scopes, and voice. Dependencies
/// are explicit constructor inputs; this owner never resolves a runtime owner
/// through the service locator.
class LocalDaemonHttpControlRoutes {
  final Config _config;

  /// Platform identity reported by `/health`.
  final String platformId;

  final Logger _logger;
  final AuthManager Function() _resolveAuthManager;
  final DaemonRestartCoordinator Function() _resolveRestartCoordinator;
  final bool Function() _isCloudRegistered;
  final String? Function() _currentHomeId;
  final LocalDaemonJsonResponseWriter _writeJsonResponse;

  /// Co-located enrollment coupling; created on first use when absent.
  ColocatedAuthCoupling? _authCoupling;

  LocalDaemonHttpControlRoutes({
    required Config config,
    required this.platformId,
    required Logger logger,
    required AuthManager Function() authManager,
    required DaemonRestartCoordinator Function() restartCoordinator,
    required bool Function() cloudRegistered,
    required String? Function() homeId,
    required LocalDaemonJsonResponseWriter writeJsonResponse,
    ColocatedAuthCoupling? authCoupling,
  }) : _config = config,
       _logger = logger,
       _resolveAuthManager = authManager,
       _resolveRestartCoordinator = restartCoordinator,
       _isCloudRegistered = cloudRegistered,
       _currentHomeId = homeId,
       _writeJsonResponse = writeJsonResponse,
       _authCoupling = authCoupling;

  /// Returns whether a control route answered the request.
  Future<bool> handle(HttpRequest request) async {
    if (request.uri.path == '/auth/logout') {
      final hasBody =
          request.headers.contentLength > 0 ||
          request.headers.value(HttpHeaders.transferEncodingHeader) != null;
      if (request.method != 'POST' || request.uri.hasQuery || hasBody) {
        await _writeJsonResponse(request.response, const {
          'status': 'invalid_request',
        }, statusCode: HttpStatus.badRequest);
        return true;
      }
      await _resolveAuthManager().logout();
      await _writeJsonResponse(request.response, const {
        'status': 'logged_out',
      });
      return true;
    }

    if (request.uri.path == '/auth/coupling') {
      final hasBody =
          request.headers.contentLength > 0 ||
          request.headers.value(HttpHeaders.transferEncodingHeader) != null;
      if (request.uri.hasQuery ||
          hasBody ||
          (request.method != 'GET' &&
              request.method != 'POST' &&
              request.method != 'DELETE')) {
        await _writeJsonResponse(request.response, {
          'status': 'invalid_request',
        }, statusCode: HttpStatus.badRequest);
        return true;
      }
      final coupling = _authCoupling ??= ColocatedAuthCoupling(
        authManager: _resolveAuthManager(),
        authorizationClient: DeviceAuthorizationClient(
          portalUrl: _config.portalUrl,
          authManager: _resolveAuthManager(),
        ),
      );
      if (request.method == 'DELETE') {
        await coupling.cancel();
        await _writeJsonResponse(request.response, const {
          'status': 'cancelled',
        });
        return true;
      }
      final snapshot = request.method == 'POST'
          ? await coupling.start()
          : coupling.snapshot;
      await _writeJsonResponse(request.response, snapshot.toJson());
      return true;
    }

    if (request.uri.path == '/health') {
      final stateMode = (getSanadStateHome() != getSanadHome())
          ? 'isolated'
          : 'default';
      final vault = SecretVaults.current;
      await _writeJsonResponse(request.response, {
        'status': 'ok',
        'platform_id': platformId,
        'url': _config.localGatewayUrl,
        'version': _config.version,
        'is_source': AppConfig.isSourceRun,
        'home_id': _currentHomeId() ?? sanadHomeIdentity(getSanadHome()),
        'workspace_hash': _workspaceHash(),
        'dev_launcher_id': Platform.environment['SANAD_DEV_LAUNCHER_ID'],
        'dev_runtime_nonce': Platform.environment['SANAD_DEV_RUNTIME_NONCE'],
        'state_mode': stateMode,
        'gateway_enabled': _config.enableGateway,
        // The Agent vault is the OS credential vault. A closed vault means
        // provider keys, MCP secrets, user secrets and the Device Credential
        // cannot be read, so this reports it as a non-secret status instead of
        // leaving it inside one log line.
        'secret_vault': vault?.statusLabel ?? 'unavailable',
        'secret_vault_reason': vault?.unavailableReason,
        'cloud_registered': _isCloudRegistered(),
      });
      return true;
    }

    if (request.uri.path == '/update' && request.method == 'POST') {
      String? targetVersion;
      try {
        targetVersion = request.uri.queryParameters['target_version']?.trim();
        if (targetVersion == null || targetVersion.isEmpty) {
          throw const FormatException('target_version is required.');
        }
        ReleaseVersion.parse(targetVersion);
      } on FormatException catch (error) {
        await _writeJsonResponse(request.response, {
          'success': false,
          'status': 'target_mismatch',
          'message': error.message,
        }, statusCode: HttpStatus.badRequest);
        return true;
      }
      final updater = AgentUpdateService(
        currentVersion: _config.version,
        executablePath: Platform.resolvedExecutable,
        isSourceManaged: AppConfig.isSourceRun,
      );
      var result = await updater.update(targetVersion: targetVersion);
      if (Platform.isWindows && result.stagedPath != null) {
        final scheduled = await updater.scheduleWindowsReplacement(result);
        if (!scheduled) {
          result = result.copyWith(
            status: AgentUpdateStatus.scheduleFailed,
            message:
                'Verified replacement could not be scheduled; the running agent was kept.',
          );
        }
      }
      await _writeJsonResponse(
        request.response,
        result.toJson(),
        statusCode: result.isSuccess
            ? HttpStatus.ok
            : HttpStatus.unprocessableEntity,
      );
      if (result.status == AgentUpdateStatus.restartRequired) {
        unawaited(
          Platform.isWindows
              ? _resolveRestartCoordinator().stop()
              : _resolveRestartCoordinator().restart(),
        );
      }
      return true;
    }

    if (request.uri.path == '/logs' && request.method == 'GET') {
      await _writeJsonResponse(request.response, {'logs': agentLogs});
      return true;
    }

    if (request.uri.path == '/restart' && request.method == 'POST') {
      final forceRaw = request.uri.queryParameters['force'];
      if (forceRaw != null && forceRaw != 'true' && forceRaw != 'false') {
        await _writeJsonResponse(request.response, {
          'success': false,
          'outcome': 'invalid_force',
          'message': 'force must be true or false.',
        }, statusCode: HttpStatus.badRequest);
        return true;
      }
      final force = forceRaw == 'true';
      final permanentRaw = request.uri.queryParameters['permanent'];
      if (permanentRaw != null &&
          permanentRaw != 'true' &&
          permanentRaw != 'false') {
        await _writeJsonResponse(request.response, {
          'success': false,
          'outcome': 'invalid_permanent',
          'message': 'permanent must be true or false.',
        }, statusCode: HttpStatus.badRequest);
        return true;
      }
      final permanent = permanentRaw == 'true';
      final timeoutRaw = request.uri.queryParameters['timeout_seconds'];
      final timeoutSeconds = timeoutRaw == null
          ? null
          : int.tryParse(timeoutRaw);
      if (timeoutRaw != null &&
          (timeoutSeconds == null ||
              timeoutSeconds < 1 ||
              timeoutSeconds > 3600)) {
        await _writeJsonResponse(request.response, {
          'success': false,
          'outcome': 'invalid_timeout',
          'message': 'timeout_seconds must be between 1 and 3600.',
        }, statusCode: HttpStatus.badRequest);
        return true;
      }
      final coordinator = _resolveRestartCoordinator();
      final preparation = await coordinator.prepareRestart(
        force: force,
        timeout: Duration(
          seconds:
              timeoutSeconds ??
              SessionRunOrchestrator
                  .controlledRestartCheckpointTimeout
                  .inSeconds,
        ),
        requesterSessionId: request.headers.value(
          'x-sanad-requester-session-id',
        ),
        requesterToolCallId: request.headers.value(
          'x-sanad-requester-tool-call-id',
        ),
      );
      try {
        await _writeJsonResponse(
          request.response,
          preparation.toJson(),
          statusCode: preparation.accepted
              ? HttpStatus.ok
              : preparation.outcome == 'internal_error'
              ? HttpStatus.internalServerError
              : HttpStatus.conflict,
        );
      } on Object catch (error) {
        coordinator.abandonPreparedRestart(preparation);
        _logger.warning(
          'Restart response could not be flushed; restart was cancelled: '
          '$error',
        );
        return true;
      }
      unawaited(
        permanent
            ? coordinator.completePreparedStop(preparation)
            : coordinator.completePreparedRestart(preparation),
      );
      return true;
    }

    if (request.uri.path == '/shutdown' && request.method == 'POST') {
      final mode = request.uri.queryParameters['mode'] ?? 'pause';
      if (mode != 'pause' && mode != 'cancel') {
        await _writeJsonResponse(request.response, {
          'success': false,
          'outcome': 'invalid_mode',
          'message': 'mode must be pause or cancel.',
        }, statusCode: HttpStatus.badRequest);
        return true;
      }
      final coordinator = _resolveRestartCoordinator();
      if (mode == 'cancel') {
        await _writeJsonResponse(request.response, {
          'success': true,
          'outcome': 'cancelled',
          'message': 'Daemon work cancelled; shutting down permanently.',
        });
        unawaited(coordinator.stop());
        return true;
      }

      final timeoutRaw = request.uri.queryParameters['timeout_seconds'];
      final timeoutSeconds = timeoutRaw == null
          ? SessionRunOrchestrator.controlledRestartCheckpointTimeout.inSeconds
          : int.tryParse(timeoutRaw);
      if (timeoutSeconds == null ||
          timeoutSeconds < 1 ||
          timeoutSeconds > 3600) {
        await _writeJsonResponse(request.response, {
          'success': false,
          'outcome': 'invalid_timeout',
          'message': 'timeout_seconds must be between 1 and 3600.',
        }, statusCode: HttpStatus.badRequest);
        return true;
      }
      final preparation = await coordinator.prepareRestart(
        timeout: Duration(seconds: timeoutSeconds),
      );
      try {
        await _writeJsonResponse(
          request.response,
          preparation.toJson(),
          statusCode: preparation.accepted
              ? HttpStatus.ok
              : preparation.outcome == 'internal_error'
              ? HttpStatus.internalServerError
              : HttpStatus.conflict,
        );
      } on Object catch (error) {
        coordinator.abandonPreparedRestart(preparation);
        _logger.warning(
          'Pause response could not be flushed; shutdown was cancelled: $error',
        );
        return true;
      }
      unawaited(coordinator.completePreparedPause(preparation));
      return true;
    }

    if (request.uri.path == '/stop' && request.method == 'POST') {
      _logger.info('Received stop request from client. Exiting permanently...');
      await _writeJsonResponse(request.response, {
        'success': true,
        'message': 'Daemon exiting permanently...',
      });
      unawaited(_resolveRestartCoordinator().stop());
      return true;
    }

    if (request.uri.path == '/authentication-exchange' &&
        request.method == 'POST') {
      await _resolveAuthManager().reload(notifyIfChanged: true);
      await _writeJsonResponse(request.response, const {'success': true});
      return true;
    }

    if (request.uri.path == '/capabilities') {
      final capabilities = await loadSanadCapabilities();
      await _writeJsonResponse(request.response, capabilities.toJson());
      return true;
    }

    return false;
  }

  String? _findGitTopLevel(String startPath) {
    var dir = Directory(startPath);
    while (true) {
      final gitEntity = Directory('${dir.path}${Platform.pathSeparator}.git');
      final gitFile = File('${dir.path}${Platform.pathSeparator}.git');
      if (gitEntity.existsSync() || gitFile.existsSync()) {
        return dir.absolute.path;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return null;
  }

  String _canonicalPath(String path) {
    String resolved;
    try {
      resolved = Directory(path).resolveSymbolicLinksSync();
    } catch (_) {
      resolved = Directory(path).absolute.path;
    }
    if (Platform.isWindows && resolved.length >= 2 && resolved[1] == ':') {
      return '${resolved[0].toLowerCase()}${resolved.substring(1)}';
    }
    return resolved;
  }

  int _stableHash(String value) {
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  String _workspaceHash() {
    final envHash = Platform.environment['SANAD_DEV_WORKSPACE_HASH'];
    if (envHash != null && envHash.isNotEmpty) return envHash;
    final gitTop = _findGitTopLevel(Directory.current.absolute.path);
    if (gitTop == null) return 'unknown';
    return _stableHash(
      _canonicalPath(gitTop),
    ).toRadixString(16).padLeft(8, '0').substring(0, 8);
  }
}
