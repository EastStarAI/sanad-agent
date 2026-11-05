/// The dictation meter as the composer's own background.
///
/// While the user speaks, vertical bars grow behind the whole composer card so
/// the level is visible without looking at the mic button. Bars are drawn, not
/// laid out: one [CustomPaint] keeps the cost flat regardless of composer size.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_cubit.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_state.dart';

class DictationComposerBackdrop extends StatefulWidget {
  const DictationComposerBackdrop({super.key});

  @override
  State<DictationComposerBackdrop> createState() =>
      _DictationComposerBackdropState();
}

class _DictationComposerBackdropState extends State<DictationComposerBackdrop>
    with SingleTickerProviderStateMixin {
  /// Drives the travelling wave so the bars keep moving while a vowel is held
  /// (a static level would otherwise freeze the pattern).
  ///
  /// It only runs while a session is listening: an always-on ticker would keep
  /// the app repainting at 60 fps when idle and make `pumpAndSettle` in widget
  /// tests spin forever.
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  void _syncTicker(bool listening) {
    if (listening) {
      if (!_wave.isAnimating) _wave.repeat();
    } else if (_wave.isAnimating) {
      _wave.stop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return BlocConsumer<DictationCubit, DictationState>(
      listenWhen: (previous, current) =>
          previous.status != current.status ||
          previous.isActive != current.isActive,
      listener: (context, state) =>
          _syncTicker(state.status == DictationStatus.listening),
      // Rebuild on state changes only while the meter is actually visible.
      buildWhen: (previous, current) =>
          previous.isActive != current.isActive ||
          (current.isActive && (previous.level - current.level).abs() > 0.01),
      builder: (context, state) {
        final listening = state.status == DictationStatus.listening;
        return IgnorePointer(
          child: AnimatedOpacity(
            opacity: listening ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            child: AnimatedBuilder(
              animation: _wave,
              builder: (context, _) => CustomPaint(
                painter: _ComposerBarsPainter(
                  level: state.level,
                  phase: _wave.value,
                  color: colors.primary,
                ),
                size: Size.infinite,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ComposerBarsPainter extends CustomPainter {
  _ComposerBarsPainter({
    required this.level,
    required this.phase,
    required this.color,
  });

  final double level;
  final double phase;
  final Color color;

  static const double _barWidth = 4;
  static const double _gap = 5;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final pitch = _barWidth + _gap;
    final count = (size.width / pitch).floor();
    if (count <= 0) return;

    // A hair of activity even in silence so the surface reads as "listening".
    final amplitude = (0.10 + level * 0.90).clamp(0.0, 1.0);
    final paint = Paint()..color = color.withValues(alpha: 0.16 + level * 0.24);

    for (var i = 0; i < count; i++) {
      final wave = 0.55 + 0.45 * math.sin(phase * 2 * math.pi + i * 0.55);
      final height = size.height * amplitude * wave;
      if (height <= 0.5) continue;
      final left = i * pitch;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, size.height - height, _barWidth, height),
        const Radius.circular(2),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ComposerBarsPainter old) =>
      old.level != level || old.phase != phase || old.color != color;
}
