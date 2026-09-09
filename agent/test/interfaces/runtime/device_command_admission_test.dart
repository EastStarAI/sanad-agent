import 'package:sanad_agent/interfaces/models/device_control.dart';
import 'package:sanad_agent/interfaces/runtime/device_command_admission.dart';
import 'package:test/test.dart';

void main() {
  late DateTime now;
  late DeviceCommandAdmission admission;

  setUp(() {
    now = DateTime.utc(2026, 8, 30, 1);
    admission = DeviceCommandAdmission(
      registeredDeviceId: () => 'device-a',
      clock: () => now,
    );
  });

  test('admits a matching update check', () {
    final decision = admission.admit(
      command: DeviceControlCommands.updateCheck,
      envelopeDeviceId: 'device-a',
      requestId: 'req-1',
    );
    expect(decision.allowed, isTrue);
  });

  test('admits a trusted local hardware identity without weakening others', () {
    final localAdmission = DeviceCommandAdmission(
      registeredDeviceId: () => 'cloud-device',
      additionalDeviceIds: () => const ['local-hardware'],
    );

    expect(
      localAdmission
          .admit(
            command: DeviceControlCommands.runtimeRestart,
            envelopeDeviceId: 'local-hardware',
            requestId: 'req-local',
          )
          .allowed,
      isTrue,
    );
    expect(
      localAdmission
          .admit(
            command: DeviceControlCommands.runtimeRestart,
            envelopeDeviceId: 'untrusted-device',
            requestId: 'req-other',
          )
          .code,
      DeviceControlErrorCodes.wrongDevice,
    );
  });

  test('deduplicates one request across cloud and local identities', () {
    final localAdmission = DeviceCommandAdmission(
      registeredDeviceId: () => 'cloud-device',
      additionalDeviceIds: () => const ['local-hardware'],
    );

    expect(
      localAdmission
          .admit(
            command: DeviceControlCommands.updateCheck,
            envelopeDeviceId: 'cloud-device',
            requestId: 'req-shared',
          )
          .allowed,
      isTrue,
    );
    expect(
      localAdmission
          .admit(
            command: DeviceControlCommands.updateCheck,
            envelopeDeviceId: 'local-hardware',
            requestId: 'req-shared',
          )
          .code,
      DeviceControlErrorCodes.duplicateRequest,
    );
  });

  test('rejects a different device without recording the request', () {
    final decision = admission.admit(
      command: DeviceControlCommands.updateCheck,
      envelopeDeviceId: 'device-b',
      requestId: 'req-1',
    );
    expect(decision.code, DeviceControlErrorCodes.wrongDevice);

    final retry = admission.admit(
      command: DeviceControlCommands.updateCheck,
      envelopeDeviceId: 'device-a',
      requestId: 'req-1',
    );
    expect(retry.allowed, isTrue);
  });

  test('rejects missing request_id', () {
    final decision = admission.admit(
      command: DeviceControlCommands.updateCheck,
      envelopeDeviceId: 'device-a',
      requestId: '  ',
    );
    expect(decision.code, DeviceControlErrorCodes.invalidRequest);
  });

  test('rejects a missing device_id on a registered cloud connection', () {
    final decision = admission.admit(
      command: DeviceControlCommands.updateCheck,
      envelopeDeviceId: '  ',
      requestId: 'req-missing-device',
    );
    expect(decision.code, DeviceControlErrorCodes.invalidRequest);
    expect(decision.message, 'device_id is required.');
  });

  test('rejects an unknown device-control command', () {
    final decision = admission.admit(
      command: 'device.unknown.command',
      envelopeDeviceId: 'device-a',
      requestId: 'req-unknown',
    );
    expect(decision.code, DeviceControlErrorCodes.unsupported);
  });

  test('rejects a duplicate request_id after admission', () {
    expect(
      admission
          .admit(
            command: DeviceControlCommands.updateCheck,
            envelopeDeviceId: 'device-a',
            requestId: 'req-dup',
          )
          .allowed,
      isTrue,
    );
    final duplicate = admission.admit(
      command: DeviceControlCommands.updateCheck,
      envelopeDeviceId: 'device-a',
      requestId: 'req-dup',
    );
    expect(duplicate.code, DeviceControlErrorCodes.duplicateRequest);
  });

  test('rejects apply without a confirmation ticket', () {
    final decision = admission.admit(
      command: DeviceControlCommands.updateApply,
      envelopeDeviceId: 'device-a',
      requestId: 'req-apply',
    );
    expect(decision.code, DeviceControlErrorCodes.confirmationRequired);
  });

  test('rejects a stale or mismatched confirmation ticket', () {
    final ticket = admission.issueConfirmation(
      deviceId: 'device-a',
      operation: DeviceControlCommands.updateApply,
      fingerprint: 'manifest-1',
    );
    now = now.add(const Duration(minutes: 3));
    final stale = admission.admit(
      command: DeviceControlCommands.updateApply,
      envelopeDeviceId: 'device-a',
      requestId: 'req-stale',
      confirmationToken: ticket.token,
      confirmationFingerprint: 'manifest-1',
    );
    expect(stale.code, DeviceControlErrorCodes.staleConfirmation);

    now = DateTime.utc(2026, 8, 30, 1);
    final fresh = admission.issueConfirmation(
      deviceId: 'device-a',
      operation: DeviceControlCommands.updateApply,
      fingerprint: 'manifest-1',
    );
    final wrongFingerprint = admission.admit(
      command: DeviceControlCommands.updateApply,
      envelopeDeviceId: 'device-a',
      requestId: 'req-fingerprint',
      confirmationToken: fresh.token,
      confirmationFingerprint: 'manifest-other',
    );
    expect(wrongFingerprint.code, DeviceControlErrorCodes.staleConfirmation);
  });

  test('consumes a matching confirmation ticket once', () {
    final ticket = admission.issueConfirmation(
      deviceId: 'device-a',
      operation: DeviceControlCommands.updateApply,
      fingerprint: 'manifest-1',
    );
    expect(
      admission
          .admit(
            command: DeviceControlCommands.updateApply,
            envelopeDeviceId: 'device-a',
            requestId: 'req-apply-ok',
            confirmationToken: ticket.token,
            confirmationFingerprint: 'manifest-1',
          )
          .allowed,
      isTrue,
    );
    final reused = admission.admit(
      command: DeviceControlCommands.updateApply,
      envelopeDeviceId: 'device-a',
      requestId: 'req-apply-reuse',
      confirmationToken: ticket.token,
      confirmationFingerprint: 'manifest-1',
    );
    expect(reused.code, DeviceControlErrorCodes.staleConfirmation);
  });

  test('admits explicit force restart and rejects invalid restart fields', () {
    expect(
      admission
          .admit(
            command: DeviceControlCommands.runtimeRestart,
            envelopeDeviceId: 'device-a',
            requestId: 'req-force',
            payload: const {'force': true},
          )
          .allowed,
      isTrue,
    );
    expect(
      admission
          .admit(
            command: DeviceControlCommands.runtimeRestart,
            envelopeDeviceId: 'device-a',
            requestId: 'req-force-invalid',
            payload: const {'force': 'true'},
          )
          .code,
      DeviceControlErrorCodes.invalidRequest,
    );
    expect(
      admission
          .admit(
            command: DeviceControlCommands.runtimeRestart,
            envelopeDeviceId: 'device-a',
            requestId: 'req-timeout-high',
            payload: const {'timeout_seconds': 3601},
          )
          .code,
      DeviceControlErrorCodes.invalidRequest,
    );
  });

  test('restart parser preserves the explicit force choice', () {
    final request = DeviceRuntimeRestartRequest.parse(
      deviceId: 'device-a',
      payload: const {'request_id': 'req-force-parse', 'force': true},
    );

    expect(request.force, isTrue);
  });

  test('apply parser rejects client artifact URLs', () {
    expect(
      () => DeviceUpdateApplyRequest.parse(
        deviceId: 'device-a',
        payload: {
          'request_id': 'req-url',
          'target_version': '1.2.3',
          'manifest_revision': 'rev-1',
          'manifest_fingerprint': 'fp-1',
          'url': 'https://evil.example/agent',
        },
      ),
      throwsFormatException,
    );
  });
}
