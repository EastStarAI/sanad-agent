import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_state.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_setup_header.dart';
import 'package:url_launcher/url_launcher.dart';

/// Form for entering an API key (and optional base URL / model) for a
/// provider whose auth flow is `api_key`. Shows a "Get a key" button when the
/// catalog provides a `docs_url`.
class ApiKeyProviderForm extends StatefulWidget {
  const ApiKeyProviderForm({super.key});

  @override
  State<ApiKeyProviderForm> createState() => _ApiKeyProviderFormState();
}

class _ApiKeyProviderFormState extends State<ApiKeyProviderForm> {
  final _keyController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _modelController = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _keyController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ProviderSetupCubit, ProviderSetupState>(
      builder: (context, state) {
        final provider = state.selectedProvider;
        final template = state.selectedTemplate;
        final instance = state.selectedInstance;

        final displayName = instance?.displayName ?? provider?.displayName ?? template?.displayName ?? 'Provider';
        final defaultBaseUrl = instance?.baseUrl ?? provider?.defaultBaseUrl ?? template?.defaultBaseUrl;
        final docsUrl = provider?.docsUrl ?? template?.docsUrl;
        final showBaseUrl =
            defaultBaseUrl != null ||
            provider?.envBaseUrlName != null ||
            provider?.authFlow == 'custom_endpoint' ||
            template?.name == 'custom';

        _baseUrlController.text = _baseUrlController.text.isEmpty && defaultBaseUrl != null
            ? defaultBaseUrl
            : _baseUrlController.text;

        final saving = state.status == ProviderSetupStatus.saving;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ProviderSetupHeader(
              title: displayName,
              subtitle: 'Enter your API key to continue.',
              icon: Icons.vpn_key_outlined,
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _keyController,
              obscureText: _obscure,
              decoration: InputDecoration(
                labelText: '$displayName API Key',
                hintText: 'Paste your API key',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.vpn_key_outlined),
                suffixIcon: IconButton(
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            if (showBaseUrl) ...[
              const SizedBox(height: 14),
              TextField(
                controller: _baseUrlController,
                decoration: const InputDecoration(
                  labelText: 'Base URL (optional)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.link),
                ),
              ),
            ],
            const SizedBox(height: 14),
            if (docsUrl != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Get a key'),
                  onPressed: () => _launchUrl(docsUrl),
                ),
              ),
            if (state.error != null) ...[
              const SizedBox(height: 8),
              Text(
                state.error!,
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ],
            const SizedBox(height: 24),
            Row(
              children: [
                TextButton(
                  onPressed: saving ? null : () => context.read<ProviderSetupCubit>().backToInstances(),
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
    final key = _keyController.text.trim();
    final cubit = context.read<ProviderSetupCubit>();
    final template = cubit.state.selectedTemplate;
    // An empty key is allowed only when the template declares the key as
    // optional (Plan 29 §7.1 / criterion 32). Custom providers are optional.
    final isOptional =
        template?.isApiKeyOptional == true || template?.name == 'custom' || template?.authFlow == 'custom_endpoint';
    if (key.isEmpty && !isOptional) {
      setState(() {});
      return;
    }
    unawaited(
      cubit.saveApiKey(
        apiKey: key,
        baseUrl: _baseUrlController.text.trim().isEmpty ? null : _baseUrlController.text.trim(),
      ),
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
