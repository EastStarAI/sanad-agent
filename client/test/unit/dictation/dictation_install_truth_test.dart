// Device-scoped dictation state and daemon-owned install truth.
//
// Three defects are pinned here, each one reproducible in the field:
//
// * A→B→A showed "dictation is not available on this device" for a device whose
//   model was installed, because one transport (and one model projection)
//   answered for every device.
// * Closing and reopening the model sheet lost a running download, because every
//   `stt_status` rebuilt the projection and erased the install it carried.
// * A second press met `install_in_progress`, which the cubit turned into an
//   error whose reset closed the socket — and on the local channel that
//   cancelled the real download and deleted its partial bytes.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_cubit.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_state.dart';

import '../../helpers/dictation_fakes.dart';

void main() {
  final deviceA = DeviceConfig(id: 'agent-a', name: 'Studio Mac');
  final deviceB = DeviceConfig(id: 'agent-b', name: 'Oracle');
  const hostedRow = {
    'id': 'large',
    'name': 'Whisper Large v3 Turbo',
    'size_bytes': 812000000,
    'hosted': true,
    'installed': false,
  };
  const installedRow = {
    'id': 'q8',
    'name': 'Egyptian Whisper Turbo Q8',
    'size_bytes': 874208239,
    'hosted': true,
    'installed': true,
  };

  late FakeDictationResolver resolver;
  late DictationCubit cubit;
  late DateTime now;

  setUp(() {
    resolver = FakeDictationResolver();
    now = DateTime(2026, 11, 9, 12);
    cubit = DictationCubit(
      resolver: resolver,
      capture: SilentDictationCapture(),
      sessionIdFactory: () => 'session-${resolver.resolved.length}',
      now: () => now,
      // The recovery probe waits between attempts; a test does not.
      delay: (_) async {},
    );
  });

  tearDown(() async {
    await cubit.close();
  });

  /// Lets the cubit's transport listeners run.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  group('device-scoped transport', () {
    test('A ready, then B not installed, then A ready again', () async {
      // A answers with its installed model.
      final statusA = cubit.refreshStatus(deviceA);
      await settle();
      resolver.latest('agent-a').emit(
        dictationStatusEvent(selected: 'q8', ready: true, models: [installedRow]),
      );
      await statusA;
      expect(cubit.state.model.isReady, isTrue);
      expect(resolver.resolved, ['agent-a']);

      // B is another machine: it has no model.
      final statusB = cubit.refreshStatus(deviceB);
      await settle();
      resolver.latest('agent-b').emit(
        dictationStatusEvent(selected: null, ready: false, reason: 'model_not_installed'),
      );
      await statusB;
      expect(cubit.state.model.isReady, isFalse);
      expect(cubit.state.model.blockedReason, 'model_not_installed');

      // Back to A: a fresh connection to A, and the command must reach it.
      final statusA2 = cubit.refreshStatus(deviceA);
      await settle();
      expect(
        resolver.resolved,
        ['agent-a', 'agent-b', 'agent-a'],
        reason: 'a transport never answers for two devices',
      );
      expect(resolver.resolvesFor('agent-a'), 2);
      expect(
        resolver.latest('agent-a').commandNames,
        ['status'],
        reason: "A's new transport receives A's status",
      );
      expect(
        resolver.latest('agent-b').commandNames,
        ['status'],
        reason: 'the third status must never travel to B',
      );
      resolver.latest('agent-a').emit(
        dictationStatusEvent(selected: 'q8', ready: true, models: [installedRow]),
      );
      await statusA2;

      expect(cubit.state.model.isReady, isTrue);
      expect(cubit.state.model.blockedReason, isNull);
    });
  });

  group('daemon-owned install truth', () {
    test('a status refresh keeps the running install', () async {
      final opened = cubit.refreshStatus(deviceA);
      await settle();
      final transport = resolver.latest('agent-a');
      transport.emit(
        dictationStatusEvent(
          selected: 'q8',
          ready: false,
          models: [installedRow],
          install: {
            'model_id': 'f16',
            'received_bytes': 300,
            'total_bytes': 1000,
            'phase': 'downloading',
            'bytes_per_second': 50,
          },
        ),
      );
      await opened;

      expect(cubit.state.model.installingModelId, 'f16');
      expect(cubit.state.model.downloadProgress, closeTo(0.3, 1e-9));
      expect(cubit.state.model.isDownloading, isTrue);

      // This is the refresh the sheet issues when it opens.
      final reopened = cubit.refreshStatus(deviceA);
      await settle();
      transport.emit(
        dictationStatusEvent(
          selected: 'q8',
          ready: false,
          models: [installedRow],
          install: {
            'model_id': 'f16',
            'received_bytes': 400,
            'total_bytes': 1000,
            'phase': 'downloading',
            'bytes_per_second': 50,
          },
        ),
      );
      await reopened;

      expect(
        cubit.state.model.installingModelId,
        'f16',
        reason: 'the status states the install; a refresh must not erase it',
      );
      expect(cubit.state.model.downloadProgress, closeTo(0.4, 1e-9));
    });

    test('an absent install ends the row, and the rename phase is exposed',
        () async {
      final first = cubit.refreshStatus(deviceA);
      await settle();
      final transport = resolver.latest('agent-a');
      transport.emit(
        dictationStatusEvent(
          selected: 'q8',
          ready: false,
          models: [installedRow],
          install: {
            'model_id': 'f16',
            'received_bytes': 1000,
            'total_bytes': 1000,
            'phase': 'activating',
            'bytes_per_second': 0,
          },
        ),
      );
      await first;
      expect(cubit.state.model.installingPhase, 'activating');
      expect(cubit.state.model.installEta, Duration.zero);

      final second = cubit.refreshStatus(deviceA);
      await settle();
      transport.emit(
        dictationStatusEvent(selected: 'f16', ready: true, models: [installedRow]),
      );
      await second;

      expect(cubit.state.model.installingModelId, isNull);
      expect(cubit.state.model.isDownloading, isFalse);
      expect(cubit.state.model.downloadProgress, isNull);
    });

    test('remaining time comes from the daemon rate', () async {
      final opened = cubit.refreshStatus(deviceA);
      await settle();
      resolver.latest('agent-a').emit(
        dictationStatusEvent(
          selected: 'q8',
          ready: false,
          models: [installedRow],
          install: {
            'model_id': 'f16',
            'received_bytes': 250,
            'total_bytes': 1000,
            'phase': 'downloading',
            'bytes_per_second': 125,
          },
        ),
      );
      await opened;

      expect(cubit.state.model.installEta, const Duration(seconds: 6));
    });

    test('a second press for the same model sends nothing', () async {
      final opened = cubit.refreshStatus(deviceA);
      await settle();
      final transport = resolver.latest('agent-a');
      transport.emit(
        dictationStatusEvent(
          selected: 'q8',
          ready: false,
          models: [installedRow],
          install: {
            'model_id': 'f16',
            'received_bytes': 100,
            'total_bytes': 1000,
            'phase': 'downloading',
            'bytes_per_second': 10,
          },
        ),
      );
      await opened;
      final before = transport.commands.length;

      await cubit.installModel('f16', device: deviceA);

      expect(transport.commands.length, before);
      expect(transport.closed, isFalse);
    });

    test('a terminal status clears a finished install on an open sheet',
        () async {
      // D1: the daemon used to build this status while the install was still
      // active, so it carried `install` again and the row never cleared. The
      // client's contract is the same either way: a status without `install` is
      // the end of the download, and it must land without touching the socket.
      unawaited(cubit.installModel('large', device: deviceA));
      await settle();
      final transport = resolver.latest('agent-a');
      expect(transport.commandNames, ['install']);

      transport.emit({
        'event': 'stt_download_progress',
        'model_id': 'large',
        'received_bytes': 800,
        'total_bytes': 1000,
        'phase': 'downloading',
        'bytes_per_second': 125,
      });
      await settle();
      expect(cubit.state.model.installingModelId, 'large');

      transport.emit(
        dictationStatusEvent(
          selected: null,
          ready: false,
          models: [
            {...hostedRow, 'installed': true},
          ],
        ),
      );
      await settle();

      expect(cubit.state.model.installingModelId, isNull);
      expect(cubit.state.model.isDownloading, isFalse);
      expect(cubit.state.model.downloadProgress, isNull);
      expect(
        cubit.state.model.models.single.installed,
        isTrue,
        reason: 'the same status also reports the model as installed',
      );
      expect(transport.isOpen, isTrue, reason: 'a settle is not a failure');
    });

    test('a cancelled install also ends on a status without install', () async {
      unawaited(cubit.installModel('large', device: deviceA));
      await settle();
      final transport = resolver.latest('agent-a');
      transport.emit({
        'event': 'stt_download_progress',
        'model_id': 'large',
        'received_bytes': 150,
        'total_bytes': 1000,
        'phase': 'downloading',
        'bytes_per_second': 50,
      });
      await settle();
      unawaited(cubit.cancelInstallModel(device: deviceA));
      await settle();
      expect(transport.commandNames, ['install', 'cancelInstall']);

      transport.emit(
        dictationStatusEvent(
          selected: null,
          ready: false,
          models: [hostedRow],
        ),
      );
      await settle();

      expect(cubit.state.model.installingModelId, isNull);
      expect(cubit.state.errorCode, isNull, reason: 'a cancel is not a failure');
      expect(cubit.state.model.isDownloading, isFalse);
      expect(transport.isOpen, isTrue);
    });

    test('a lost socket clears the row and re-asks the device', () async {
      // D7: after a hard Agent restart the open sheet kept a dead Cancel at 28 %,
      // because nothing told it the daemon that owned the install was gone.
      unawaited(cubit.installModel('large', device: deviceA));
      await settle();
      final first = resolver.latest('agent-a');
      expect(first.commandNames, ['install']);
      expect(cubit.state.model.installingModelId, 'large');

      // The Agent process dies: the local socket closes with no terminal event.
      await first.close();
      await settle();

      expect(
        cubit.state.model.installingModelId,
        isNull,
        reason: 'a row with no daemon behind it must not keep a Cancel button',
      );
      expect(cubit.state.errorCode, isNull, reason: 'a probe is not a failure');

      // The probe resolves a fresh socket and asks the device for truth.
      await settle();
      expect(resolver.resolvesFor('agent-a'), 2);
      final second = resolver.latest('agent-a');
      expect(second.commandNames, ['status']);

      second.emit(
        dictationStatusEvent(selected: null, ready: false, models: [hostedRow]),
      );
      await settle();
      expect(cubit.state.model.installingModelId, isNull);
      expect(second.commandNames, ['status'], reason: 'one probe, not a poll');
    });

    test('install_in_progress is state: no reset, no socket close', () async {
      await cubit.installModel('f16', device: deviceA);
      await settle();
      final transport = resolver.latest('agent-a');
      expect(transport.commandNames, ['install']);

      transport.emit({
        'event': 'dictation_error',
        'code': 'install_in_progress',
        'message': 'another model install is running',
      });
      await settle();

      expect(transport.closed, isFalse, reason: 'the socket must stay open');
      expect(cubit.state.status, DictationStatus.idle);
      // The refusal also asks the daemon for its truth, so the sheet shows the
      // install that is actually running.
      expect(transport.commandNames, ['install', 'status']);
      expect(cubit.state.errorCode, isNull);
    });

    test('a failed install keeps the transport and clears the row', () async {
      await cubit.installModel('f16', device: deviceA);
      await settle();
      final transport = resolver.latest('agent-a');

      transport.emit({
        'event': 'dictation_error',
        'code': 'storage_full',
        'message': 'not enough free disk space',
      });
      await settle();

      expect(cubit.state.model.installingModelId, isNull);
      expect(cubit.state.errorCode, 'storage_full');
      expect(transport.closed, isFalse);
    });

    test('cancel sends the explicit command and nothing else', () async {
      await cubit.installModel('f16', device: deviceA);
      await settle();
      final transport = resolver.latest('agent-a');

      await cubit.cancelInstallModel(device: deviceA);

      expect(transport.commandNames, ['install', 'cancelInstall']);
      expect(transport.closed, isFalse);
    });
  });
}
