import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';

/// Single semantic policy owner for activity indicators and continuous motion.
///
/// On Windows, continuous animations such as spinning progress indicators or
/// repeating pulsing glows trigger heavy raster repaints (driving GPU to ~100%
/// and spiking CPU). Therefore, on Windows the policy defaults to static (false).
/// On other platforms (macOS, Linux, Android, iOS, Web), continuous animation is permitted.
class ActivityAnimationPolicy {
  ActivityAnimationPolicy._();

  static bool? _overrideAllowContinuous;

  /// Sets an explicit override for testing or fixture validation regardless of host OS.
  @visibleForTesting
  static void setOverride({bool? allowContinuous}) {
    _overrideAllowContinuous = allowContinuous;
  }

  /// Resets any previously configured test override.
  @visibleForTesting
  static void resetOverride() {
    _overrideAllowContinuous = null;
  }

  /// Runs [action] with [allowContinuous] temporarily forced, restoring the previous
  /// setting upon completion.
  @visibleForTesting
  static R withContinuousActivityAnimationOverride<R>(bool allowContinuous, R Function() action) {
    final previous = _overrideAllowContinuous;
    _overrideAllowContinuous = allowContinuous;
    try {
      return action();
    } finally {
      _overrideAllowContinuous = previous;
    }
  }

  /// Runs async [action] with [allowContinuous] temporarily forced, restoring the previous
  /// setting upon completion.
  @visibleForTesting
  static Future<R> withContinuousActivityAnimationOverrideAsync<R>(
    bool allowContinuous,
    Future<R> Function() action,
  ) async {
    final previous = _overrideAllowContinuous;
    _overrideAllowContinuous = allowContinuous;
    try {
      return await action();
    } finally {
      _overrideAllowContinuous = previous;
    }
  }

  /// Returns `true` if continuous activity animations are permitted on the active runtime.
  static bool get allowContinuousActivityAnimation {
    if (_overrideAllowContinuous != null) {
      return _overrideAllowContinuous!;
    }
    if (kIsWeb) return true;
    try {
      if (Platform.isWindows) {
        return false;
      }
    } catch (_) {
      // In web or non-dart:io environments, fallback to true.
    }
    return true;
  }
}
