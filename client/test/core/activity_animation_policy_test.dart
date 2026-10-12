import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/theme/activity_animation_policy.dart';

void main() {
  group('ActivityAnimationPolicy', () {
    test('withContinuousActivityAnimationOverride overrides policy value', () {
      ActivityAnimationPolicy.withContinuousActivityAnimationOverride(true, () {
        expect(ActivityAnimationPolicy.allowContinuousActivityAnimation, isTrue);
      });

      ActivityAnimationPolicy.withContinuousActivityAnimationOverride(false, () {
        expect(ActivityAnimationPolicy.allowContinuousActivityAnimation, isFalse);
      });
    });

    test('resets override after callback finishes', () {
      final initial = ActivityAnimationPolicy.allowContinuousActivityAnimation;
      ActivityAnimationPolicy.withContinuousActivityAnimationOverride(!initial, () {
        expect(ActivityAnimationPolicy.allowContinuousActivityAnimation, equals(!initial));
      });
      expect(ActivityAnimationPolicy.allowContinuousActivityAnimation, equals(initial));
    });
  });
}
