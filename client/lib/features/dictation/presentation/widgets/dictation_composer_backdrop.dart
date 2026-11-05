/// The dictation meter as the composer's own background.
///
/// While the user speaks, the level scrolls across the whole card: the newest
/// sample enters on the right, older samples slide out on the left, and each bar
/// grows from the bottom like an equalizer. That is the shape people read as
/// "I am being recorded", and keeping it behind the text means the level is
/// visible without looking at the mic button.
///
/// Bars are drawn, not laid out: one [CustomPaint] keeps the cost flat whatever
/// the composer size is, and the ticker only runs while a session is listening —
/// an always-on ticker would repaint at 60 fps when idle and make
/// `pumpAndSettle` in widget tests spin forever.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_cubit.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_state.dart';

class DictationComposerBackdrop extends StatefulWidget {
  const DictationComposerBackdrop({super.key});

  /// Bars across the card. Enough to read as a waveform at desktop width without
  /// becoming noise on a narrow mobile composer.
  static const int barCount = 64;

  @override
  State<DictationComposerBackdrop> createState() =>
      _DictationComposerBackdropState();
}

class _DictationComposerBackdropState extends State<DictationComposerBackdrop>
    with SingleTickerProviderStateMixin {
  /// Newest sample last; the painter reads it left-to-right.
  final List<double> _samples = List<double>.filled(
    DictationComposerBackdrop.barCount,
    0,
  );

  late final Ticker _ticker = createTicker(_onTick);

  /// One bar enters every [_shiftInterval]; that is what produces the scroll.
  static const Duration _shiftInterval = Duration(milliseconds: 70);

  Duration _lastShift = Duration.zero;
  double _latest = 0;

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    if (elapsed - _lastShift < _shiftInterval) return;
    _lastShift = elapsed;
    setState(() {
      _samples.removeAt(0);
      _samples.add(_latest.clamp(0.0, 1.0));
    });
  }

  void _syncTicker(bool listening) {
    if (listening) {
      if (!_ticker.isActive) _ticker.start();
    } else if (_ticker.isActive) {
      _ticker.stop();
      _lastShift = Duration.zero;
      for (var i = 0; i < _samples.length; i++) {
        _samples[i] = 0;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return BlocConsumer<DictationCubit, DictationState>(
      listenWhen: (previous, current) =>
          previous.status != current.status ||
          previous.isActive != current.isActive ||
          previous.level != current.level,
      listener: (context, state) {
        _latest = state.level;
        _syncTicker(state.status == DictationStatus.listening);
      },
      buildWhen: (previous, current) =>
          previous.status != current.status ||
          previous.isActive != current.isActive,
      builder: (context, state) {
        final visible = state.status == DictationStatus.listening;
        if (!visible) return const SizedBox.shrink();
        return IgnorePointer(
          child: CustomPaint(
            key: const Key('dictation_level'),
            painter: _WavePainter(samples: _samples, color: colors.primary),
          ),
        );
      },
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({required this.samples, required this.color});

  final List<double> samples;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.isEmpty || size.width <= 0) return;
    final count = samples.length;
    final slot = size.width / count;
    // Rounded 4 px ticks with a real gap — the shape audio apps already use
    // (audio_play_or_record draws its bars the same way: strokeWidth = barWidth,
    // StrokeCap.round).
    final barWidth = math.min(4.0, slot * 0.55);
    final centerY = size.height / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barWidth;
    final loudest = samples.fold<double>(0, (m, s) => math.max(m, s));

    // Silence: a quiet baseline so the card does not look broken, no fake bars.
    if (loudest < 0.02) {
      paint
        ..color = color.withValues(alpha: 0.18)
        ..strokeWidth = 2;
      canvas.drawLine(
        Offset(0, centerY),
        Offset(size.width, centerY),
        paint,
      );
      return;
    }

    for (var i = 0; i < count; i++) {
      // sqrt gives quiet speech visible movement without a loud word clipping.
      final amplitude = math.sqrt(samples[i].clamp(0.0, 1.0));
      final halfHeight = math.max(1.5, amplitude * size.height / 2);
      final x = i * slot + slot / 2;
      final freshness = 0.35 + 0.65 * (i / (count - 1));
      // Low alpha keeps the text above the bars readable at any level.
      paint.color = color.withValues(alpha: 0.14 + 0.22 * freshness);
      canvas.drawLine(
        Offset(x, centerY - halfHeight),
        Offset(x, centerY + halfHeight),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter oldDelegate) =>
      oldDelegate.color != color || !_sameSamples(oldDelegate.samples, samples);

  bool _sameSamples(List<double> a, List<double> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
