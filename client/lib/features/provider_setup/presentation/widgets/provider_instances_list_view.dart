import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_dto.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_state.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_usage_section.dart';

const _kAccountMethods = ['device_code', 'loopback', 'external'];

class ProviderInstancesListView extends StatefulWidget {
  const ProviderInstancesListView({super.key});

  @override
  State<ProviderInstancesListView> createState() => _ProviderInstancesListViewState();
}

class _ProviderInstancesListViewState extends State<ProviderInstancesListView> {
  /// The target [DeviceConfig] consumed by both the setup cubit and the usage
  /// cubit to scope every usage snapshot to `device + provider_instance_id`
  /// (Task 55 §3.5).
  DeviceConfig? get _agent => context.read<ProviderSetupCubit>().agent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return BlocBuilder<ProviderSetupCubit, ProviderSetupState>(
      builder: (context, state) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                Text(
                  'Configured Providers',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                ElevatedButton.icon(
                  key: const Key('add_provider_btn'),
                  onPressed: () => context.read<ProviderSetupCubit>().backToPicker(),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add Provider'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Manage your AI credentials and models. Multiple accounts/keys are supported.',
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: 16),
            _buildFilteredList(context, state.instances, null),
            if (state.error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
                ),
                child: Text(
                  state.error!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildFilteredList(
    BuildContext context,
    List<ProviderInstanceDto> instances,
    bool? filterOAuth,
  ) {
    final filtered = instances.where((inst) {
      final isOAuth = _kAccountMethods.contains(inst.authMethod);
      if (filterOAuth == null) return true;
      if (filterOAuth) return isOAuth;
      return !isOAuth;
    }).toList();

    // Preserve the daemon order (newest first).
    if (filtered.isEmpty) {
      return Center(
        child: Text(
          'No provider instances configured here yet.',
          style: TextStyle(
            fontSize: 13,
            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
          ),
        ),
      );
    }

    final agent = _agent;
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: filtered.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final inst = filtered[index];
        final templates = context.read<ProviderSetupCubit>().state.templates;
        final providerName = templates
            .where((template) => template.name == inst.templateId)
            .map((template) => template.displayName)
            .firstOrNull;
        return _InstanceCard(
          key: Key('provider_instance_card_${inst.id}'),
          instance: inst,
          providerName: providerName ?? 'Provider',
          agent: agent,
        );
      },
    );
  }
}

class _InstanceCard extends StatelessWidget {
  final ProviderInstanceDto instance;
  final String providerName;

  /// Target device used to scope usage fetches to `device + instance`
  /// (Task 55 §3.5). `null` means the local daemon.
  final DeviceConfig? agent;

  const _InstanceCard({
    super.key,
    required this.instance,
    required this.providerName,
    this.agent,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOAuth = _kAccountMethods.contains(instance.authMethod);
    final isReady = instance.status == 'ready';
    final isDraft = instance.status == 'draft';
    final setupState = context.watch<ProviderSetupCubit>().state;
    final operation = setupState.instanceOperations[instance.id];
    final feedback = setupState.instanceFeedback[instance.id];
    final busy = operation != null;

    return Container(
      key: Key('provider_instance_${instance.id}'),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: instance.isDefault
              ? theme.colorScheme.primary.withValues(alpha: 0.4)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.05),
          width: instance.isDefault ? 1.5 : 1,
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            instance.displayName,
                            key: Key('provider_instance_name_${instance.id}'),
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (instance.isDefault) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              'Default',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      providerName,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                    if (instance.defaultModel != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Model: ${instance.defaultModel}',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                    if (isOAuth && instance.credential?.accountLabel != null) ...[
                      const SizedBox(height: 2),
                      SelectableText(
                        'Account: ${instance.credential!.accountLabel}',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                    if (isOAuth &&
                        instance.credential?.accountName != null &&
                        instance.credential!.accountName != instance.credential!.accountLabel) ...[
                      const SizedBox(height: 2),
                      SelectableText(
                        'Name: ${instance.credential!.accountName}',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: isReady ? Colors.green.withValues(alpha: 0.1) : Colors.amber.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isReady ? Colors.green.withValues(alpha: 0.3) : Colors.amber.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(
                      instance.status.toUpperCase(),
                      key: Key('provider_instance_status_${instance.id}'),
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: isReady ? Colors.green : Colors.amber[800],
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isOAuth ? 'OAuth Account' : 'API Key',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ),
                ],
              ),
            ],
          ),
          // Usage & limits disclosure (Task 55 §3.6). Renders only when the
          // daemon reports an adapter for this instance's template; hidden
          // phase and the widget itself collapse to nothing otherwise. Late
          // loading and transient failure never block the parent card.
          ProviderUsageSection(
            agent: agent,
            instanceId: instance.id,
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 8),
          if (operation != null || feedback != null) ...[
            Text(
              operation ?? feedback!,
              key: Key('provider_feedback_${instance.id}'),
              style: TextStyle(
                fontSize: 12,
                color: operation != null ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
          ],
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            runSpacing: 4,
            children: [
              if (!instance.isDefault && !isDraft)
                TextButton.icon(
                  key: Key('provider_instance_make_default_${instance.id}'),
                  onPressed: isReady && !busy
                      ? () => unawaited(
                          context.read<ProviderSetupCubit>().setInstanceDefault(instance.id),
                        )
                      : null,
                  icon: const Icon(Icons.star_outline, size: 16),
                  label: const Text('Make Default'),
                ),
              if (!isDraft)
                TextButton.icon(
                  key: Key('provider_instance_test_${instance.id}'),
                  onPressed: busy
                      ? null
                      : () => unawaited(
                          context.read<ProviderSetupCubit>().testInstance(instance.id),
                        ),
                  icon: const Icon(Icons.flash_on, size: 16),
                  label: const Text('Test'),
                ),
              TextButton.icon(
                key: Key(isDraft ? 'provider_instance_resume_${instance.id}' : 'provider_instance_edit_${instance.id}'),
                onPressed: busy
                    ? null
                    : () {
                        final cubit = context.read<ProviderSetupCubit>();
                        isDraft ? cubit.resumeDraft(instance) : cubit.selectInstanceForEdit(instance);
                      },
                icon: Icon(
                  isDraft ? Icons.play_arrow : Icons.edit_outlined,
                  size: 16,
                ),
                label: Text(isDraft ? 'Resume setup' : 'Edit'),
              ),
              TextButton.icon(
                key: Key('provider_instance_delete_${instance.id}'),
                onPressed: busy ? null : () => _confirmDelete(context),
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('Delete'),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _confirmDelete(BuildContext context) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: const Text('Delete Provider Instance?'),
          content: Text(
            instance.isDefault
                ? '"${instance.displayName}" is the default provider. Deleting it removes its credentials and may stop model requests until another ready provider is made default.'
                : 'Delete "${instance.displayName}" and its stored credentials?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('Cancel'),
            ),
            TextButton(
              key: const Key('confirm_delete_provider_button'),
              onPressed: () {
                Navigator.pop(dialogCtx);
                unawaited(context.read<ProviderSetupCubit>().removeInstance(instance.id));
              },
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              child: const Text('Delete'),
            ),
          ],
        ),
      ),
    );
  }
}
