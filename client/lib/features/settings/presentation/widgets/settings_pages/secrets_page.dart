import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/settings/data/secrets_client.dart';
import 'package:sanad_client/features/settings/presentation/bloc/secrets_cubit.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/utils/toast_utils.dart';

import '../settings_widgets.dart';
import 'delete_secret_dialog.dart';
import 'secret_editor_dialog.dart';
import 'secrets_failure_text.dart';

/// Settings → Privacy & Security → Secrets for one inspected device
/// (Task 140 C1–C3).
///
/// One [SecretsCubit] per page, created here from DI with the selected device.
/// [SecretsCubit.load] runs once from [initState] and again from Retry, never
/// from [build], so a rebuild cannot re-issue `secrets.list`.
///
/// The page renders metadata only. There is no value in any state it consumes,
/// every value the user types lives in a dialog controller, and a mutation is
/// followed by a re-read of the Agent's own projection.
class SettingsSecretsPage extends StatefulWidget {
  const SettingsSecretsPage({super.key, required this.device});

  final DeviceConfig device;

  @override
  State<SettingsSecretsPage> createState() => _SettingsSecretsPageState();
}

class _SettingsSecretsPageState extends State<SettingsSecretsPage> {
  late final SecretsCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = SecretsCubit(client: getIt<SecretsClient>(), device: () => widget.device);
    unawaited(_cubit.load());
  }

  @override
  void didUpdateWidget(covariant SettingsSecretsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasOnline = oldWidget.device.isOnline;
    final isOnline = widget.device.isOnline;
    if (wasOnline == isOnline) return;
    // An offline device cannot present its last list as current, and coming
    // back online is the page's own reason to read again.
    if (isOnline) {
      unawaited(_cubit.load());
    } else {
      _cubit.markDeviceUnavailable();
    }
  }

  @override
  void dispose() {
    unawaited(_cubit.close());
    super.dispose();
  }

  Future<void> _openEditor({StoredSecret? secret}) async {
    final saved = await SecretEditorDialog.show(context, cubit: _cubit, secret: secret);
    if (!mounted || saved != true) return;
    ToastUtils.showSuccess(context, AppLocalizations.of(context)!.secretSaved);
  }

  Future<void> _openDeleteDialog(StoredSecret secret) async {
    final deleted = await DeleteSecretDialog.show(context, cubit: _cubit, name: secret.name);
    if (!mounted || deleted != true) return;
    ToastUtils.showSuccess(context, AppLocalizations.of(context)!.secretDeleted);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return BlocProvider<SecretsCubit>.value(
      value: _cubit,
      child: BlocBuilder<SecretsCubit, SecretsState>(
        builder: (context, state) {
          final online = widget.device.isOnline;
          final unavailable = !online || state.status == SecretsStatus.deviceUnavailable;
          final actionsEnabled = !unavailable && !state.mutationInFlight;
          return PageFrame(
            key: const Key('secrets_page'),
            title: l10n.secrets,
            subtitle: l10n.secretsSubtitle(widget.device.name),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: FilledButton.icon(
                    key: const Key('secrets_add_btn'),
                    onPressed: actionsEnabled ? () => unawaited(_openEditor()) : null,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: Text(l10n.addSecret),
                  ),
                ),
                const SizedBox(height: 16),
                if (unavailable)
                  _SecretsUnavailableCard(
                    // A device that is online but whose transport failed can be
                    // retried; an offline device cannot answer at all.
                    onRetry: online ? () => unawaited(_cubit.load()) : null,
                  )
                else
                  _buildState(state, l10n, actionsEnabled: actionsEnabled),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildState(
    SecretsState state,
    AppLocalizations l10n, {
    required bool actionsEnabled,
  }) {
    if (state.showsList) {
      return _SecretList(
        secrets: state.secrets,
        actionsEnabled: actionsEnabled,
        onReplace: (secret) => unawaited(_openEditor(secret: secret)),
        onDelete: (secret) => unawaited(_openDeleteDialog(secret)),
      );
    }
    return switch (state.status) {
      SecretsStatus.empty => const _SecretsEmptyCard(),
      SecretsStatus.error => _SecretsErrorCard(
        failure: state.failure,
        onRetry: () => unawaited(_cubit.load()),
      ),
      _ => const _SecretsLoadingCard(),
    };
  }
}

/// A page skeleton while the first read of a device scope is in flight.
class _SecretsLoadingCard extends StatelessWidget {
  const _SecretsLoadingCard();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08);
    return SettingsCard(
      key: const Key('secrets_loading'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var row = 0; row < 3; row++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 12,
                    width: row.isEven ? 220 : 160,
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 10,
                    width: row.isEven ? 160 : 120,
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SecretsEmptyCard extends StatelessWidget {
  const _SecretsEmptyCard();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    return SettingsCard(
      key: const Key('secrets_empty'),
      child: Row(
        children: [
          Icon(Icons.lock_outline_rounded, size: 20, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(child: Text(l10n.secretsEmpty)),
        ],
      ),
    );
  }
}

/// The typed failure of the last read, plus Retry (C3).
class _SecretsErrorCard extends StatelessWidget {
  const _SecretsErrorCard({required this.failure, required this.onRetry});

  final SecretsFailure? failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final detail = secretsFailureText(l10n, failure?.code ?? SecretsErrorCode.unknown);
    return SettingsCard(
      key: const Key('secrets_error'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline_rounded, size: 20, color: colorScheme.error),
              const SizedBox(width: 12),
              Expanded(child: Text(l10n.secretsLoadFailed)),
            ],
          ),
          if (detail != null) ...[
            const SizedBox(height: 6),
            Text(detail, style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12)),
          ],
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('secrets_retry_btn'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(l10n.retry),
          ),
        ],
      ),
    );
  }
}

/// The offline banner: actions are disabled and no list is presented as current.
class _SecretsUnavailableCard extends StatelessWidget {
  const _SecretsUnavailableCard({this.onRetry});

  /// Retry for an online device whose transport failed; `null` when offline.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    return SettingsCard(
      key: const Key('secrets_unavailable_banner'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.cloud_off_outlined, size: 20, color: colorScheme.error),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.secretsUnavailable, style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  l10n.secretsUnavailableHint,
                  style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
                ),
                if (onRetry != null) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const Key('secrets_retry_btn'),
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    label: Text(l10n.retry),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SecretList extends StatelessWidget {
  const _SecretList({
    required this.secrets,
    required this.actionsEnabled,
    required this.onReplace,
    required this.onDelete,
  });

  final List<StoredSecret> secrets;
  final bool actionsEnabled;
  final ValueChanged<StoredSecret> onReplace;
  final ValueChanged<StoredSecret> onDelete;

  @override
  Widget build(BuildContext context) => Column(
    key: const Key('secrets_list'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final secret in secrets) ...[
        _SecretRow(
          secret: secret,
          actionsEnabled: actionsEnabled,
          onReplace: () => onReplace(secret),
          onDelete: () => onDelete(secret),
        ),
        const SizedBox(height: 10),
      ],
    ],
  );
}

/// One row: name, source, description (or its placeholder), updated date, and
/// the Replace/Delete actions. It never receives a value.
class _SecretRow extends StatelessWidget {
  const _SecretRow({
    required this.secret,
    required this.actionsEnabled,
    required this.onReplace,
    required this.onDelete,
  });

  final StoredSecret secret;
  final bool actionsEnabled;
  final VoidCallback onReplace;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final updatedAt = secret.updatedAt;
    final description = secret.hasDescription ? secret.description!.trim() : l10n.secretNoDescription;
    return SettingsCard(
      key: Key('secret_row_${secret.name}'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(top: 2, end: 12),
            child: Icon(Icons.key_rounded, size: 20, color: colorScheme.onSurfaceVariant),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      secret.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    _SecretSourcePill(source: secret.source),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 13),
                ),
                if (updatedAt != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    l10n.secretUpdatedAt(
                      MaterialLocalizations.of(context).formatShortDate(updatedAt.toLocal()),
                    ),
                    style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            key: Key('secret_replace_btn_${secret.name}'),
            tooltip: l10n.replaceSecret,
            icon: const Icon(Icons.swap_horiz_rounded, size: 20),
            onPressed: actionsEnabled ? onReplace : null,
          ),
          IconButton(
            key: Key('secret_delete_btn_${secret.name}'),
            tooltip: l10n.deleteSecret,
            icon: const Icon(Icons.delete_outline_rounded, size: 20),
            onPressed: actionsEnabled ? onDelete : null,
          ),
        ],
      ),
    );
  }
}

/// How the current value arrived (M5), in localized copy.
class _SecretSourcePill extends StatelessWidget {
  const _SecretSourcePill({required this.source});

  final SecretSource source;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final isUser = source == SecretSource.user;
    final color = isUser ? colorScheme.primary : colorScheme.tertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        isUser ? l10n.secretSourceUser : l10n.secretSourceAgent,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
