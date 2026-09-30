import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_state.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_setup_header.dart';

/// Form for a custom or local LLM endpoint (base URL + model + optional key).
class CustomEndpointForm extends StatefulWidget {
  const CustomEndpointForm({super.key});

  @override
  State<CustomEndpointForm> createState() => _CustomEndpointFormState();
}

class _CustomEndpointFormState extends State<CustomEndpointForm> {
  final _baseUrlController = TextEditingController();
  final _modelController = TextEditingController();
  final _keyController = TextEditingController();
  String _protocol = 'openai_compatible';
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    final state = context.read<ProviderSetupCubit>().state;
    final template = state.selectedTemplate;
    final provider = state.selectedProvider;
    _protocol = template?.protocol ?? 'openai_compatible';
    final defaultBaseUrl = template?.defaultBaseUrl ?? provider?.defaultBaseUrl;
    if (defaultBaseUrl != null && defaultBaseUrl.isNotEmpty) {
      _baseUrlController.text = defaultBaseUrl;
    }
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _modelController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ProviderSetupCubit, ProviderSetupState>(
      builder: (context, state) {
        final provider = state.selectedProvider;
        final saving = state.status == ProviderSetupStatus.saving;
        if (_baseUrlController.text.isEmpty && provider?.defaultBaseUrl != null) {
          _baseUrlController.text = provider!.defaultBaseUrl!;
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ProviderSetupHeader(
              title: provider?.displayName ?? 'Custom Endpoint',
              subtitle: 'Connect to a local or self-hosted LLM endpoint.',
              icon: Icons.dns_outlined,
            ),
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              initialValue: _protocol,
              decoration: const InputDecoration(
                labelText: 'Protocol',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.alt_route),
              ),
              items: const [
                DropdownMenuItem(
                  value: 'openai_compatible',
                  child: Text('OpenAI API Compatible'),
                ),
                DropdownMenuItem(
                  value: 'anthropic_compatible',
                  child: Text('Anthropic API Compatible'),
                ),
              ],
              onChanged: saving
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _protocol = value);
                      }
                    },
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _baseUrlController,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'http://localhost:11434/v1',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _modelController,
              decoration: const InputDecoration(
                labelText: 'Model name',
                hintText: 'llama3.1',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.memory),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _keyController,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: 'API Key (optional)',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.vpn_key_outlined),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            if (state.error != null) ...[
              const SizedBox(height: 12),
              Text(
                state.error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                TextButton(
                  onPressed: saving ? null : () => context.read<ProviderSetupCubit>().backToPicker(),
                  child: const Text('Back'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    icon: saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: AppProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(saving ? 'Saving...' : 'Save & continue'),
                    onPressed: saving ? null : _submit,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  void _submit() {
    final baseUrl = _baseUrlController.text.trim();
    final model = _modelController.text.trim();
    if (baseUrl.isEmpty || model.isEmpty) return;
    unawaited(
      context.read<ProviderSetupCubit>().saveCustomEndpoint(
        protocol: _protocol,
        baseUrl: baseUrl,
        model: model,
        apiKey: _keyController.text.trim().isEmpty ? null : _keyController.text.trim(),
      ),
    );
  }
}
