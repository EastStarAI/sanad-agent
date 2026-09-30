import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/provider_setup/data/models/auth_session_dto.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_state.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_setup_header.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_setup_step_scaffold.dart';
import 'package:url_launcher/url_launcher.dart';

class LoopbackAuthView extends StatelessWidget {
  const LoopbackAuthView({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ProviderSetupCubit, ProviderSetupState>(
      builder: (context, state) {
        final displayName = state.selectedInstance?.displayName ?? state.selectedTemplate?.displayName ?? 'Provider';
        final session = state.authSession;
        final waiting = state.authPollStatus == null || state.authPollStatus == AuthPollStatus.pending;
        return ProviderSetupStepScaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ProviderSetupHeader(
                title: 'Sign in with $displayName',
                subtitle: 'Complete sign-in in your browser. Sanad continues automatically after authorization.',
                icon: Icons.login,
              ),
              const SizedBox(height: 28),
              if (session?.hasError ?? false)
                Text(
                  state.error ?? 'Could not start account sign-in.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                )
              else ...[
                Icon(
                  Icons.travel_explore_outlined,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 16),
                if (session?.verificationUri != null)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('Open authorization page'),
                    onPressed: () => unawaited(_open(session)),
                  )
                else
                  const Text(
                    'Waiting for browser authorization...',
                    textAlign: TextAlign.center,
                  ),
                if (waiting) ...[
                  const SizedBox(height: 24),
                  const Center(child: AppProgressIndicator()),
                ],
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
                onPressed: () => _cancel(context),
                icon: const Icon(Icons.close),
                label: const Text('Cancel'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _cancel(BuildContext context) async {
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
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep setup'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true) await cubit.cancelAuth();
  }

  Future<void> _open(AuthSessionDto? session) async {
    final url = session?.verificationUriComplete ?? session?.verificationUri;
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
