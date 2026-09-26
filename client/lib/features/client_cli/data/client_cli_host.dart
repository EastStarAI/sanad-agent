import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/device_repository.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:uuid/uuid.dart';

import '../domain/models/client_cli_record.dart';
import '../domain/models/client_cli_settings.dart';
import 'client_cli_approval_coordinator.dart';
import 'client_cli_ownership.dart';

class ClientCliHost {
  final DeviceConnectionCoordinator connectionCoordinator;
  final IDeviceRepository deviceRepository;
  final ClientCliOwnership ownership;
  final ClientCliApprovalCoordinator approvalCoordinator;
  final String sanadHome;
  final String clientVersion;
  final Uuid uuid;

  final _logger = Logger('ClientCliHost');

  HttpServer? _server;
  String? _token;
  bool _enabled;
  String _permissionMode;
  final List<WebSocket> _activeSockets = [];

  ClientCliHost({
    required this.connectionCoordinator,
    required this.deviceRepository,
    required this.ownership,
    required this.approvalCoordinator,
    required this.sanadHome,
    required this.clientVersion,
    bool initialEnabled = false,
    String initialPermissionMode = ClientCliSettings.defaultMode,
    this.uuid = const Uuid(),
  })  : _enabled = initialEnabled,
        _permissionMode = initialPermissionMode;

  bool get isRunning => _server != null;
  bool get isEnabled => _enabled;
  String get permissionMode => _permissionMode;
  int? get port => _server?.port;
  String? get token => _token;

  Future<void> updateSettings({
    required bool enabled,
    required String permissionMode,
  }) async {
    final modeChanged = _permissionMode != permissionMode;
    final enabledChanged = _enabled != enabled;
    _enabled = enabled;
    _permissionMode = permissionMode;

    if (enabledChanged) {
      if (_enabled) {
        await start();
      } else {
        await stop();
      }
    } else if (isRunning && modeChanged) {
      // Update running record
      final currentPort = _server?.port;
      final currentToken = _token;
      if (currentPort != null && currentToken != null) {
        final record = ClientCliRecord(
          pid: pid,
          port: currentPort,
          token: currentToken,
          sanadHome: sanadHome,
          clientVersion: clientVersion,
          enabled: _enabled,
          permissionMode: _permissionMode,
          updatedAt: DateTime.now().toUtc(),
        );
        await ownership.acquireOwnership(record);
      }
    }
  }

  Future<void> start() async {
    if (isRunning) return;

    final tokenBytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    _token = base64Url.encode(tokenBytes);

    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final currentPort = _server!.port;

    final record = ClientCliRecord(
      pid: pid,
      port: currentPort,
      token: _token!,
      sanadHome: sanadHome,
      clientVersion: clientVersion,
      enabled: _enabled,
      permissionMode: _permissionMode,
      updatedAt: DateTime.now().toUtc(),
    );

    try {
      await ownership.acquireOwnership(record);
    } catch (e) {
      await _server?.close(force: true);
      _server = null;
      _token = null;
      rethrow;
    }

    _server!.listen(
      _handleRequest,
      onError: (e) {
        _logger.warning('Client CLI server error: $e');
      },
    );
  }

  Future<void> stop() async {
    for (final socket in List<WebSocket>.from(_activeSockets)) {
      try {
        await socket.close(WebSocketStatus.normalClosure, 'Client CLI stopped');
      } catch (_) {}
    }
    _activeSockets.clear();

    await _server?.close(force: true);
    _server = null;
    _token = null;

    try {
      await ownership.releaseOwnership(sanadHome, pid: pid);
    } catch (_) {}

    approvalCoordinator.clearSessionApprovals();
  }

  void _handleRequest(HttpRequest request) async {
    // 1. Authenticate token
    if (!_authenticate(request)) {
      request.response
        ..statusCode = HttpStatus.unauthorized
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'error': 'unauthorized', 'message': 'Invalid authentication token.'}));
      await request.response.close();
      return;
    }

    final path = request.uri.path;
    if (path == '/health' && request.method == 'GET') {
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'status': 'ok',
            'enabled': _enabled,
            'permission_mode': _permissionMode,
            'client_version': clientVersion,
            'pid': pid,
          }),
        );
      await request.response.close();
      return;
    }

    if (path == '/devices' && request.method == 'GET') {
      if (!_enabled) {
        request.response
          ..statusCode = HttpStatus.forbidden
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'error': 'disabled',
              'message': 'Client CLI is disabled in settings.',
            }),
          );
        await request.response.close();
        return;
      }

      final allAgents = deviceRepository.agents;
      // Remote only: filter out local inventory devices
      final remoteAgents = allAgents.where((agent) => !agent.isLocalInventoryDevice).toList();
      final currentDeviceId = connectionCoordinator.currentDeviceId;

      final deviceList = remoteAgents.map((agent) {
        return {
          'id': agent.accountDeviceId ?? agent.id,
          'name': agent.name,
          'platform': agent.metadata?['platform']?.toString() ?? 'unknown',
          'status': agent.isOnline ? 'online' : 'offline',
          'is_current': agent.representsDeviceId(currentDeviceId),
        };
      }).toList();

      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'devices': deviceList}));
      await request.response.close();
      return;
    }

    if (path == '/ws' && WebSocketTransformer.isUpgradeRequest(request)) {
      if (!_enabled) {
        request.response
          ..statusCode = HttpStatus.forbidden
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode({
              'error': 'disabled',
              'message': 'Client CLI is disabled in settings.',
            }),
          );
        await request.response.close();
        return;
      }

      final socket = await WebSocketTransformer.upgrade(request);
      _activeSockets.add(socket);
      _handleWebSocket(socket);
      return;
    }

    request.response
      ..statusCode = HttpStatus.notFound
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'error': 'not_found'}));
    await request.response.close();
  }

  bool _authenticate(HttpRequest request) {
    final expected = _token;
    if (expected == null || expected.isEmpty) return false;

    // Check header x-sanad-client-token
    final customToken = request.headers.value('x-sanad-client-token');
    if (customToken != null && customToken.trim() == expected) return true;

    // Check Authorization: Bearer <token>
    final authHeader = request.headers.value(HttpHeaders.authorizationHeader);
    if (authHeader != null && authHeader.startsWith('Bearer ')) {
      final token = authHeader.substring(7).trim();
      if (token == expected) return true;
    }

    // Check query param 'token'
    final queryToken = request.uri.queryParameters['token'];
    if (queryToken != null && queryToken.trim() == expected) return true;

    return false;
  }

  void _handleWebSocket(WebSocket socket) {
    StreamSubscription<Map<String, dynamic>>? eventSubscription;
    ResolvedAgentEndpoint? currentEndpoint;

    socket.listen(
      (data) async {
        try {
          final decoded = jsonDecode(data.toString()) as Map<String, dynamic>;
          final type = decoded['type']?.toString();

          if (type == 'execute') {
            final requestId = decoded['request_id']?.toString() ?? uuid.v4();
            final targetDeviceId = decoded['device_id']?.toString() ?? '';
            final argv = List<String>.from(decoded['argv'] as List? ?? []);
            final stdin = decoded['stdin']?.toString();
            final briefContent = decoded['brief_content']?.toString();
            final timeoutSeconds = decoded['timeout_seconds'] as int? ?? 300;

            if (targetDeviceId.isEmpty) {
              socket.add(
                jsonEncode({
                  'type': 'error',
                  'request_id': requestId,
                  'code': 'missing_device',
                  'message': 'Target device_id is required.',
                }),
              );
              await socket.close(WebSocketStatus.protocolError, 'missing_device');
              return;
            }

            // Find device in inventory
            final device = _findRemoteDevice(targetDeviceId);
            if (device == null) {
              socket.add(
                jsonEncode({
                  'type': 'error',
                  'request_id': requestId,
                  'code': 'wrong_device',
                  'message': 'Remote device "$targetDeviceId" was not found in inventory.',
                }),
              );
              await socket.close(WebSocketStatus.protocolError, 'wrong_device');
              return;
            }

            // Permission checking
            if (_permissionMode == ClientCliSettings.defaultMode) {
              final approved = await approvalCoordinator.requestApproval(
                id: requestId,
                deviceId: device.id,
                deviceName: device.name,
                argv: argv,
                sessionId: _extractSessionId(argv),
              );

              if (!approved) {
                socket.add(
                  jsonEncode({
                    'type': 'result',
                    'request_id': requestId,
                    'exit_code': 1,
                    'cancelled': false,
                    'timed_out': false,
                    'error': 'Command rejected by user in Sanad Client.',
                  }),
                );
                await socket.close(WebSocketStatus.normalClosure);
                return;
              }
            }

            // Ensure endpoint and route command
            final endpoint = await connectionCoordinator.ensureConnectedEndpointForAgent(device);
            currentEndpoint = endpoint;

            if (!endpoint.socketService.isConnected) {
              socket.add(
                jsonEncode({
                  'type': 'error',
                  'request_id': requestId,
                  'code': 'device_offline',
                  'message': 'Target device "${device.name}" is currently unreachable.',
                }),
              );
              await socket.close(WebSocketStatus.protocolError, 'device_offline');
              return;
            }

            // Listen to remote agent events for this requestId
            eventSubscription = endpoint.socketService.events.listen((event) {
              final payload = Map<String, dynamic>.from(event['payload'] as Map? ?? const {});
              final eventRequestId =
                  event['request_id']?.toString() ??
                  payload['request_id']?.toString() ??
                  payload['id']?.toString();

              if (eventRequestId != requestId) return;

              final eventName = event['event']?.toString();
              if (eventName == 'device.cli.stdout') {
                socket.add(
                  jsonEncode({
                    'type': 'stdout',
                    'request_id': requestId,
                    'text': payload['text']?.toString() ?? '',
                  }),
                );
              } else if (eventName == 'device.cli.stderr') {
                socket.add(
                  jsonEncode({
                    'type': 'stderr',
                    'request_id': requestId,
                    'text': payload['text']?.toString() ?? '',
                  }),
                );
              } else if (eventName == 'device.cli.event') {
                socket.add(
                  jsonEncode({
                    'type': 'event',
                    'request_id': requestId,
                    'event': payload['event'] ?? payload,
                  }),
                );
              } else if (eventName == 'device.cli.result') {
                unawaited(eventSubscription?.cancel());
                socket.add(
                  jsonEncode({
                    'type': 'result',
                    'request_id': requestId,
                    'exit_code': payload['exit_code'] ?? 0,
                    'duration_ms': payload['duration_ms'],
                    'cancelled': payload['cancelled'] == true,
                    'timed_out': payload['timed_out'] == true,
                    'error': payload['error'],
                  }),
                );
                unawaited(socket.close(WebSocketStatus.normalClosure));
              } else if (eventName == 'error') {
                unawaited(eventSubscription?.cancel());
                socket.add(
                  jsonEncode({
                    'type': 'error',
                    'request_id': requestId,
                    'code': payload['code'] ?? 'relay_error',
                    'message': payload['message'] ?? 'Device command failed.',
                  }),
                );
                unawaited(socket.close(WebSocketStatus.normalClosure));
              }
            });

            // Dispatch command to remote agent
            endpoint.socketService.sendDeviceCommand(
              deviceId: endpoint.protocolDeviceId,
              command: 'device.cli.execute',
              payload: {
                'request_id': requestId,
                'argv': argv,
                'stdin': stdin,
                'brief_content': briefContent,
                'timeout_seconds': timeoutSeconds,
              },
            );
          } else if (type == 'cancel') {
            final targetRequestId = decoded['target_request_id']?.toString() ??
                decoded['request_id']?.toString() ??
                '';
            final endpoint = currentEndpoint;
            if (endpoint != null && targetRequestId.isNotEmpty) {
              endpoint.socketService.sendDeviceCommand(
                deviceId: endpoint.protocolDeviceId,
                command: 'device.cli.cancel',
                payload: {
                  'request_id': uuid.v4(),
                  'target_request_id': targetRequestId,
                },
              );
            }
          }
        } catch (e) {
          socket.add(
            jsonEncode({
              'type': 'error',
              'message': 'Failed to process request: $e',
            }),
          );
        }
      },
      onDone: () {
        unawaited(eventSubscription?.cancel());
        _activeSockets.remove(socket);
      },
      onError: (_) {
        unawaited(eventSubscription?.cancel());
        _activeSockets.remove(socket);
      },
    );
  }

  DeviceConfig? _findRemoteDevice(String deviceId) {
    for (final agent in deviceRepository.agents) {
      if (agent.isLocalInventoryDevice) continue; // Remote only!
      if (agent.representsDeviceId(deviceId) ||
          agent.id == deviceId ||
          agent.accountDeviceId == deviceId ||
          agent.name.toLowerCase() == deviceId.toLowerCase()) {
        return agent;
      }
    }
    return null;
  }

  String? _extractSessionId(List<String> argv) {
    for (var i = 0; i < argv.length; i++) {
      if ((argv[i] == '-s' || argv[i] == '--session') && i + 1 < argv.length) {
        return argv[i + 1];
      }
      if (argv[i].startsWith('--session=')) {
        return argv[i].substring('--session='.length);
      }
    }
    return null;
  }
}
