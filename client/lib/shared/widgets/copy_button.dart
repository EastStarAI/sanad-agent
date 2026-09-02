import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sanad_client/utils/toast_utils.dart';

/// Shared visual contract for compact conversation action buttons.
abstract final class ConversationActionStyle {
  static const double buttonSize = 28.0;
  static const double iconSize = 15.0;
  static const double iconAlpha = 0.6;
  static const BoxConstraints constraints = BoxConstraints.tightFor(
    width: buttonSize,
    height: buttonSize,
  );

  static Color iconColor(BuildContext context) => Theme.of(
    context,
  ).colorScheme.onSurfaceVariant.withValues(alpha: iconAlpha);
}

/// Visual constants for [CopyButton]. Centralized to comply with the
/// "no hardcoded magic values" project rule.
class _CopyButtonConstants {
  const _CopyButtonConstants._();

  static const Duration resetDelay = Duration(seconds: 2);
  static const Duration animationDuration = Duration(milliseconds: 200);
}

/// A compact icon button that copies [text] to the system clipboard and
/// briefly displays a confirmation icon.
///
/// On success, a success toast is shown and the icon swaps to a check mark
/// for [_CopyButtonConstants.resetDelay] before reverting. On failure, an
/// error toast is shown and the state is left untouched.
class CopyButton extends StatefulWidget {
  final String text;
  final String successMessage;
  final String errorMessage;

  const CopyButton({
    super.key,
    required this.text,
    required this.successMessage,
    this.errorMessage = 'Failed to copy to clipboard',
  });

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  bool _isCopied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.text));
    } catch (e) {
      if (!mounted) return;
      ToastUtils.showError(context, widget.errorMessage);
      return;
    }

    if (!mounted) return;

    setState(() => _isCopied = true);
    ToastUtils.showSuccess(context, widget.successMessage);

    // Cancel any pending reset so a rapid second tap doesn't get cut short
    // by an older scheduled callback.
    _resetTimer?.cancel();
    _resetTimer = Timer(_CopyButtonConstants.resetDelay, _resetCopiedState);
  }

  void _resetCopiedState() {
    if (!mounted) return;
    setState(() => _isCopied = false);
  }

  Widget _buildIcon(ColorScheme colorScheme) {
    if (_isCopied) {
      return Icon(
        Icons.check_circle_outline_rounded,
        key: const ValueKey('copied'),
        size: ConversationActionStyle.iconSize,
        color: colorScheme.primary,
      );
    }

    return Icon(
      Icons.copy_all_rounded,
      key: const ValueKey('copy'),
      size: ConversationActionStyle.iconSize,
      color: colorScheme.onSurfaceVariant.withValues(
        alpha: ConversationActionStyle.iconAlpha,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      button: true,
      label: _isCopied ? 'Copied' : 'Copy to clipboard',
      child: IconButton(
        tooltip: _isCopied ? 'Copied' : 'Copy',
        visualDensity: VisualDensity.compact,
        constraints: ConversationActionStyle.constraints,
        padding: EdgeInsets.zero,
        onPressed: _copy,
        icon: AnimatedSwitcher(
          duration: _CopyButtonConstants.animationDuration,
          transitionBuilder: (child, animation) {
            return ScaleTransition(scale: animation, child: child);
          },
          child: _buildIcon(colorScheme),
        ),
      ),
    );
  }
}
