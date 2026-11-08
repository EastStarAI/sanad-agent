import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('the standalone Dart pin matches the Dart SDK every lane runs', () {
    final pin = File(
      '../scripts/ci/dart_sdk_version.txt',
    ).readAsStringSync().trim();

    // Linux arm64 hosts install this standalone Dart SDK because the pinned
    // Flutter SDK publishes no Linux arm64 archive. Every other lane runs the
    // Dart SDK bundled with the Flutter version declared in `.fvmrc`, so the
    // pin and that bundle must never diverge: this assertion fails on the
    // normal lanes as soon as a Flutter bump changes the bundled Dart version.
    expect(pin, matches(RegExp(r'^\d+\.\d+\.\d+$')));
    expect(Platform.version, startsWith('$pin '));
  });
}
