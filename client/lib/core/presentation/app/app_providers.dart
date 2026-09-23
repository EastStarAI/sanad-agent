import 'dart:async';

import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart';
import 'package:sanad_client/core/presentation/bloc/app_error_cubit.dart';
import 'package:sanad_client/core/presentation/bloc/connection/connection_cubit.dart';
import 'package:sanad_client/core/presentation/bloc/debug_panel_cubit.dart';
import 'package:sanad_client/core/presentation/bloc/theme/theme_cubit.dart';
import 'package:sanad_client/core/presentation/state/app_log_store.dart';
import 'package:sanad_client/core/presentation/state/app_state.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/device_client_registry.dart';
import 'package:sanad_client/features/devices/domain/device_repository.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_capabilities_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/gateway_connection_cubit.dart';
import 'package:sanad_client/features/devices/presentation/state/device_command_handler.dart';
import 'package:sanad_client/features/auth/domain/auth_repository.dart';
import 'package:sanad_client/features/auth/infrastructure/auth_service.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/conversations/domain/conversation_client.dart';
import 'package:sanad_client/features/mcp/data/mcp_runtime_client.dart';
import 'package:sanad_client/features/voice/domain/services/voice_stream_service.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_cubit.dart';
import 'package:sanad_client/infrastructure/local_tools/local_tool_runtime_service.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:provider/provider.dart';
import 'package:toastification/toastification.dart';

import 'package:sanad_client/core/presentation/bloc/appearance/appearance_cubit.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_state.dart';

class AppProviders extends StatelessWidget {
  final ThemeMode initialTheme;
  final Locale initialLocale;
  final AppearanceState initialAppearance;
  final Widget child;

  const AppProviders({
    super.key,
    required this.initialTheme,
    required this.initialLocale,
    this.initialAppearance = const AppearanceState(),
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final appState = getIt<AppState>();
    final authService = appState.authService;
    final socketService = appState.brainSocketController;
    final localToolRuntime = appState.localToolRuntime;
    final agentCommandHandler = appState.agentCommandHandler;
    final logStore = appState.logStore;
    final connectionCoordinator = getIt<DeviceConnectionCoordinator>();

    return MultiBlocProvider(
      providers: [
        BlocProvider(create: (_) => AppearanceCubit(initialAppearance)),
        BlocProvider(create: (_) => ThemeCubit(initialTheme)),
        BlocProvider(create: (_) => LocaleCubit(initialLocale)),
        BlocProvider(create: (_) => AppErrorCubit()),
        BlocProvider(create: (_) => DebugPanelCubit()),
        BlocProvider(
          create: (_) {
            final cubit = AuthCubit(authRepository: getIt<IAuthRepository>());
            unawaited(cubit.init());
            return cubit;
          },
        ),
        BlocProvider(
          create: (_) => ConnectionCubit(
            socketService: socketService,
          ),
        ),
        BlocProvider(
          create: (_) {
            final cubit = DeviceCubit(
              socketService: socketService,
              agentRepository: getIt<IDeviceRepository>(),
              agentClientRegistry: getIt<IDeviceClientRegistry>(),
              conversationClientRegistry: getIt<ManagedConversationClientRegistry>(),
            );
            unawaited(cubit.init());
            return cubit;
          },
        ),
        BlocProvider(
          create: (context) => DeviceCapabilitiesCubit(
            capabilities: getIt<DeviceCapabilitiesStore>(),
            agentCubit: context.read<DeviceCubit>(),
          ),
        ),
        BlocProvider(
          create: (context) => GatewayConnectionCubit(
            authCubit: context.read<AuthCubit>(),
            deviceCubit: context.read<DeviceCubit>(),
            connectionCoordinator: getIt<DeviceConnectionCoordinator>(),
          ),
        ),
        BlocProvider(
          create: (context) => VoiceStreamCubit(
            voiceStreamService: VoiceStreamService(),
            connectionCoordinator: getIt<DeviceConnectionCoordinator>(),
          ),
        ),
        BlocProvider(
          create: (_) => getIt<ProviderUsageCubit>(),
        ),
      ],
      child: MultiProvider(
        providers: [
          Provider<AuthService>.value(value: authService),
          Provider<SanadSocketService>.value(value: socketService),
          Provider<McpRuntimeClient>.value(value: getIt<McpRuntimeClient>()),
          Provider<LocalToolRuntimeService>.value(value: localToolRuntime),
          Provider<DeviceCommandHandler>.value(value: agentCommandHandler),
          Provider<AppLogStore>.value(value: logStore),
          Provider<DeviceConnectionCoordinator>.value(
            value: connectionCoordinator,
          ),
        ],
        child: ToastificationWrapper(child: child),
      ),
    );
  }
}
