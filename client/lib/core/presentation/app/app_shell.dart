import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/navigation/app_router.dart';
import 'package:sanad_client/core/navigation/navigation_history_controller.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart';
import 'package:sanad_client/core/presentation/bloc/theme/theme_cubit.dart';
import 'package:sanad_client/core/theme/app_themes.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/widgets/device_login_challenge_overlay.dart';
import 'package:sanad_client/features/devices/presentation/bloc/gateway_connection_cubit.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/shared/widgets/responsive_window_wrapper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class AppShell extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;

  const AppShell({
    super.key,
    required this.navigatorKey,
  });

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  AppRouterSetup? _routerSetup;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _routerSetup ??= AppRouter.createRouter(
      context.read<AuthCubit>(),
      gatewayConnectionCubit: context.read<GatewayConnectionCubit>(),
      navigatorKey: widget.navigatorKey,
      historyController: getIt<ConversationHistoryController>(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ThemeCubit, ThemeMode>(
      builder: (context, themeMode) => BlocBuilder<LocaleCubit, Locale>(
        builder: (context, locale) => MaterialApp.router(
          routerConfig: _routerSetup!.router,
          title: 'Sanad',
          debugShowCheckedModeBanner: false,
          theme: AppThemes.light,
          darkTheme: AppThemes.dark,
          themeMode: themeMode,
          locale: locale,
          supportedLocales: kSupportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) => DeviceLoginChallengeOverlay(
            child: ResponsiveWindowWrapper(child: child ?? const SizedBox()),
          ),
        ),
      ),
    );
  }
}
