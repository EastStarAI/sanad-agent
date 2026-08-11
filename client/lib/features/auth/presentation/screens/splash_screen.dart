import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_state.dart';
import 'package:sanad_client/features/devices/presentation/bloc/gateway_connection_cubit.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/utils/app_platform.dart';

class SplashScreen extends StatefulWidget {
  final String? requestedLocation;
  final bool bootstrapGateway;

  const SplashScreen({
    super.key,
    this.requestedLocation,
    this.bootstrapGateway = true,
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.bootstrapGateway) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrapGateway());
    }
  }

  @override
  void didUpdateWidget(SplashScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.bootstrapGateway && !oldWidget.bootstrapGateway) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrapGateway());
    }
  }

  void _navigateToHome() {
    // Handled by GoRouter redirect
  }

  Future<void> _bootstrapGateway() async {
    final routeFuture = context.read<GatewayConnectionCubit>().resolveInitialRoute(
      requestedLocation: widget.requestedLocation,
    );
    final route = await (AppPlatform.isDesktop
        ? routeFuture.catchError((_) => AppRoutes.onboarding)
        : routeFuture
              .timeout(
                const Duration(seconds: 8),
                onTimeout: () => AppRoutes.login,
              )
              .catchError((_) => AppRoutes.login));
    if (!mounted) return;
    context.go(route);
  }

  Future<void> _handleLogin() async {
    unawaited(context.read<AuthCubit>().login());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return BlocListener<AuthCubit, AuthState>(
      listener: (context, state) {
        if (state is AuthAuthenticated) {
          _navigateToHome();
        } else if (state is AuthUnauthenticated || state is AuthInitial) {
          // Stay on splash or show login
        } else if (state is AuthError) {
          setState(() {
            _error = state.message;
          });
        }
      },
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(36.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Logo or Title - Always visible
                Image.asset(
                  'assets/sanad_mark.png',
                  width: 150,
                  height: 150,
                  errorBuilder: (ctx, _, __) => Icon(
                    Icons.rocket_launch,
                    size: 80,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  'Sanad',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w300,
                  ),
                ),
                const SizedBox(height: 48),

                // Loading Indicator OR Login Button
                BlocBuilder<AuthCubit, AuthState>(
                  builder: (context, state) {
                    if (widget.bootstrapGateway && state is! AuthError) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(
                            color: theme.colorScheme.primary,
                            strokeWidth: 3,
                          ),
                          const SizedBox(height: 24),
                          Text(
                            'Checking gateway connection...',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      );
                    }

                    if (state is AuthLoading || state is AuthCompleting) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(
                            color: theme.colorScheme.primary,
                            strokeWidth: 3,
                          ),
                          if (state is AuthCompleting) ...[
                            const SizedBox(height: 24),
                            Text(
                              'Completing sign-in...',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurface.withValues(
                                  alpha: 0.7,
                                ),
                              ),
                            ),
                          ],
                        ],
                      );
                    }

                    return Column(
                      children: [
                        ElevatedButton.icon(
                          onPressed: _handleLogin,
                          icon: const Icon(Icons.login),
                          label: const Text('Sign In'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: theme.colorScheme.onSurface,
                            foregroundColor: theme.colorScheme.surface,
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                          ),
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 24),
                          Text(
                            _error!,
                            style: TextStyle(color: theme.colorScheme.error),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
