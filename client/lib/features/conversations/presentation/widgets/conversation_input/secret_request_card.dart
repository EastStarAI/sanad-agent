import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import '../../../domain/models/device_suspended_request.dart';
import '../../bloc/conversation_input_cubit.dart';
import '../../utils/text_utils.dart';

/// Composer card for a `system_request_secret` form (Plan 84).
///
/// Values typed here go only into the response command for this request.
/// They are never written to Client state, caches, the timeline or logs, and
/// the controllers are cleared as soon as the form is submitted or skipped.
class SecretRequestCard extends StatefulWidget {
  final DeviceSuspendedRequest request;
  final Color borderColor;

  const SecretRequestCard({
    super.key,
    required this.request,
    required this.borderColor,
  });

  @override
  State<SecretRequestCard> createState() => _SecretRequestCardState();
}

class _SecretRequestCardState extends State<SecretRequestCard> {
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, bool> _revealed = {};
  String? _missingLabel;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _resetFields();
  }

  @override
  void didUpdateWidget(covariant SecretRequestCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request.requestId != widget.request.requestId) {
      _resetFields();
    }
  }

  void _resetFields() {
    _disposeControllers();
    _revealed.clear();
    _missingLabel = null;
    _submitting = false;
    for (final field in widget.request.secretFields) {
      _controllers[field.name] = TextEditingController();
    }
  }

  void _disposeControllers() {
    for (final controller in _controllers.values) {
      controller.clear();
      controller.dispose();
    }
    _controllers.clear();
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  void _clearValues() {
    for (final controller in _controllers.values) {
      controller.clear();
    }
  }

  Future<void> _save() async {
    if (_submitting) return;
    final values = <String, String>{};
    for (final field in widget.request.secretFields) {
      final value = _controllers[field.name]?.text ?? '';
      if (value.isEmpty) {
        if (field.required) {
          setState(() => _missingLabel = field.label);
          return;
        }
        continue;
      }
      values[field.name] = value;
    }
    if (values.isEmpty) return;
    setState(() {
      _missingLabel = null;
      _submitting = true;
    });
    final cubit = context.read<ConversationInputCubit>();
    _clearValues();
    await cubit.submitSecretRequest(request: widget.request, values: values);
  }

  Future<void> _skip() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    final cubit = context.read<ConversationInputCubit>();
    _clearValues();
    await cubit.denyPendingSuspendedRequest(request: widget.request);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final reason = widget.request.secretReason;
    final replaces = widget.request.secretReplaces;

    return Column(
      key: const Key('secret_request_card'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(Icons.lock_outline_rounded, size: 16, color: colorScheme.secondary),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                l10n.secretRequestTitle,
                style: GoogleFonts.inter(
                  color: colorScheme.onSurface,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        if (reason.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: widget.borderColor),
            ),
            child: Text(
              reason,
              key: const Key('secret_request_reason'),
              textDirection: TextUtils.getTextDirection(reason),
              style: TextStyle(color: colorScheme.onSurface, fontSize: 13, height: 1.45),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.shield_outlined, size: 13, color: colorScheme.primary.withValues(alpha: 0.8)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l10n.secretRequestVaultNotice,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final field in widget.request.secretFields) ...[
          _buildField(context, l10n, field, replaces: replaces.contains(field.name)),
          const SizedBox(height: 10),
        ],
        if (_missingLabel != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              l10n.secretRequestRequiredField(_missingLabel!),
              key: const Key('secret_request_error'),
              style: GoogleFonts.inter(
                color: colorScheme.error,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                key: const Key('secret_request_save_btn'),
                onPressed: _submitting ? null : _save,
                icon: const Icon(Icons.check_rounded, size: 16),
                label: Text(l10n.secretRequestSave),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              key: const Key('secret_request_skip_btn'),
              onPressed: _submitting ? null : _skip,
              child: Text(l10n.secretRequestSkip),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildField(
    BuildContext context,
    AppLocalizations l10n,
    SecretRequestFieldSpec field, {
    required bool replaces,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final hidden = field.masked && !(_revealed[field.name] ?? false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                field.label,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
            ),
            if (field.required)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 4),
                child: Text('*', style: TextStyle(fontSize: 12, color: colorScheme.error)),
              ),
            const SizedBox(width: 8),
            Text(
              field.name,
              style: GoogleFonts.firaCode(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
        if (field.description.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            field.description,
            textDirection: TextUtils.getTextDirection(field.description),
            style: GoogleFonts.inter(
              fontSize: 11,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
            ),
          ),
        ],
        if (replaces) ...[
          const SizedBox(height: 2),
          Text(
            l10n.secretRequestReplacesNotice,
            key: Key('secret_replaces_${field.name}'),
            style: GoogleFonts.inter(fontSize: 11, color: colorScheme.tertiary),
          ),
        ],
        const SizedBox(height: 6),
        TextField(
          key: Key('secret_input_${field.name}'),
          controller: _controllers[field.name],
          obscureText: hidden,
          enableSuggestions: false,
          autocorrect: false,
          enableIMEPersonalizedLearning: false,
          keyboardType: field.masked ? TextInputType.visiblePassword : TextInputType.text,
          textDirection: TextDirection.ltr,
          style: GoogleFonts.inter(fontSize: 13),
          onSubmitted: (_) => _save(),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.15),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: widget.borderColor),
            ),
            suffixIcon: field.masked
                ? IconButton(
                    key: Key('secret_toggle_visibility_${field.name}'),
                    tooltip: hidden ? l10n.secretRequestShowValue : l10n.secretRequestHideValue,
                    icon: Icon(
                      hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      size: 18,
                    ),
                    onPressed: () => setState(() => _revealed[field.name] = hidden),
                  )
                : null,
          ),
        ),
      ],
    );
  }
}
