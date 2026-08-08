import 'dart:async';
import 'package:sanad_client/features/devices/presentation/state/device_command_handler.dart';
import 'package:sanad_client/features/auth/infrastructure/auth_service.dart';
import 'package:sanad_client/infrastructure/local_tools/local_tool_runtime_service.dart';
import 'package:sanad_client/infrastructure/platform/auto_update_service.dart';
import 'package:sanad_client/infrastructure/local_tools/local_tool_execution_coordinator.dart';
import 'package:sanad_client/infrastructure/mcp/mcp_service.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:sanad_client/core/presentation/state/app_log_store.dart';
import 'package:sanad_client/core/presentation/state/socket_auth_recovery_coordinator.dart';

class AppState {
  final AuthService authService;
  final McpService mcpController;
  final LocalToolRuntimeService localToolRuntime;
  final SanadSocketService brainSocketController;
  final DeviceCommandHandler agentCommandHandler;
  final LocalToolExecutionCoordinator toolExecutionCoordinator;
  final AutoUpdateService autoUpdateService;
  final AppLogStore logStore;
  final String _hardwareId;
  late final SocketAuthRecoveryCoordinator _socketAuthRecoveryCoordinator;
  late final Future<void> ready;
  StreamSubscription<String?>? _authSubscription;

  AppState({
    required this.authService,
    required this.mcpController,
    required this.localToolRuntime,
    required this.brainSocketController,
    required this.agentCommandHandler,
    required this.toolExecutionCoordinator,
    required this.autoUpdateService,
    required String hardwareId,
    AppLogStore? logStore,
  }) : _hardwareId = hardwareId,
       logStore = logStore ?? AppLogStore() {
    _authSubscription = authService.accessTokenStream.listen(
      (_) => syncAuthContext(),
    );
    _socketAuthRecoveryCoordinator = SocketAuthRecoveryCoordinator(
      authService: authService,
      socketService: brainSocketController,
    )..start();
    ready = _initServices();
  }

  Future<void> _initServices() async {
    await authService.init(fallbackDeviceId: _hardwareId);
    syncAuthContext();
    await autoUpdateService.initialize();
  }

  void syncAuthContext() {
    brainSocketController.setAccessToken(authService.accessToken);
  }

  void onAppResumed() {
    _socketAuthRecoveryCoordinator.onAppResumed();
  }

  void dispose() {
    unawaited(_authSubscription?.cancel());
    _socketAuthRecoveryCoordinator.dispose();
    logStore.dispose();
    authService.dispose();
    toolExecutionCoordinator.dispose();
    mcpController.dispose();
    brainSocketController.dispose();
  }
}
