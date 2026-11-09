import 'package:flutter/material.dart';

import 'app_progress_indicator.dart';

/// The product's single stop control.
///
/// The conversation composer and the dictation button both stop something, and
/// each drew its own button: same 32 px footprint, but a different glyph, icon
/// scale, tint, and only one of them carried the error outline. Two designs for
/// one meaning made the dictation Stop read as a different affordance from the
/// Stop that ends a reply.
///
/// This widget owns that design. A caller supplies only its own key, label,
/// callback, and whether the stop is being accepted — so a surface can neither
/// drift visually nor lose its own behaviour and test seam.
class StopActionButton extends StatelessWidget {
  const StopActionButton({
    super.key,
    this.buttonKey,
    required this.tooltip,
    required this.onPressed,
    this.onLongPress,
    this.busy = false,
    this.progressIndicatorKey,
  });

  /// The surface's own key, kept on the `IconButton` itself.
  ///
  /// A caller's seam is the control it presses, not this wrapper: existing tests
  /// read `IconButton.onPressed` off that key to prove enabledness.
  final Key? buttonKey;

  /// The control's only label: it never shows visible text.
  final String tooltip;

  /// Null renders the control disabled, which is how an accepted stop reads.
  final VoidCallback? onPressed;

  /// A surface that opens its settings on a long press keeps that gesture.
  final VoidCallback? onLongPress;

  /// True while the stop is being accepted: the glyph becomes a spinner.
  final bool busy;

  /// Caller-owned key for the spinner, so each surface keeps its own seam.
  final Key? progressIndicatorKey;

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return SizedBox(
      width: 32,
      height: 32,
      child: Tooltip(
        message: tooltip,
        textAlign: TextAlign.center,
        child: IconButton(
          key: buttonKey,
          onPressed: onPressed,
          onLongPress: onLongPress,
          style: IconButton.styleFrom(
            backgroundColor: error.withValues(alpha: 0.1),
            side: BorderSide(color: error.withValues(alpha: 0.2)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: EdgeInsets.zero,
          ),
          icon: busy
              ? SizedBox(
                  key: progressIndicatorKey,
                  width: 16,
                  height: 16,
                  child: AppProgressIndicator(strokeWidth: 2, color: error),
                )
              : Icon(Icons.stop_circle_outlined, size: 16, color: error),
        ),
      ),
    );
  }
}
