import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/navigation/navigation_history_controller.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/repositories/conversation_repository.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_search_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_sidebar_cubit.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';

/// The conversation scope the device side menu reads.
///
/// `SidebarDrawer` renders `SessionSidebar`, which projects the conversation
/// cache through `SessionSidebarCubit`, searches through `SessionSearchCubit`,
/// and switches devices through `SessionCubit`. Any surface that offers the
/// side menu must therefore sit below this scope — the home surface and the
/// mobile zero-device surface share it, so the menu (Settings, Profile, Sign
/// out) is the same one everywhere and never a second implementation.
///
/// The scope is created above the responsive layout, so crossing a breakpoint
/// keeps the same cubit instances and never drops the selected session.
class ConversationSidebarScope extends StatelessWidget {
  final Widget child;

  const ConversationSidebarScope({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final conversationRepository = getIt<ConversationRepository>();
    final conversationCacheRepository = getIt<ConversationCacheRepository>();

    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (context) => SessionSidebarCubit(
            cacheRepository: conversationCacheRepository,
          ),
        ),
        BlocProvider(
          create: (context) => SessionSearchCubit(
            repository: conversationRepository,
          ),
        ),
        BlocProvider(
          create: (context) => SessionCubit(
            agentCubit: context.read<DeviceCubit>(),
            socketService: context.read<SanadSocketService>(),
            conversationRepository: conversationRepository,
            historyController: getIt<ConversationHistoryController>(),
            conversationCacheRepository: conversationCacheRepository,
            connectionCoordinator: getIt<DeviceConnectionCoordinator>(),
          ),
        ),
      ],
      child: child,
    );
  }
}
