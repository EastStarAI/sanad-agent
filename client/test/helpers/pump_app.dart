import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart'
    show kSupportedLocales;
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_capabilities_cubit.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/repositories/conversation_repository.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_sidebar_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_cubit.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_state.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

Future<void> pumpTestApp(
  WidgetTester tester, {
  required Widget child,
  GoRouter? router,
  DeviceCubit? agentCubit,
  SessionCubit? sessionCubit,
  SessionSidebarCubit? sessionSidebarCubit,
  SessionMessagesCubit? sessionMessagesCubit,
  ConversationInputCubit? conversationInputCubit,
  DeviceCapabilitiesStore? capabilities,
  DeviceCapabilitiesCubit? deviceCapabilitiesCubit,
  VoiceStreamCubit? voiceStreamCubit,
  ConversationCacheRepository? conversationCacheRepository,
  ConversationRepository? conversationRepository,
}) {
  Widget wrapped = router != null
      ? MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: kSupportedLocales,
        )
      : MaterialApp(
          home: Scaffold(body: child),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: kSupportedLocales,
        );

  final blocProviders = [
    BlocProvider<VoiceStreamCubit>.value(value: voiceStreamCubit ?? FakeVoiceStreamCubit()),
    if (agentCubit != null) BlocProvider<DeviceCubit>.value(value: agentCubit),
    if (deviceCapabilitiesCubit != null)
      BlocProvider<DeviceCapabilitiesCubit>.value(value: deviceCapabilitiesCubit)
    else if (capabilities != null && agentCubit != null)
      BlocProvider<DeviceCapabilitiesCubit>(
        create: (_) => DeviceCapabilitiesCubit(capabilities: capabilities, agentCubit: agentCubit),
      ),
    if (sessionCubit != null) BlocProvider<SessionCubit>.value(value: sessionCubit),
    if (sessionSidebarCubit != null) BlocProvider<SessionSidebarCubit>.value(value: sessionSidebarCubit),
    if (sessionMessagesCubit != null) BlocProvider<SessionMessagesCubit>.value(value: sessionMessagesCubit),
    if (conversationInputCubit != null)
      BlocProvider<ConversationInputCubit>.value(value: conversationInputCubit)
    else if (sessionMessagesCubit != null)
      BlocProvider<ConversationInputCubit>(create: (_) => ConversationInputCubit(messagesCubit: sessionMessagesCubit)),
  ];

  final repositoryProviders = <RepositoryProvider>[
    if (conversationCacheRepository != null)
      RepositoryProvider<ConversationCacheRepository>.value(value: conversationCacheRepository),
    if (conversationRepository != null) RepositoryProvider<ConversationRepository>.value(value: conversationRepository),
  ];

  if (repositoryProviders.isNotEmpty) {
    wrapped = MultiRepositoryProvider(
      providers: repositoryProviders,
      child: wrapped,
    );
  }

  if (blocProviders.isNotEmpty) {
    wrapped = MultiBlocProvider(providers: blocProviders, child: wrapped);
  }

  return tester.pumpWidget(wrapped);
}

class FakeVoiceStreamCubit extends Cubit<VoiceStreamState> implements VoiceStreamCubit {
  FakeVoiceStreamCubit() : super(const VoiceStreamState());

  @override
  Future<void> startVoiceSession({required DeviceConfig agent, required String sessionId}) async {}

  @override
  void sendManualInterrupt() {}

  @override
  void toggleMute() {}

  @override
  Future<void> stopVoiceSession() async {}
}
