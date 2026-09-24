import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/provider_setup/data/models/auth_session_dto.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_state.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_setup_header.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_setup_step_scaffold.dart';
import 'package:sanad_client/utils/toast_utils.dart';
import 'package:url_launcher/url_launcher.dart';

typedef VerificationPageLauncher = Future<bool> Function(Uri uri);

class DeviceCodeAuthView extends StatefulWidget {
  const DeviceCodeAuthView({super.key, this.verificationLauncher});

  final VerificationPageLauncher? verificationLauncher;

  @override
  State<DeviceCodeAuthView> createState() => _DeviceCodeAuthViewState();
}

class _DeviceCodeAuthViewState extends State<DeviceCodeAuthView> {
  String? _autoLaunchSessionId;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ProviderSetupCubit, ProviderSetupState>(
      builder: (context, state) {
        final session = state.authSession;
        if (session != null && session.sessionId != _autoLaunchSessionId && !state.verificationLaunchAttempted) {
          _autoLaunchSessionId = session.sessionId;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_openVerification(session));
          });
        }
        final displayName = state.selectedInstance?.displayName ?? state.selectedTemplate?.displayName ?? 'Provider';
        final pollStatus = state.authPollStatus;
        final waiting = pollStatus == null || pollStatus == AuthPollStatus.pending;

        return ProviderSetupStepScaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ProviderSetupHeader(
                title: 'Sign in with $displayName',
                subtitle: 'Enter the code below on the provider verification page.',
                icon: Icons.login,
              ),
              const SizedBox(height: 24),
              if (session?.hasError ?? false)
                _ErrorPanel(
                  message: state.error ?? 'Could not start account sign-in.',
                )
              else if (session == null)
                const Center(child: AppProgressIndicator())
              else ...[
                Center(
                  child: Text(
                    'Your code',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Theme.of(
                        context,
                      ).colorScheme.primary.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          session.userCode ?? '------',
                          key: const Key('device_user_code'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 6,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                      IconButton(
                        key: const Key('copy_device_user_code_button'),
                        tooltip: 'Copy device code',
                        onPressed: session.userCode?.isNotEmpty == true ? () => _copyUserCode(session.userCode!) : null,
                        icon: const Icon(Icons.copy_outlined),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                if (state.verificationPageOpened)
                  const Text(
                    'The verification page was opened in your browser.',
                    textAlign: TextAlign.center,
                  )
                else if (state.verificationLaunchAttempted)
                  Text(
                    state.verificationLaunchError ?? 'Open the verification page to continue.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  )
                else
                  const Text(
                    'Opening the verification page...',
                    textAlign: TextAlign.center,
                  ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const Key('open_verification_button'),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text(
                    state.verificationPageOpened ? 'Re-open verification page' : 'Open verification page',
                  ),
                  onPressed: () => _openVerification(session),
                ),
                const SizedBox(height: 24),
                if (waiting)
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: AppProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 10),
                      Text('Waiting for authorization...'),
                    ],
                  )
                else if (pollStatus == AuthPollStatus.expired)
                  const _StatusMessage(
                    message: 'The code expired. Go back and try again.',
                    color: Colors.orange,
                  )
                else if (pollStatus == AuthPollStatus.error)
                  _StatusMessage(
                    message: state.error ?? 'Authentication failed.',
                    color: Colors.redAccent,
                  ),
              ],
            ],
          ),
          footer: Row(
            children: [
              TextButton(
                onPressed: () => context.read<ProviderSetupCubit>().backToProviderDetails(),
                child: const Text('Back'),
              ),
              const Spacer(),
              TextButton.icon(
                key: const Key('cancel_device_auth_button'),
                onPressed: () => _confirmDiscard(context),
                icon: const Icon(Icons.close),
                label: const Text('Cancel'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _copyUserCode(String code) async {
    try {
      await Clipboard.setData(ClipboardData(text: code));
      if (mounted) ToastUtils.showSuccess(context, 'Device code copied');
    } catch (_) {
      if (mounted) ToastUtils.showError(context, 'Could not copy device code');
    }
  }

  Future<void> _confirmDiscard(BuildContext context) async {
    final cubit = context.read<ProviderSetupCubit>();
    if (cubit.state.provisionalInstanceId == null) {
      await cubit.cancelAuth();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard provider setup?'),
        content: const Text(
          'This cancels authentication and removes the incomplete provider created by this setup attempt.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep setup'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && context.mounted) {
      await cubit.cancelAuth();
    }
  }

  Future<void> _openVerification(AuthSessionDto session) async {
    final url = session.verificationUriComplete ?? session.verificationUri;
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null) {
      if (mounted) {
        context.read<ProviderSetupCubit>().recordVerificationLaunch(
          sessionId: session.sessionId,
          opened: false,
          error: 'The provider did not return a valid verification page.',
        );
      }
      return;
    }
    try {
      final opened =
          await (widget.verificationLauncher?.call(uri) ?? launchUrl(uri, mode: LaunchMode.externalApplication));
      if (mounted) {
        context.read<ProviderSetupCubit>().recordVerificationLaunch(
          sessionId: session.sessionId,
          opened: opened,
        );
      }
    } catch (_) {
      if (mounted) {
        context.read<ProviderSetupCubit>().recordVerificationLaunch(
          sessionId: session.sessionId,
          opened: false,
        );
      }
    }
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(message),
    );
  }
}

class _StatusMessage extends StatelessWidget {
  const _StatusMessage({required this.message, required this.color});

  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      message,
      textAlign: TextAlign.center,
      style: TextStyle(color: color, fontSize: 13),
    );
  }
}
