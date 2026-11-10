// The wire behaviour of a daemon-scoped install, seen from a channel.
//
// Everything the Client relies on for its download surfaces is decided here:
// a repeated install joins instead of failing, a different model is refused with
// the running truth attached, progress carries the phase, and a cancelled
// install never looks like a session failure.

import 'dart:async';
import 'dart:io';

import 'package:sanad_agent/infrastructure/stt/dictation_control.dart';
import 'package:sanad_agent/infrastructure/stt/dictation_session.dart';
import 'package:sanad_agent/infrastructure/stt/dictation_status.dart';
import 'package:sanad_agent/infrastructure/stt/stt_install_control.dart';
import 'package:sanad_agent/infrastructure/stt/stt_model_store.dart';
import 'package:sanad_agent/infrastructure/stt/stt_settings.dart';
import 'package:sanad_agent/infrastructure/stt/stt_types.dart';
import 'package:test/test.dart';

/// Records the events one channel received.
class _ChannelLog {
  final List<(String, Map<String, dynamic>)> events =
      <(String, Map<String, dynamic>)>[];

  void emit(String event, Map<String, dynamic> payload) =>
      events.add((event, payload));

  List<Map<String, dynamic>> of(String name) => [
    for (final entry in events)
      if (entry.$1 == name) entry.$2,
  ];

  List<String> get names => [for (final entry in events) entry.$1];
}

/// Minimal host: the control only asks it for status and the install runner.
class _FakeHost implements DictationControlHost {
  _FakeHost({this.gate});

  final Completer<void>? gate;
  final List<String> installs = <String>[];

  /// Set by each test after the control is built, so `statusPayload` reports the
  /// control's live truth exactly as the daemon's service does.
  DictationControl? control;
  SttInstallPhase phase = SttInstallPhase.downloading;

  @override
  String get selectedModelId => 'default-model';

  @override
  Map<String, dynamic> statusPayload() {
    return {'ready': false, 'install': ?control?.installPayload};
  }

  @override
  Future<void> install(
    String modelId, {
    SttProgressCallback? onProgress,
    void Function(SttInstallPhase phase)? onPhase,
    bool Function()? isCancelled,
  }) async {
    installs.add(modelId);
    if (installs.length > 1) {
      throw StateError('a second writer must never start');
    }
    onProgress?.call(modelId, 10, 100);
    // `gate` is a Completer, not a Future: awaiting the field itself never
    // suspends.
    await (gate?.future ?? Completer<void>().future);
    onPhase?.call(SttInstallPhase.verifying);
    onProgress?.call(modelId, 100, 100);
  }

  @override
  Future<void> selectModel(String modelId) async {}

  @override
  bool prepareNativeRuntime() => false;
}

void main() {
  test('a repeated install joins and answers with the running truth', () async {
    final gate = Completer<void>();
    final host = _FakeHost(gate: gate);
    final control = DictationControl(host);
    host.control = control;
    final first = _ChannelLog();
    final second = _ChannelLog();

    final firstRun = control.handle(
      const DictationMessage(DictationCommand.install, {'model_id': 'm'}),
      owner: Object(),
      emit: first.emit,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // The second channel asks for the same model while it downloads.
    final secondRun = control.handle(
      const DictationMessage(DictationCommand.install, {'model_id': 'm'}),
      owner: Object(),
      emit: second.emit,
    );
    await secondRun;

    expect(host.installs, ['m'], reason: 'joins, never a second writer');
    // The joining channel is answered with the running truth and the status it
    // belongs to — never with `install_in_progress`.
    expect(second.names, ['stt_download_progress', 'stt_status']);
    expect(second.of('stt_download_progress').single['received_bytes'], 10);
    expect(second.of('stt_status').single['ready'], isFalse);
    expect(second.of('dictation_error'), isEmpty);

    gate.complete();
    await firstRun;

    // Both channels are told the same terminal truth: the channel that started
    // the install hears it once, the one that joined hears its join reply and
    // then the same terminal status.
    expect(first.of('stt_status'), hasLength(1));
    expect(second.of('stt_status'), hasLength(2));
    expect(second.of('stt_status').last['ready'], isFalse);
    expect(first.of('dictation_error'), isEmpty);
    expect(second.of('dictation_error'), isEmpty);
    expect(control.isInstalling, isFalse);
  });

  test('a different model is refused with the running install attached', () async {
    final gate = Completer<void>();
    final host = _FakeHost(gate: gate);
    final control = DictationControl(host);
    host.control = control;
    final first = _ChannelLog();
    final other = _ChannelLog();

    final firstRun = control.handle(
      const DictationMessage(DictationCommand.install, {'model_id': 'm'}),
      owner: Object(),
      emit: first.emit,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await control.handle(
      const DictationMessage(DictationCommand.install, {'model_id': 'other'}),
      owner: Object(),
      emit: other.emit,
    );

    expect(host.installs, ['m']);
    expect(other.of('dictation_error').single['code'], 'install_in_progress');
    // The refused channel is also told what is running, so its row is not blank.
    final status = other.of('stt_status').single;
    expect((status['install'] as Map)['model_id'], 'm');

    gate.complete();
    await firstRun;
  });

  test('progress carries the phase and the observed rate', () async {
    final gate = Completer<void>();
    final host = _FakeHost(gate: gate);
    final control = DictationControl(host);
    host.control = control;
    final log = _ChannelLog();

    final run = control.handle(
      const DictationMessage(DictationCommand.install, {'model_id': 'm'}),
      owner: Object(),
      emit: log.emit,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    gate.complete();
    await run;

    final progress = log.of('stt_download_progress');
    expect(progress, isNotEmpty);
    expect(progress.first['model_id'], 'm');
    expect(progress.first['received_bytes'], 10);
    expect(progress.first['total_bytes'], 100);
    expect(progress.first['phase'], 'downloading');
    expect(progress.first.containsKey('bytes_per_second'), isTrue);
    expect(progress.any((tick) => tick['phase'] == 'verifying'), isTrue);
    expect(progress.last['received_bytes'], 100);
  });

  test('an explicit cancel ends the install without an error event', () async {
    final gate = Completer<void>();
    final host = _FakeHost(gate: gate);
    final control = DictationControl(host);
    host.control = control;
    final log = _ChannelLog();

    final run = control.handle(
      const DictationMessage(DictationCommand.install, {'model_id': 'm'}),
      owner: Object(),
      emit: log.emit,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await control.handle(
      const DictationMessage(DictationCommand.cancelInstall, {}),
      owner: Object(),
      emit: _ChannelLog().emit,
    );
    gate.complete();
    await run;

    // A cancel is state, not failure: reporting it as `dictation_error` is what
    // used to make a Client tear down the session that must ask for status next.
    expect(log.of('dictation_error'), isEmpty);
    expect(log.names.last, 'stt_status');
    expect(control.isInstalling, isFalse);
  });

  test('the terminal status of a finished install carries no install', () async {
    final gate = Completer<void>();
    final host = _FakeHost(gate: gate);
    final control = DictationControl(host);
    host.control = control;
    final log = _ChannelLog();

    final run = control.handle(
      const DictationMessage(DictationCommand.install, {'model_id': 'm'}),
      owner: Object(),
      emit: log.emit,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // Nothing has settled yet: the row is fed by progress, and the status the
    // channel holds still states the install.
    expect(log.of('stt_status'), isEmpty);
    expect(log.names, contains('stt_download_progress'));
    expect(control.installPayload, isNotNull);

    gate.complete();
    await run;

    // This is D1: the terminal status was built while the install was still the
    // active one, so it carried `install` again — the client set the row back to
    // downloading and no further status ever cleared it.
    final terminal = log.of('stt_status').last;
    expect(terminal.containsKey('install'), isFalse);
    expect(control.installPayload, isNull);
    expect(control.isInstalling, isFalse);
  });

  test('a cancelled install ends with a status that carries no install', () async {
    final gate = Completer<void>();
    final host = _FakeHost(gate: gate);
    final control = DictationControl(host);
    host.control = control;
    final log = _ChannelLog();

    final run = control.handle(
      const DictationMessage(DictationCommand.install, {'model_id': 'm'}),
      owner: Object(),
      emit: log.emit,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await control.handle(
      const DictationMessage(DictationCommand.cancelInstall, {}),
      owner: Object(),
      emit: _ChannelLog().emit,
    );
    gate.complete();
    await run;

    // The live cancel froze at 15 % with Cancel still offered: the daemon had
    // released the install, but its last word still claimed one was running.
    expect(log.of('stt_status').last.containsKey('install'), isFalse);
    expect(log.of('dictation_error'), isEmpty);
  });

  test('a channel that arrives mid-install keeps receiving it', () async {
    // D2: a client that restarted saw one snapshot and then nothing, while the
    // daemon finished the install alone. A status request attaches the channel.
    final gate = Completer<void>();
    final host = _FakeHost(gate: gate);
    final control = DictationControl(host);
    host.control = control;
    final starter = _ChannelLog();
    final late = _ChannelLog();

    final run = control.handle(
      const DictationMessage(DictationCommand.install, {'model_id': 'm'}),
      owner: Object(),
      emit: starter.emit,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await control.handle(
      const DictationMessage(DictationCommand.status, {}),
      owner: Object(),
      emit: late.emit,
    );

    // The snapshot it asked for, plus the running install it just attached to.
    expect(late.names, ['stt_download_progress', 'stt_status']);
    expect(late.of('stt_download_progress').single['received_bytes'], 10);

    gate.complete();
    await run;

    // The end of the install reaches both channels, and only once.
    expect(late.of('stt_status'), hasLength(2));
    expect(late.of('stt_status').last.containsKey('install'), isFalse);
    expect(starter.of('stt_status').last.containsKey('install'), isFalse);
    expect(starter.of('stt_status'), hasLength(1));
  });

  test('stt_status carries the install truth and omits it when idle', () async {
    final home = Directory.systemTemp.createTempSync('stt-status-');
    addTearDown(() => home.deleteSync(recursive: true));
    final store = SttModelStore(sanadHome: home.path);

    Map<String, dynamic> payload({Map<String, dynamic>? install}) =>
        dictationStatusPayload(
          readiness: const SttReadiness.ready(),
          settings: const SttSettings(),
          store: store,
          availability: const SttEngineAvailability.build(),
          selectedModelId: 'm',
          busy: false,
          hasOverridePath: false,
          overrideReady: false,
          install: install,
        );

    expect(payload().containsKey('install'), isFalse);
    const state = SttInstallState(
      modelId: 'm',
      receivedBytes: 10,
      totalBytes: 100,
      phase: SttInstallPhase.downloading,
      bytesPerSecond: 5,
    );
    expect(payload(install: state.toWire())['install'], {
      'model_id': 'm',
      'received_bytes': 10,
      'total_bytes': 100,
      'phase': 'downloading',
      'bytes_per_second': 5,
    });
  });
}
