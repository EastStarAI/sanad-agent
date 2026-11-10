/// Dictation fakes shared by the unit and widget suites.
///
/// A real `DictationCubit` needs a transport that can be driven event by event:
/// the install truth lives on `stt_status` and `stt_download_progress`, so a test
/// that mocks the cubit instead of its transport would be asserting the mock.
library;

import 'dart:async';

import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/dictation/domain/dictation_audio_capture.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport_resolver.dart';

/// One device's transport, with the commands it received.
class FakeDictationTransport implements DictationTransport {
  FakeDictationTransport(this.deviceId);

  final String deviceId;
  final StreamController<Map<String, dynamic>> controller =
      StreamController<Map<String, dynamic>>.broadcast();
  final List<(String, Map<String, dynamic>)> commands =
      <(String, Map<String, dynamic>)>[];
  bool closed = false;

  @override
  Stream<Map<String, dynamic>> get events => controller.stream;

  @override
  bool get isOpen => !closed;

  @override
  void sendCommand(String event, [Map<String, dynamic> payload = const {}]) {
    commands.add((event, payload));
  }

  @override
  void sendAudio(List<int> pcm16) {}

  @override
  Future<void> close() async {
    closed = true;
    if (!controller.isClosed) await controller.close();
  }

  void emit(Map<String, dynamic> event) {
    if (!controller.isClosed) controller.add(event);
  }

  List<String> get commandNames => [for (final entry in commands) entry.$1];
}

/// Resolves a **new** transport per call, exactly like a real socket, and keeps
/// the last one per device so a test can address the live channel.
class FakeDictationResolver implements DictationResolver {
  final Map<String, List<FakeDictationTransport>> _byDevice =
      <String, List<FakeDictationTransport>>{};
  final List<String> resolved = <String>[];

  FakeDictationTransport latest(String deviceId) => _byDevice[deviceId]!.last;

  int resolvesFor(String deviceId) => _byDevice[deviceId]?.length ?? 0;

  @override
  Future<DictationTransport> resolve({
    required DeviceConfig device,
    required String sessionId,
  }) async {
    resolved.add(device.id);
    final transport = FakeDictationTransport(device.id);
    _byDevice.putIfAbsent(device.id, () => <FakeDictationTransport>[]).add(
      transport,
    );
    return transport;
  }
}

/// A capture device that never records: these suites never start a session.
class SilentDictationCapture implements DictationCapture {
  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<List<int>>> start() async => const Stream<List<int>>.empty();

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

/// One `stt_status` frame, in the daemon's wire shape.
///
/// `install` is present exactly while a download is in flight, so omitting it is
/// how a test states "the install is over".
Map<String, dynamic> dictationStatusEvent({
  required String? selected,
  required bool ready,
  List<Map<String, dynamic>> models = const [],
  String? reason,
  Map<String, dynamic>? install,
}) => {
  'event': 'stt_status',
  'supported': true,
  'ready': ready,
  if (reason != null) 'reason': reason,
  'busy': false,
  'selected': selected,
  'models': models,
  if (install != null) 'install': install,
};
