/// Typed thinking-selection validation failures (Task 43 Gate D).
library;

class ThinkingSelectionException implements Exception {
  final String code;
  final String message;

  const ThinkingSelectionException({
    required this.code,
    required this.message,
  });

  @override
  String toString() => '$code: $message';
}

class ThinkingSelectionErrorCode {
  static const optionUnavailable = 'thinking_option_unavailable_for_route';
  static const capabilityUnknown = 'thinking_capability_unknown';
  static const capabilityUnsupported = 'thinking_capability_unsupported';
  static const instanceNotFound = 'thinking_route_instance_not_found';

  ThinkingSelectionErrorCode._();
}
