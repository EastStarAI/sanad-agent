import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_dto.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_state.dart';

/// Lists every supported provider from the agent's `ProviderRegistry`.
/// Shows configured/authenticated/current badges and routes to the right
/// sub-flow on tap. No provider list is hardcoded here.
class ProviderPickerView extends StatelessWidget {
  const ProviderPickerView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return BlocBuilder<ProviderSetupCubit, ProviderSetupState>(
      builder: (context, state) {
        if (state.providers.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                state.error ?? 'No providers available.',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Choose your AI provider',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'The agent needs an LLM provider before you can start chatting. '
              'Pick one below to configure it.',
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: 20),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: state.providers.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final provider = state.providers[index];
                return _ProviderCard(
                  key: Key('provider_card_item_${provider.id}'),
                  provider: provider,
                  onTap: () {
                    final template = state.templates.where((t) => t.name == provider.id).firstOrNull;
                    if (template != null) {
                      context.read<ProviderSetupCubit>().selectTemplate(
                        template,
                      );
                    }
                  },
                );
              },
            ),
            if (state.error != null) ...[
              const SizedBox(height: 12),
              Text(
                state.error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        );
      },
    );
  }
}

class _ProviderCard extends StatelessWidget {
  final ProviderDto provider;
  final VoidCallback onTap;

  const _ProviderCard({
    super.key,
    required this.provider,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key('provider_card_${provider.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            border: Border.all(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.1),
            ),
            borderRadius: BorderRadius.circular(14),
            color: provider.isCurrent
                ? theme.colorScheme.primary.withValues(alpha: 0.06)
                : theme.colorScheme.onSurface.withValues(alpha: 0.02),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  provider.isOAuth ? Icons.key_outlined : Icons.vpn_key_outlined,
                  color: theme.colorScheme.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            provider.displayName,
                            key: Key('provider_name_${provider.id}'),
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (provider.isCurrent)
                          _Badge(
                            label: 'Active',
                            color: theme.colorScheme.primary,
                          ),
                        if (provider.configured && !provider.isCurrent)
                          _Badge(
                            label: 'Configured',
                            color: theme.colorScheme.tertiary,
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      provider.description.isEmpty ? _authFlowLabel(provider) : provider.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _authFlowLabel(ProviderDto p) {
    switch (p.authFlow) {
      case 'device_code':
        return 'Sign in with a device code';
      case 'loopback':
        return 'Sign in via browser';
      case 'external':
        return 'External sign-in';
      case 'custom_endpoint':
        return 'Custom or local endpoint';
      default:
        return 'API key';
    }
  }
}

class _Badge extends StatelessWidget {
  final String label;
  final Color color;
  const _Badge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }
}
