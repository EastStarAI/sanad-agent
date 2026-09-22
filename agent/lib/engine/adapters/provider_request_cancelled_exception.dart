import 'dart:io';

/// Typed provider cancellation separate from network failure or watchdog timeout.
class ProviderRequestCancelledException implements IOException {
  final String operation;

  const ProviderRequestCancelledException({this.operation = 'provider_request'});

  @override
  String toString() => 'ProviderRequestCancelledException($operation)';
}
