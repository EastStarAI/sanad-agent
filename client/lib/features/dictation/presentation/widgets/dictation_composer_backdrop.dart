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
import 'package:logging/logging.dart';
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

class _DictationComposerBackdropState extends State<DictationComposerBackdrop> {
  /// Diagnostics, summary only: per-frame logging would flood the log during a
  /// normal sentence, so the session reports its totals when it stops and a
  /// single line when visibility flips.
  static final _logger = Logger('DictationMeter');
  int _shiftCount = 0;
  double _maxSample = 0;

  /// Newest sample last; the painter reads it left-to-right.
  ///
  /// Held in a notifier instead of State fields because the cubit emits while
  /// the composer is building, and a `setState` from that listener throws
  /// "setState() called during build" and is dropped — which is exactly how the
  /// meter stayed empty. A notifier can be written at any phase.
  final ValueNotifier<List<double>> _samples = ValueNotifier<List<double>>(
    List<double>.filled(DictationComposerBackdrop.barCount, 0),
  );

  /// The daemon streams the level many times per second, and every event moves
  /// the meter by one bar. A Ticker used to drive this, but it never fired a
  /// single tick in the desktop runtime even while reported active and unmuted,
  /// which left the meter frozen at zero; the level events are the real clock.
  static const Duration _minShift = Duration(milliseconds: 40);
  DateTime? _lastShiftAt;
  bool _lastVisible = false;

  @override
  void dispose() {
    _samples.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Proves the log pipeline is live before anyone speaks: a missing mount line
    // means the widget is not built at all, not that the bars are invisible.
    _logger.info('meter mounted');
  }

  /// Shifts one bar per level event, dropping bursts that arrive closer than
  /// [_minShift] so a chatty stream cannot scroll the history away instantly.
  void _pushLevel(double level) {
    final now = DateTime.now();
    final last = _lastShiftAt;
    if (last != null && now.difference(last) < _minShift) return;
    _lastShiftAt = now;
    final next = List<double>.of(_samples.value)..removeAt(0);
    next.add(level.clamp(0.0, 1.0));
    _deliver(next);
    _shiftCount++;
    if (level > _maxSample) _maxSample = level;
  }

  void _resetSamples() {
    if (_shiftCount > 0) {
      _logger.info(
        'meter session: shifts=$_shiftCount max=${_maxSample.toStringAsFixed(3)}',
      );
    }
    _lastShiftAt = null;
    _shiftCount = 0;
    _maxSample = 0;
    _deliver(List<double>.filled(DictationComposerBackdrop.barCount, 0));
  }

  /// Delivers a new frame of samples.
  ///
  /// The cubit emits from inside the composer's build, and notifying a
  /// [ValueListenableBuilder] there calls `setState` during build — the exact
  /// throw that kept this meter blank. During build/layout the frame is
  /// deferred to the end of the frame instead.
  void _deliver(List<double> next) {
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _samples.value = next;
      });
      return;
    }
    _samples.value = next;
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
        final listening = state.status == DictationStatus.listening;
        if (listening) {
          _pushLevel(state.level);
        } else if (_lastShiftAt != null) {
          _resetSamples();
        }
      },
      buildWhen: (previous, current) =>
          previous.status != current.status ||
          previous.isActive != current.isActive,
      builder: (context, state) {
        final visible = state.status == DictationStatus.listening;
        if (visible != _lastVisible) {
          _lastVisible = visible;
          // A disabled TickerMode silences the ticker without any error, so it
          // is logged next to visibility: muted ticks look exactly like a broken
          // meter.
          _logger.info(
            'meter visible=$visible tickerMode=${TickerMode.valuesOf(context).enabled}',
          );
        }
        if (!visible) return const SizedBox.shrink();
        return IgnorePointer(
          child: ValueListenableBuilder<List<double>>(
            valueListenable: _samples,
            builder: (context, samples, _) => CustomPaint(
              key: const Key('dictation_composer_meter'),
              painter: DictationMeterPainter(
                samples: samples,
                color: colors.primary,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Paints the rolling meter. Public so a unit test can draw it into an offscreen
/// canvas and assert pixels without booting a whole composer.
class DictationMeterPainter extends CustomPainter {
  DictationMeterPainter({required this.samples, required this.color});

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
        ..color = color.withValues(alpha: 0.22)
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
      final halfHeight = math.max(2.0, amplitude * size.height * 0.45);
      final x = i * slot + slot / 2;
      final freshness = 0.35 + 0.65 * (i / (count - 1));
      // Low alpha keeps the text above the bars readable at any level.
      paint.color = color.withValues(alpha: 0.20 + 0.26 * freshness);
      canvas.drawLine(
        Offset(x, centerY - halfHeight),
        Offset(x, centerY + halfHeight),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(DictationMeterPainter oldDelegate) =>
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
