import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:sanad_client/core/theme/activity_animation_policy.dart';

/// A project-wide unified progress indicator.
///
/// When continuous animations are permitted by [ActivityAnimationPolicy.allowContinuousActivityAnimation]
/// (or when a determinate [value] is supplied), this renders a standard [CircularProgressIndicator].
///
/// On platforms where continuous motion is disabled (such as Windows, to avoid severe GPU/CPU raster spikes),
/// this renders a static ring matching the exact visual geometry, stroke width, and color of
/// [CircularProgressIndicator] without instantiating any [Ticker] or [AnimationController].
class AppProgressIndicator extends StatelessWidget {
  final double? value;
  final Color? backgroundColor;
  final Color? color;
  final Animation<Color?>? valueColor;
  final double strokeWidth;
  final double strokeAlign;
  final StrokeCap? strokeCap;
  final String? semanticsLabel;
  final String? semanticsValue;

  const AppProgressIndicator({
    super.key,
    this.value,
    this.backgroundColor,
    this.color,
    this.valueColor,
    this.strokeWidth = 4.0,
    this.strokeAlign = 0.0,
    this.strokeCap,
    this.semanticsLabel,
    this.semanticsValue,
  });

  @override
  Widget build(BuildContext context) {
    if (value != null || ActivityAnimationPolicy.allowContinuousActivityAnimation) {
      return CircularProgressIndicator(
        value: value,
        backgroundColor: backgroundColor,
        color: color,
        valueColor: valueColor,
        strokeWidth: strokeWidth,
        strokeAlign: strokeAlign,
        strokeCap: strokeCap,
        semanticsLabel: semanticsLabel,
        semanticsValue: semanticsValue,
      );
    }

    final theme = Theme.of(context);
    final indicatorTheme = ProgressIndicatorTheme.of(context);
    final resolvedColor = color ?? valueColor?.value ?? indicatorTheme.color ?? theme.colorScheme.primary;
    final resolvedBg = backgroundColor ?? indicatorTheme.circularTrackColor;

    return Semantics(
      label: semanticsLabel ?? 'Loading',
      value: semanticsValue,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minWidth: 36.0,
          minHeight: 36.0,
        ),
        child: CustomPaint(
          painter: _StaticCircularProgressPainter(
            color: resolvedColor,
            backgroundColor: resolvedBg,
            strokeWidth: strokeWidth,
            strokeCap: strokeCap ?? StrokeCap.round,
          ),
        ),
      ),
    );
  }
}

class _StaticCircularProgressPainter extends CustomPainter {
  final Color color;
  final Color? backgroundColor;
  final double strokeWidth;
  final StrokeCap strokeCap;

  const _StaticCircularProgressPainter({
    required this.color,
    this.backgroundColor,
    required this.strokeWidth,
    required this.strokeCap,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    if (radius <= 0) return;

    if (backgroundColor != null && backgroundColor != Colors.transparent) {
      final bgPaint = Paint()
        ..color = backgroundColor!
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth;
      canvas.drawCircle(center, radius, bgPaint);
    }

    final fgPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = strokeCap;

    // Draw a static complete 360-degree ring representing the progress indicator without motion
    canvas.drawCircle(center, radius, fgPaint);
  }

  @override
  bool shouldRepaint(covariant _StaticCircularProgressPainter oldDelegate) {
    return oldDelegate.color != color ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.strokeCap != strokeCap;
  }
}
