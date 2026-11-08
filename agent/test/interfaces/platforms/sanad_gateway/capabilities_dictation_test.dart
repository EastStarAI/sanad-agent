import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

/// The Gateway accepts `dictation_unavailable_reason` only beside
/// `supports_dictation: false` and only as a machine code
/// (`^[a-z][a-z0-9_]{0,63}$`). These tests pin the exact envelope so a
/// transient readiness state can never block `register_device`.
void main() {
  Map<String, dynamic> capabilitiesOf(AgentCapabilities capabilities) =>
      capabilities.toJson()['capabilities'] as Map<String, dynamic>;

  AgentCapabilities build({
    required bool supported,
    String? reason,
    Map<String, dynamic>? relay,
  }) => AgentCapabilities(
    displayName: 'Sanad Agent',
    thinkingModes: const [],
    thinkingModeSource: 'model',
    supportsDictation: supported,
    dictationUnavailableReason: reason,
    dictationRelay: relay,
  );

  test('a ready supported device advertises support without a reason', () {
    final payload = capabilitiesOf(
      build(
        supported: true,
        relay: const {'max_session_bytes': 1048576},
      ),
    );

    expect(payload['supports_dictation'], isTrue);
    expect(payload.containsKey('dictation_unavailable_reason'), isFalse);
    expect(payload['dictation_relay_v1'], isNotNull);
  });

  test('supported-but-not-ready keeps readiness off the envelope', () {
    final payload = capabilitiesOf(
      build(supported: true, reason: 'native_runtime_missing'),
    );

    expect(payload['supports_dictation'], isTrue);
    expect(
      payload.containsKey('dictation_unavailable_reason'),
      isFalse,
      reason: 'A missing model or native runtime is transient readiness, not a '
          'refused capability; registration must not fail on it.',
    );
    expect(payload['dictation_relay_v1'], isNull);
  });

  test('an unsupported platform advertises its stable refusal code', () {
    final payload = capabilitiesOf(
      build(supported: false, reason: 'unsupported_platform'),
    );

    expect(payload['supports_dictation'], isFalse);
    expect(payload['dictation_unavailable_reason'], 'unsupported_platform');
    expect(
      RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(
        payload['dictation_unavailable_reason'] as String,
      ),
      isTrue,
    );
    expect(payload['dictation_relay_v1'], isNull);
  });

  test('a non-code refusal reason is never serialized', () {
    final payload = capabilitiesOf(
      build(
        supported: false,
        reason: 'Whisper runtime is missing on this build.',
      ),
    );

    expect(payload['supports_dictation'], isFalse);
    expect(
      payload.containsKey('dictation_unavailable_reason'),
      isFalse,
      reason: 'Prose or paths must never reach the Gateway schema.',
    );
  });

  test('additive capabilities ride beside the dictation keys unchanged', () {
    final payload = capabilitiesOf(
      build(
        supported: true,
        relay: const {
          'version': 1,
          'max_session_bytes': 1048576,
          'max_session_seconds': 120,
        },
      ),
    );

    expect(payload['voice_origin_v1'], isTrue);
    expect(payload['dictation_relay_v1'], {
      'version': 1,
      'max_session_bytes': 1048576,
      'max_session_seconds': 120,
    });
    expect(payload['delivery_presence_v1'], isTrue);
  });
}
