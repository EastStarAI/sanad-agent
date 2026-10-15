import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../domain/models/device_suspended_request.dart';
import '../../bloc/conversation_input_cubit.dart';

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
  final Map<String, bool> _obscureState = {};
  String? _validationError;

  @override
  void initState() {
    super.initState();
    _initFields();
  }

  @override
  void didUpdateWidget(covariant SecretRequestCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request.requestId != widget.request.requestId) {
      _disposeControllers();
      _initFields();
      setState(() {
        _validationError = null;
      });
    }
  }

  void _initFields() {
    _controllers.clear();
    _obscureState.clear();
    for (final field in widget.request.secretFields) {
      final id = field['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final defaultVal = field['default_value']?.toString() ?? '';
      _controllers[id] = TextEditingController(text: defaultVal);
      final isSecret = field['is_secret'] as bool? ?? true;
      _obscureState[id] = isSecret;
    }
  }

  void _disposeControllers() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
  }

  @override
  void dispose() {
    _disposeControllers();
    super.dispose();
  }

  Future<void> _handleSave() async {
    final fields = widget.request.secretFields;
    final Map<String, String> values = {};

    for (final field in fields) {
      final id = field['id']?.toString() ?? '';
      if (id.isEmpty) continue;
      final isRequired = field['required'] as bool? ?? true;
      final val = _controllers[id]?.text ?? '';

      if (isRequired && val.trim().isEmpty) {
        final label = field['label']?.toString() ?? id;
        setState(() {
          _validationError = 'Please fill in required field: $label';
        });
        return;
      }
      values[id] = val;
    }

    setState(() {
      _validationError = null;
    });

    await context.read<ConversationInputCubit>().answerPendingSuspendedRequest(
      request: widget.request,
      answer: jsonEncode(values),
    );
  }

  Future<void> _handleSkip() async {
    await context.read<ConversationInputCubit>().denyPendingSuspendedRequest(
      request: widget.request,
      comment: 'User skipped secret request',
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final fields = widget.request.secretFields;
    final reason = widget.request.secretReason;
    final targetVault = widget.request.targetVault;
    final writeEnv = widget.request.writeToWorkspaceEnv;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Header Row
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(
                  Icons.lock_outline_rounded,
                  size: 16,
                  color: colorScheme.secondary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Credentials Required',
                  style: GoogleFonts.inter(
                    color: colorScheme.onSurface,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: widget.borderColor.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    targetVault,
                    style: GoogleFonts.inter(
                      color: colorScheme.onSurface.withValues(alpha: 0.7),
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
            TextButton(
              key: const Key('dismiss_secret_request_btn'),
              onPressed: _handleSkip,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                'Skip',
                style: GoogleFonts.inter(
                  color: colorScheme.onSurface.withValues(alpha: 0.5),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),

        // Reason box
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
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ),
        ],

        // Zero-leak security reassurance
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(
              Icons.shield_outlined,
              size: 13,
              color: colorScheme.primary.withValues(alpha: 0.8),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                writeEnv != null && writeEnv.isNotEmpty
                    ? 'Saved directly to secure OS vault and $writeEnv. Never exposed to AI models.'
                    : 'Saved directly to secure OS vault. Never exposed to AI models or transcripts.',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 12),

        // Form fields
        for (final field in fields) ...[
          _buildFieldInput(context, field),
          const SizedBox(height: 10),
        ],

        // Validation error
        if (_validationError != null) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _validationError!,
              style: GoogleFonts.inter(
                color: colorScheme.error,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],

        // Action Buttons Row
        Row(
          children: [
            Expanded(
              child: _buildPermissionAction(
                context,
                label: 'Save to Vault',
                primary: true,
                icon: Icons.check_rounded,
                key: const Key('save_to_vault_btn'),
                onTap: _handleSave,
              ),
            ),
            const SizedBox(width: 8),
            _buildPermissionAction(
              context,
              label: 'Skip',
              primary: false,
              key: const Key('skip_secret_request_btn'),
              onTap: _handleSkip,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFieldInput(BuildContext context, Map<String, dynamic> field) {
    final colorScheme = Theme.of(context).colorScheme;
    final id = field['id']?.toString() ?? '';
    final label = field['label']?.toString() ?? id;
    final desc = field['description']?.toString() ?? '';
    final isSecret = field['is_secret'] as bool? ?? true;
    final isRequired = field['required'] as bool? ?? true;
    final isObscured = _obscureState[id] ?? isSecret;
    final controller = _controllers[id];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurface,
              ),
            ),
            if (isRequired) ...[
              const SizedBox(width: 4),
              Text(
                '*',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: colorScheme.error,
                ),
              ),
            ],
          ],
        ),
        if (desc.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            desc,
            style: GoogleFonts.inter(
              fontSize: 11,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
        const SizedBox(height: 6),
        TextField(
          key: Key('secret_input_$id'),
          controller: controller,
          obscureText: isObscured,
          enableSuggestions: !isSecret,
          autocorrect: !isSecret,
          style: GoogleFonts.inter(fontSize: 13),
          decoration: InputDecoration(
            hintText: 'Enter $label',
            hintStyle: GoogleFonts.inter(
              fontSize: 13,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
            ),
            filled: true,
            fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.15),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: widget.borderColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
            ),
            suffixIcon: isSecret
                ? IconButton(
                    key: Key('toggle_visibility_$id'),
                    icon: Icon(
                      isObscured ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      size: 18,
                      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                    onPressed: () {
                      setState(() {
                        _obscureState[id] = !isObscured;
                      });
                    },
                  )
                : null,
          ),
        ),
      ],
    );
  }

  Widget _buildPermissionAction(
    BuildContext context, {
    required String label,
    required VoidCallback onTap,
    bool primary = false,
    IconData? icon,
    Key? key,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      key: key,
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        decoration: BoxDecoration(
          color: primary
              ? colorScheme.primary
              : colorScheme.surfaceContainerHighest.withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: primary
                ? colorScheme.primary
                : colorScheme.outline.withValues(alpha: 0.18),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 15,
                color: primary ? colorScheme.onPrimary : colorScheme.onSurface,
              ),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: GoogleFonts.inter(
                color: primary ? colorScheme.onPrimary : colorScheme.onSurface,
                fontSize: 13,
                fontWeight: primary ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
