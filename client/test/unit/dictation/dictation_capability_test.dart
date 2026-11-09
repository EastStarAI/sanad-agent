import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';

/// The dictation/voice advertisements are additive capability keys: an older
/// Agent omits them, a newer one declares object payloads. Parsing must stay
/// forward-compatible in both directions and never invent a relay from a
/// malformed value.
void main() {
  group('dictation relay capability', () {
    test('a well-formed v1 block enables the relay', () {
      final capability = Capability.fromJson({
        'supports_dictation': true,
        'dictation_relay_v1': {'version': 1, 'max_frame_bytes': 16384},
        'voice_origin_v1': true,
      });

      expect(capability.supportsDictation, isTrue);
      expect(capability.supportsDictationRelay, isTrue);
      expect(capability.dictationRelayVersion, Capability.dictationRelayVersion1);
      expect(capability.dictationRelayMaxFrameBytes, 16384);
      expect(capability.supportsVoiceOrigin, isTrue);
    });

    test('a string version still parses as v1', () {
      final capability = Capability.fromJson({
        'supports_dictation': true,
        'dictation_relay_v1': {'version': '1'},
      });

      expect(capability.supportsDictationRelay, isTrue);
    });

    test('the declared frame bound is clamped to the contract maximum', () {
      final over = Capability.fromJson({
        'supports_dictation': true,
        'dictation_relay_v1': {
          'version': 1,
          'max_frame_bytes': Capability.dictationRelayContractMaxFrameBytes * 4,
        },
      });
      final under = Capability.fromJson({
        'supports_dictation': true,
        'dictation_relay_v1': {'version': 1, 'max_frame_bytes': 1024},
      });
      final missing = Capability.fromJson({
        'supports_dictation': true,
        'dictation_relay_v1': {'version': 1},
      });

      expect(
        over.dictationRelayMaxFrameBytes,
        Capability.dictationRelayContractMaxFrameBytes,
      );
      expect(under.dictationRelayMaxFrameBytes, 1024);
      expect(
        missing.dictationRelayMaxFrameBytes,
        Capability.dictationRelayContractMaxFrameBytes,
      );
    });

    test('an older Agent that omits every key stays local-only', () {
      final capability = Capability.fromJson({'supports_dictation': true});

      expect(capability.supportsDictation, isTrue);
      expect(capability.supportsDictationRelay, isFalse);
      expect(capability.supportsVoiceOrigin, isFalse);
      expect(capability.dictationRelayVersion, isNull);
    });

    test('the declared session bounds are parsed and clamped', () {
      final declared = Capability.fromJson({
        'supports_dictation': true,
        'dictation_relay_v1': {
          'version': 1,
          'max_session_bytes': 64000,
          'max_session_seconds': 30,
        },
      });
      final oversized = Capability.fromJson({
        'supports_dictation': true,
        'dictation_relay_v1': {
          'version': 1,
          'max_session_bytes':
              Capability.dictationRelayContractMaxSessionBytes * 2,
          'max_session_seconds': 9999,
        },
      });

      expect(declared.dictationRelayMaxSessionBytes, 64000);
      expect(declared.dictationRelayMaxSessionSeconds, 30);
      expect(
        oversized.dictationRelayMaxSessionBytes,
        Capability.dictationRelayContractMaxSessionBytes,
      );
      expect(
        oversized.dictationRelayMaxSessionSeconds,
        Capability.dictationRelayContractMaxSessionSeconds,
      );
    });

    test('invalid session bound types fall back to the contract defaults', () {
      for (final raw in <dynamic>[
        {'version': 1, 'max_session_bytes': -1, 'max_session_seconds': 0},
        {
          'version': 1,
          'max_session_bytes': '64000',
          'max_session_seconds': '30',
        },
        {'version': 1, 'max_session_bytes': 1.5, 'max_session_seconds': true},
      ]) {
        final capability = Capability.fromJson({
          'supports_dictation': true,
          'dictation_relay_v1': raw,
        });

        expect(
          capability.dictationRelayMaxSessionBytes,
          Capability.dictationRelayContractMaxSessionBytes,
          reason: 'raw=$raw',
        );
        expect(
          capability.dictationRelayMaxSessionSeconds,
          Capability.dictationRelayContractMaxSessionSeconds,
          reason: 'raw=$raw',
        );
      }
    });

    test('malformed blocks never enable the relay', () {
      for (final raw in <dynamic>[
        {'version': 2},
        {'version': 'two'},
        {'max_frame_bytes': 8192},
        'v1',
        true,
        <dynamic>[],
      ]) {
        final capability = Capability.fromJson({
          'supports_dictation': true,
          'dictation_relay_v1': raw,
        });

        expect(
          capability.supportsDictationRelay,
          isFalse,
          reason: 'raw=$raw must not be read as a relay contract',
        );
      }
    });

    test('a relay block cannot enable dictation on its own', () {
      final capability = Capability.fromJson({
        'dictation_relay_v1': {'version': 1},
      });

      expect(capability.supportsDictation, isFalse);
      expect(capability.supportsDictationRelay, isFalse);
    });

    test('the unavailability reason round-trips verbatim', () {
      final capability = Capability.fromJson({
        'supports_dictation': false,
        'dictation_unavailable_reason': 'native_runtime_missing',
      });

      expect(capability.dictationUnavailableReason, 'native_runtime_missing');
    });

    test('voice origin only accepts an explicit true', () {
      expect(
        Capability.fromJson({'voice_origin_v1': 'true'}).supportsVoiceOrigin,
        isFalse,
      );
      expect(
        Capability.fromJson({'voice_origin_v1': 1}).supportsVoiceOrigin,
        isFalse,
      );
    });
  });
}
