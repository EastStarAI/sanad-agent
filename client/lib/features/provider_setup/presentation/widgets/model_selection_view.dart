import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_state.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_setup_header.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_setup_step_scaffold.dart';

class ModelSelectionView extends StatefulWidget {
  const ModelSelectionView({super.key});

  @override
  State<ModelSelectionView> createState() => _ModelSelectionViewState();
}

class _ModelSelectionViewState extends State<ModelSelectionView> {
  final _manualFormKey = GlobalKey<FormState>();
  final _manualController = TextEditingController();

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ProviderSetupCubit, ProviderSetupState>(
      builder: (context, state) {
        final displayName =
            state.selectedInstance?.displayName ?? state.selectedTemplate?.displayName ?? 'this provider';
        final discovery = state.modelDiscoveryStatus;
        final saving = state.operation == ProviderSetupOperation.savingModel;
        final models = state.modelOptions?.models ?? const <String>[];

        return ProviderSetupStepScaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ProviderSetupHeader(
                title: 'Choose a model',
                subtitle: 'Select the default model for $displayName.',
                icon: Icons.memory,
              ),
              const SizedBox(height: 16),
              if (discovery == ModelDiscoveryStatus.loading)
                const _DiscoveryLoading()
              else if (discovery == ModelDiscoveryStatus.failed)
                _DiscoveryFailure(
                  message: state.modelDiscoveryError ?? 'Could not load models from this provider.',
                  suggestions: models,
                )
              else if (discovery == ModelDiscoveryStatus.manual)
                Form(
                  key: _manualFormKey,
                  child: TextFormField(
                    key: const Key('manual_model_field'),
                    controller: _manualController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Model name',
                      hintText: 'Enter the exact model identifier',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.edit),
                    ),
                    validator: (value) => value == null || value.trim().isEmpty ? 'Enter a model name' : null,
                    onChanged: (value) => context.read<ProviderSetupCubit>().selectModel(value.trim()),
                  ),
                )
              else
                _ModelList(models: models, selected: state.selectedModel),
              if (state.error != null) ...[
                const SizedBox(height: 12),
                Text(
                  state.error!,
                  key: const Key('model_selection_error'),
                  style: const TextStyle(
                    color: Colors.redAccent,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
          footer: OverflowBar(
            spacing: 8,
            overflowSpacing: 8,
            alignment: MainAxisAlignment.spaceBetween,
            overflowAlignment: OverflowBarAlignment.end,
            children: [
              TextButton(
                onPressed: saving ? null : () => context.read<ProviderSetupCubit>().backToProviderDetails(),
                child: const Text('Back'),
              ),
              if (discovery == ModelDiscoveryStatus.failed) ...[
                OutlinedButton.icon(
                  key: const Key('retry_model_discovery_button'),
                  onPressed: saving ? null : () => context.read<ProviderSetupCubit>().refreshModels(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
                FilledButton.tonalIcon(
                  key: const Key('add_model_button'),
                  onPressed: saving ? null : () => context.read<ProviderSetupCubit>().startManualModelEntry(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add Model'),
                ),
              ] else if (discovery != ModelDiscoveryStatus.loading)
                FilledButton.icon(
                  key: const Key('confirm_model_button'),
                  icon: saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: AppProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: Text(
                    saving
                        ? 'Saving...'
                        : discovery == ModelDiscoveryStatus.manual
                        ? 'Use Model'
                        : 'Confirm Model',
                  ),
                  onPressed: saving || state.selectedModel?.trim().isEmpty != false
                      ? null
                      : () {
                          if (discovery == ModelDiscoveryStatus.manual &&
                              !(_manualFormKey.currentState?.validate() ?? false)) {
                            return;
                          }
                          unawaited(
                            context.read<ProviderSetupCubit>().confirmModel(),
                          );
                        },
                ),
            ],
          ),
        );
      },
    );
  }
}

class _DiscoveryLoading extends StatelessWidget {
  const _DiscoveryLoading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          AppProgressIndicator(),
          SizedBox(height: 12),
          Text('Loading models from the provider...'),
        ],
      ),
    );
  }
}

class _DiscoveryFailure extends StatelessWidget {
  const _DiscoveryFailure({
    required this.message,
    required this.suggestions,
  });

  final String message;
  final List<String> suggestions;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const Key('model_discovery_failure'),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(message),
        ),
        if (suggestions.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            'Cached suggestions',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 4),
          Text(
            suggestions.join(', '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

class _ModelList extends StatelessWidget {
  const _ModelList({required this.models, required this.selected});

  final List<String> models;
  final String? selected;

  @override
  Widget build(BuildContext context) {
    if (models.isEmpty) {
      return const Text('No models are available. Retry or add one manually.');
    }
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: models.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final model = models[index];
        final isSelected = model == selected;
        return Material(
          color: Colors.transparent,
          child: ListTile(
            shape: RoundedRectangleBorder(
              side: BorderSide(
                color: isSelected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            leading: Icon(
              isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
            ),
            title: Text(model),
            onTap: () => context.read<ProviderSetupCubit>().selectModel(model),
          ),
        );
      },
    );
  }
}
