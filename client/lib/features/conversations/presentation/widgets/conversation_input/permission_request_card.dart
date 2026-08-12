import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../../../utils/app_platform.dart';
import '../../../domain/models/device_suspended_request.dart';
import '../../bloc/conversation_input_cubit.dart';
import 'permission_request_presentation.dart';

class PermissionRequestCard extends StatefulWidget {
  final DeviceSuspendedRequest request;
  final Color borderColor;

  const PermissionRequestCard({
    super.key,
    required this.request,
    required this.borderColor,
  });

  @override
  State<PermissionRequestCard> createState() => _PermissionRequestCardState();
}

class _PermissionRequestCardState extends State<PermissionRequestCard> {
  final TextEditingController _denyCommentController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _showDenyComment = false;

  @override
  void initState() {
    super.initState();
    if (!AppPlatform.isMobile) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focusNode.requestFocus();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant PermissionRequestCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request.requestId != widget.request.requestId) {
      setState(() {
        _showDenyComment = false;
        _denyCommentController.clear();
      });
      if (!AppPlatform.isMobile) {
        _focusNode.requestFocus();
      }
    }
  }

  @override
  void dispose() {
    _denyCommentController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (AppPlatform.isMobile || _showDenyComment) {
      return KeyEventResult.ignored;
    }

    if (event is KeyDownEvent) {
      final character = event.character;
      final logicalKey = event.logicalKey;

      final index = _matchDigit(character, logicalKey);
      if (index != null) {
        _triggerOption(index);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  int? _matchDigit(String? character, LogicalKeyboardKey logicalKey) {
    if (character == '1' || character == '١') return 0;
    if (character == '2' || character == '٢') return 1;
    if (character == '3' || character == '٣') return 2;
    if (character == '4' || character == '٤') return 3;

    if (logicalKey == LogicalKeyboardKey.digit1 || logicalKey == LogicalKeyboardKey.numpad1) {
      return 0;
    }
    if (logicalKey == LogicalKeyboardKey.digit2 || logicalKey == LogicalKeyboardKey.numpad2) {
      return 1;
    }
    if (logicalKey == LogicalKeyboardKey.digit3 || logicalKey == LogicalKeyboardKey.numpad3) {
      return 2;
    }
    if (logicalKey == LogicalKeyboardKey.digit4 || logicalKey == LogicalKeyboardKey.numpad4) {
      return 3;
    }

    return null;
  }

  void _triggerOption(int index) {
    switch (index) {
      case 0:
        _approveSuspendedRequest(context, widget.request, 'once');
      case 1:
        _approveSuspendedRequest(context, widget.request, 'session');
      case 2:
        _approveSuspendedRequest(context, widget.request, 'workspace');
      case 3:
        setState(() {
          _showDenyComment = true;
          _denyCommentController.clear();
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final presentation = PermissionRequestPresentation.fromRequest(
      widget.request,
    );
    final showNumbers = !AppPlatform.isMobile;

    final cardContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.shield_outlined, size: 16, color: colorScheme.tertiary),
            const SizedBox(width: 8),
            Text(
              presentation.title,
              style: GoogleFonts.inter(
                color: colorScheme.onSurface,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Color.alphaBlend(
              colorScheme.onSurface.withValues(alpha: 0.07),
              colorScheme.surfaceContainerHighest,
            ),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: widget.borderColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var index = 0; index < presentation.details.length; index++) ...[
                if (index > 0) const SizedBox(height: 8),
                SelectableText.rich(
                  TextSpan(
                    style: TextStyle(
                      color: colorScheme.onSurface,
                      fontSize: 13,
                      height: 1.45,
                    ),
                    children: [
                      if (presentation.details[index].label != null)
                        TextSpan(
                          text: '${presentation.details[index].label}: ',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      TextSpan(
                        text: presentation.details[index].value,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        _buildPermissionAction(
          context,
          label: showNumbers ? '1  Yes, allow this time' : 'Yes, allow this time',
          onTap: () => _approveSuspendedRequest(context, widget.request, 'once'),
          primary: true,
        ),
        const SizedBox(height: 8),
        _buildPermissionAction(
          context,
          label: showNumbers ? '2  Yes, allow for this session' : 'Yes, allow for this session',
          onTap: () => _approveSuspendedRequest(context, widget.request, 'session'),
        ),
        const SizedBox(height: 8),
        _buildPermissionAction(
          context,
          label: showNumbers ? '3  Yes, always allow in this workspace' : 'Yes, always allow in this workspace',
          onTap: () => _approveSuspendedRequest(context, widget.request, 'workspace'),
        ),
        const SizedBox(height: 8),
        _buildPermissionAction(
          context,
          label: showNumbers ? '4  No' : 'No',
          onTap: () {
            setState(() {
              _showDenyComment = !_showDenyComment;
              if (!_showDenyComment) {
                _denyCommentController.clear();
              }
            });
          },
        ),
        if (_showDenyComment) ...[
          const SizedBox(height: 10),
          TextField(
            controller: _denyCommentController,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              hintText: 'Tell the agent what to do instead (optional)',
              hintStyle: GoogleFonts.inter(fontSize: 13),
              filled: true,
              fillColor: colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.25,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: widget.borderColor),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: widget.borderColor),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: () => _denySuspendedRequest(context, widget.request),
              child: const Text('Submit'),
            ),
          ),
        ],
      ],
    );

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: cardContent,
    );
  }

  void _approveSuspendedRequest(
    BuildContext context,
    DeviceSuspendedRequest request,
    String scope,
  ) {
    setState(() {
      _showDenyComment = false;
      _denyCommentController.clear();
    });
    unawaited(
      context.read<ConversationInputCubit>().approvePendingSuspendedRequest(
        request: request,
        scope: scope,
      ),
    );
  }

  void _denySuspendedRequest(
    BuildContext context,
    DeviceSuspendedRequest request,
  ) {
    final comment = _denyCommentController.text.trim();
    setState(() {
      _showDenyComment = false;
      _denyCommentController.clear();
    });
    unawaited(
      context.read<ConversationInputCubit>().denyPendingSuspendedRequest(
        request: request,
        comment: comment.isEmpty ? null : comment,
      ),
    );
  }

  Widget _buildPermissionAction(
    BuildContext context, {
    required String label,
    required VoidCallback onTap,
    bool primary = false,
    Key? key,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return InkWell(
      key: key,
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: primary
              ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)
              : colorScheme.surfaceContainerHighest.withValues(alpha: 0.28),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: primary ? colorScheme.primary.withValues(alpha: 0.25) : colorScheme.outline.withValues(alpha: 0.18),
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            color: colorScheme.onSurface,
            fontSize: 13,
            fontWeight: primary ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
