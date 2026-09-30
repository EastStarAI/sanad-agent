import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/auth/infrastructure/auth_service.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/utils/toast_utils.dart';
import 'package:provider/provider.dart';

class DeviceLoginChallengeOverlay extends StatelessWidget {
  final Widget child;

  const DeviceLoginChallengeOverlay({
    super.key,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final authService = context.read<AuthService>();

    return StreamBuilder<AuthLoginChallenge?>(
      stream: authService.loginChallengeStream,
      initialData: authService.loginChallenge,
      builder: (context, snapshot) {
        final challenge = snapshot.data;
        // Plan 23: the overlay is always shown while a login is in progress.
        //   - CLI/headless fallback: the user must type a short code into the
        //     portal page, so we show the code + copy + cancel.
        //   - Desktop / Web / Mobile: no code is needed (the portal drives
        //     provider selection itself). We show a generic "Authenticating…"
        //     panel with a cancel button so the user can always abort and
        //     restart login from anywhere in the app.
        final showOverlay = challenge != null;
        return Stack(
          children: [
            child,
            if (showOverlay) _ChallengeDialog(challenge: challenge),
          ],
        );
      },
    );
  }
}

class _ChallengeDialog extends StatelessWidget {
  final AuthLoginChallenge challenge;

  const _ChallengeDialog({required this.challenge});

  bool get _hasUserCode => challenge.userCode.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Positioned.fill(
      child: Material(
        color: Colors.black.withValues(alpha: 0.48),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Container(
              margin: const EdgeInsets.all(24),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: colorScheme.outline.withValues(alpha: 0.16),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.24),
                    blurRadius: 24,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_hasUserCode) ...[
                    Icon(
                      Icons.verified_user_outlined,
                      color: colorScheme.primary,
                      size: 40,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Complete sign in',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colorScheme.onSurface,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Enter this code in the browser window.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 22),
                    Semantics(
                      button: true,
                      label: 'Copy sign in code',
                      child: InkWell(
                        onTap: () => _copyCode(context),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
                          decoration: BoxDecoration(
                            color: colorScheme.primary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: colorScheme.primary.withValues(alpha: 0.28),
                            ),
                          ),
                          child: Text(
                            challenge.userCode,
                            style: theme.textTheme.headlineMedium?.copyWith(
                              color: colorScheme.onSurface,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 3,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _copyCode(context),
                            icon: const Icon(Icons.copy, size: 18),
                            label: const Text('Copy'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: () => context.read<AuthCubit>().cancelLogin(),
                            icon: const Icon(Icons.close, size: 18),
                            label: const Text('Cancel'),
                            style: FilledButton.styleFrom(
                              backgroundColor: colorScheme.error,
                              foregroundColor: colorScheme.onError,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ] else ...[
                    SizedBox(
                      width: 40,
                      height: 40,
                      child: AppProgressIndicator(
                        color: colorScheme.primary,
                        strokeWidth: 3,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Authenticating…',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colorScheme.onSurface,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Complete sign in on the portal page that opened.\n'
                      'If the browser failed to authenticate, cancel and try again.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 22),
                    FilledButton.icon(
                      onPressed: () => context.read<AuthCubit>().cancelLogin(),
                      icon: const Icon(Icons.close, size: 18),
                      label: const Text('Cancel login'),
                      style: FilledButton.styleFrom(
                        backgroundColor: colorScheme.error,
                        foregroundColor: colorScheme.onError,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _copyCode(BuildContext context) {
    unawaited(Clipboard.setData(ClipboardData(text: challenge.userCode)));
    ToastUtils.showSuccess(context, 'Code copied');
  }
}
