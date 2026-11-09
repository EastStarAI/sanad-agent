import 'dart:convert';
import 'dart:developer' as developer;

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/driver/dictation_capture_fixture.dart';
import 'package:sanad_client/driver/dictation_probe.dart';
import 'package:sanad_client/driver/driver_widget_filters.dart';
import 'package:sanad_client/features/dictation/domain/dictation_audio_capture.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_cubit.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';

/// Driver-only dictation seams for real Client acceptance.
///
/// They are registered from `driver_main.dart` only and exist so an acceptance
/// run can drive the **existing** capture, resolver, transport, cubit, insertion,
/// and daemon path without a microphone. Nothing here changes production: the
/// factory still builds the real capture unless a fixture is armed for the next
/// idle session, and every response is a boolean, count, or phase — never audio,
/// transcript text, or a raw daemon message.
final DriverDictationCapture driverDictationCapture = DriverDictationCapture();

DriverDictationProbe? _probe;

/// Installs the capture seam. Must run before `AppProviders` builds the cubit.
void installDriverDictationCapture() {
  dictationCaptureFactory = () => driverDictationCapture;
}

void registerDictationDriverExtensions() {
  developer.registerExtension('ext.sanad_client.dictation_capture', (
    method,
    parameters,
  ) async {
    try {
      switch (parameters['action']) {
        case 'arm':
          final raw = parameters['pcm16le_base64'] ?? '';
          final bytes = base64Decode(raw);
          final fixture = DictationPcmFixture(
            pcm16le: bytes,
            chunkBytes:
                int.tryParse(parameters['chunk_bytes'] ?? '') ??
                DictationPcmFixture.defaultChunkBytes,
            chunkInterval: Duration(
              milliseconds:
                  int.tryParse(parameters['chunk_interval_ms'] ?? '') ??
                  DictationPcmFixture.defaultChunkInterval.inMilliseconds,
            ),
          );
          driverDictationCapture.arm(fixture);
          return _ok(_captureStatus());
        case 'disarm':
          driverDictationCapture.disarm();
          return _ok(_captureStatus());
        default:
          return _ok(_captureStatus());
      }
    } on Object catch (error) {
      return _error(_errorCode(error));
    }
  });

  developer.registerExtension('ext.sanad_client.dictation_probe', (
    method,
    parameters,
  ) async {
    final socket = getIt.isRegistered<SanadSocketService>()
        ? getIt<SanadSocketService>()
        : null;
    if (socket == null) return _error('socket_unavailable');
    final probe = _probe ??= DriverDictationProbe(
      events: socket.events,
      isConnected: () => socket.isConnected,
    );
    switch (parameters['action']) {
      case 'expect':
        probe.expect(
          deviceId: parameters['device_id'],
          dictationId: parameters['dictation_id'],
        );
        return _ok(probe.snapshot());
      case 'reset':
        probe.reset();
        return _ok(probe.snapshot());
      case 'dispose':
        probe.dispose();
        _probe = null;
        return _ok(const {'status': 'ok'});
      default:
        return _ok(probe.snapshot());
    }
  });

  developer.registerExtension('ext.sanad_client.dictation_control', (
    method,
    parameters,
  ) async {
    final element = _findKeyed(
      WidgetsBinding.instance.rootElement,
      'dictation_mic_btn',
    );
    if (element == null) return _error('composer_not_mounted');
    final cubit = Provider.of<DictationCubit>(element, listen: false);
    switch (parameters['action']) {
      case 'cancel':
        await cubit.cancel();
        return _ok({'status': 'ok', 'phase': cubit.state.status.name});
      case 'compose':
        // Composer facts only: present/chars/hash match. The text itself never
        // leaves the app, so a run cannot leak a transcript into a log.
        return _ok(
          composerFacts(
            text: cubit.state.visibleText,
            expectedSha256: parameters['expected_sha256'],
          ),
        );
      default:
        return _ok({
          'status': 'ok',
          'phase': cubit.state.status.name,
          'active': cubit.state.isActive,
        });
    }
  });
}

/// Facts a composer comparison may report: presence, length, and an exact hash
/// match. Never the text, a prefix, or a diff.
Map<String, Object?> composerFacts({required String text, String? expectedSha256}) {
  final expected = expectedSha256?.trim().toLowerCase();
  return {
    'status': 'ok',
    'present': text.isNotEmpty,
    'chars': text.runes.length,
    'matches_expected':
        expected != null &&
        expected.isNotEmpty &&
        sha256.convert(utf8.encode(text)).toString() == expected,
  };
}

Map<String, Object?> _captureStatus() {
  final fixture = driverDictationCapture.armedFixture;
  return {
    'status': 'ok',
    'armed': fixture != null,
    'active': driverDictationCapture.isSessionActive,
    if (fixture != null) ...{
      'duration_ms': fixture.duration.inMilliseconds,
      'bytes': fixture.pcm16le.length,
      'emitted_bytes': fixture.emittedBytes,
      'chunk_bytes': fixture.chunkBytes,
      'chunk_interval_ms': fixture.chunkInterval.inMilliseconds,
      'finished': fixture.isFinished,
    },
  };
}

developer.ServiceExtensionResponse _ok(Map<String, Object?> payload) =>
    developer.ServiceExtensionResponse.result(json.encode(payload));

developer.ServiceExtensionResponse _error(String code) =>
    developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.extensionError,
      json.encode({'error': code}),
    );

/// Stable codes only: a bad parameter shape must never echo caller bytes.
String _errorCode(Object error) {
  if (error is ArgumentError) return 'invalid_fixture';
  if (error is StateError) return 'session_active';
  if (error is FormatException) return 'invalid_base64';
  return 'capture_unavailable';
}

/// Key lookup over the whole tree, using the inspector's own traversal.
///
/// The bounded variant stopped at 4000 elements, which any Home with
/// conversation history exceeds, so every control call answered
/// `composer_not_mounted` even though the composer was mounted.
Element? _findKeyed(Element? root, String key) =>
    root == null ? null : findElementByKey(root, key);
