import 'package:flutter/material.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_runtime_cubit.dart';

class ProviderSelectionDialog extends StatelessWidget {
  final DeviceConfig? agent;
  final String? activeProviderId;
  final void Function(String providerId) onSelected;

  const ProviderSelectionDialog({
    super.key,
    required this.onSelected,
    this.agent,
    this.activeProviderId,
  });

  @override
  Widget build(BuildContext context) {
    final client = getIt<ProviderSetupClient>();
    return BlocProvider<ProviderRuntimeCubit>(
      create: (_) => ProviderRuntimeCubit(client: client, agent: agent),
      child: Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420, maxHeight: 520),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      'Continue With Provider',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => Navigator.of(context).pop(),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: BlocBuilder<ProviderRuntimeCubit, ProviderRuntimeState>(
                    builder: (context, state) {
                      if (state.loading && state.groups.isEmpty) {
                        return const Center(child: AppProgressIndicator(strokeWidth: 2));
                      }
                      if (state.error != null && state.groups.isEmpty) {
                        return Center(child: Text(state.error!));
                      }
                      if (state.groups.isEmpty) {
                        return const Center(child: Text('No configured providers'));
                      }
                      return ListView.separated(
                        itemCount: state.groups.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final group = state.groups[index];
                          final isSelected = group.providerId == activeProviderId;
                          return ListTile(
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                color: isSelected
                                    ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.32)
                                    : Theme.of(context).colorScheme.outline.withValues(alpha: 0.18),
                              ),
                            ),
                            leading: Icon(
                              group.runtimeReady ? Icons.check_circle_outline : Icons.error_outline,
                              size: 18,
                              color: group.runtimeReady
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).colorScheme.error,
                            ),
                            title: Text(group.displayName),
                            subtitle: Text(
                              group.models.selectedModel == null || group.models.selectedModel!.isEmpty
                                  ? 'No default model'
                                  : group.models.selectedModel!,
                            ),
                            trailing: isSelected ? const Icon(Icons.check, size: 18) : null,
                            onTap: () {
                              onSelected(group.providerId);
                              Navigator.of(context).pop();
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
