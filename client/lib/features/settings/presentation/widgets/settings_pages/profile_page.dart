import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_state.dart';
import 'package:sanad_client/features/settings/data/account_lifecycle_repository.dart';
import 'package:sanad_client/features/settings/domain/account_lifecycle.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/utils/toast_utils.dart';

import '../settings_widgets.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, this.repository});

  final AccountLifecycleRepository? repository;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool _isDeleting = false;
  bool _isDialogOpen = false;

  AccountLifecycleRepository get _repository =>
      widget.repository ?? getIt<AccountLifecycleRepository>();

  Future<void> _handleDeleteAccount(BuildContext context) async {
    if (_isDeleting || _isDialogOpen) return;
    _isDialogOpen = true;

    final l10n = AppLocalizations.of(context)!;
    final authCubit = context.read<AuthCubit>();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.deleteAccountConfirmationTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.deleteAccountConfirmationMessage),
              const SizedBox(height: 12),
              Text(
                l10n.deleteAccountLocalDataNotice,
                style: TextStyle(
                  color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.deleteAccountAppleNotice,
                style: TextStyle(
                  color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('cancel_delete_account_btn'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('confirm_delete_account_btn'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.deleteAccountConfirmAction),
          ),
        ],
      ),
    );

    _isDialogOpen = false;

    if (confirmed != true) return;

    if (mounted) {
      setState(() => _isDeleting = true);
    }

    try {
      final result = await _repository.deleteAccount();
      // Ensure logout is always dispatched regardless of whether ProfilePage unmounted
      unawaited(authCubit.logout());
      if (result.isPending && mounted) {
        ToastUtils.showSuccess(context, l10n.deleteAccountPendingNotice);
      }
    } catch (e) {
      final message = e is AccountLifecycleException
          ? e.message
          : l10n.deleteAccountError;
      if (mounted) {
        setState(() => _isDeleting = false);
        ToastUtils.showError(context, message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final auth = context.watch<AuthCubit>().state;
    return PageFrame(
      title: l10n.profile,
      subtitle: l10n.profileSubtitle,
      child: SettingsCard(
        child: auth is AuthAuthenticated
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 28,
                    child: Text(
                      auth.displayName.characters.first.toUpperCase(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    auth.displayName,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(
                    auth.email,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      OutlinedButton.icon(
                        key: const ValueKey('sign_out_btn'),
                        onPressed: _isDeleting ? null : () => context.read<AuthCubit>().logout(),
                        icon: const Icon(Icons.logout),
                        label: Text(l10n.signOut),
                      ),
                      OutlinedButton.icon(
                        key: const ValueKey('delete_account_btn'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error,
                          side: BorderSide(
                            color: Theme.of(context).colorScheme.error.withValues(alpha: 0.5),
                          ),
                        ),
                        onPressed: _isDeleting ? null : () => _handleDeleteAccount(context),
                        icon: _isDeleting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.delete_forever_outlined),
                        label: Text(
                          _isDeleting
                              ? l10n.deleteAccountInProgress
                              : l10n.deleteAccount,
                        ),
                      ),
                    ],
                  ),
                ],
              )
            : auth is AuthLoading
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: AppProgressIndicator(),
                ),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.signInPrompt),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(context.read<AuthCubit>().login()),
                    icon: const Icon(Icons.login),
                    label: Text(l10n.signIn),
                  ),
                ],
              ),
      ),
    );
  }
}
