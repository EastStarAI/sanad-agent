import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/dictation/presentation/widgets/dictation_composer_backdrop.dart';

/// Draws the meter into an offscreen canvas and reads the pixels back, so the
/// shape can be asserted without a golden image or a running composer.
Future<ByteData> _paint(
  List<double> samples, {
  Size size = const Size(200, 80),
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  DictationMeterPainter(
    samples: samples,
    color: const Color(0xFFE91E63),
  ).paint(canvas, size);
  final image = await recorder.endRecording().toImage(
    size.width.toInt(),
    size.height.toInt(),
  );
  return (await image.toByteData())!;
}

/// Alpha of a pixel, 0 when the canvas left it untouched.
int _alphaAt(ByteData pixels, int width, int x, int y) {
  final offset = (y * width + x) * 4;
  return pixels.getUint8(offset + 3);
}

/// Highest alpha anywhere on the canvas.
int _maxAlpha(ByteData pixels) {
  var max = 0;
  for (var i = 3; i < pixels.lengthInBytes; i += 4) {
    final value = pixels.getUint8(i);
    if (value > max) max = value;
  }
  return max;
}

void main() {
  group('dictation meter painter', () {
    test('silence draws small ticks, never a flat line', () async {
      final pixels = await _paint(List<double>.filled(64, 0));
      // A tick exists at the centre of every slot...
      final centreAlpha = _alphaAt(pixels, 200, 100, 40);
      expect(centreAlpha, greaterThan(0));
      // ...and it is faint: the strip must not compete with the text above it.
      expect(centreAlpha, lessThan(90));
      // Nothing tall anywhere: silence is a row of dots, not a baseline plus dots.
      expect(_alphaAt(pixels, 200, 100, 20), 0);
      expect(_alphaAt(pixels, 200, 100, 60), 0);
    });

    test('speech grows the bars around the centre line', () async {
      final pixels = await _paint(List<double>.filled(64, 0.7));
      // The meter sits behind text, so it stays translucent (≤28% opacity).
      expect(_maxAlpha(pixels), greaterThan(55));
      expect(_maxAlpha(pixels), lessThan(110));
      expect(_alphaAt(pixels, 200, 100, 30), greaterThan(0));
      expect(_alphaAt(pixels, 200, 100, 50), greaterThan(0));
    });

    test('the newest sample on the right is the most opaque', () async {
      final samples = List<double>.filled(64, 0);
      samples[samples.length - 1] = 1;
      final pixels = await _paint(samples);
      final right = _alphaAt(pixels, 200, 197, 40);
      final left = _alphaAt(pixels, 200, 3, 40);
      expect(right, greaterThan(left));
    });

    test('repaints only when the samples or the colour change', () {
      final samples = List<double>.filled(8, 0.2);
      final painter = DictationMeterPainter(
        samples: samples,
        color: const Color(0xFFE91E63),
      );
      expect(
        painter.shouldRepaint(
          DictationMeterPainter(
            samples: List<double>.of(samples),
            color: const Color(0xFFE91E63),
          ),
        ),
        isFalse,
      );
      expect(
        painter.shouldRepaint(
          DictationMeterPainter(
            samples: List<double>.of(samples)..[3] = 0.9,
            color: const Color(0xFFE91E63),
          ),
        ),
        isTrue,
      );
    });
  });
}
