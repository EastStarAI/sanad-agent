import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../../scripts/sanad_dev/runtime_component_control.dart';

void main() {
  test('component control request round-trips all selectors', () async {
    final directory = await Directory.systemTemp.createTemp(
      'sanad-component-control-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final path = runtimeComponentControlPath(directory.path, 58091);
    final request = RuntimeComponentControlRequest(
      requestId: 'request-1',
      launcherId: 'launcher-1',
      runtimeNonce: 'nonce-1',
      action: RuntimeComponentAction.stop,
      target: RuntimeComponentTarget.client,
      status: 'requested',
      requestedAt: DateTime.utc(2026, 7, 30),
      deviceId: 'macos',
      clientPid: 42,
      vmServicePort: 51042,
    );

    await writeRuntimeComponentControl(path, request);
    final restored = await readRuntimeComponentControl(path);

    expect(restored?.requestId, 'request-1');
    expect(restored?.action, RuntimeComponentAction.stop);
    expect(restored?.target, RuntimeComponentTarget.client);
    expect(restored?.deviceId, 'macos');
    expect(restored?.clientPid, 42);
    expect(restored?.vmServicePort, 51042);
    expect(restored?.openClientTerminal, isTrue);
    expect(restored?.isTerminal, isFalse);
  });

  test('client developer action can retain the invoking terminal', () {
    final request = RuntimeComponentControlRequest(
      requestId: 'request-keys',
      launcherId: 'launcher-1',
      runtimeNonce: 'nonce-1',
      action: RuntimeComponentAction.restart,
      target: RuntimeComponentTarget.client,
      status: 'requested',
      requestedAt: DateTime.utc(2026, 8, 2),
      vmServicePort: 51042,
      openClientTerminal: false,
    );

    final restored = RuntimeComponentControlRequest.fromJson(request.toJson());

    expect(restored.action, RuntimeComponentAction.restart);
    expect(restored.openClientTerminal, isFalse);
  });

  test('all Flutter interactive keys map to explicit Client actions', () {
    const expected = {
      'r': RuntimeComponentAction.reload,
      'R': RuntimeComponentAction.restart,
      'h': RuntimeComponentAction.help,
      'd': RuntimeComponentAction.detach,
      'c': RuntimeComponentAction.clear,
      'q': RuntimeComponentAction.quit,
    };

    for (final entry in expected.entries) {
      expect(runtimeClientActionForInteractiveKey(entry.key), entry.value);
      expect(runtimeClientInteractiveKeyForAction(entry.value), entry.key);
    }
    expect(runtimeClientActionForInteractiveKey('s'), isNull);
    expect(runtimeClientInteractiveKeyForAction(RuntimeComponentAction.stop), isNull);
  });

  test('Agent interactive keys distinguish restart and safe stop controls', () {
    for (final key in const ['r', 'R', 's', 'q']) {
      expect(isRuntimeAgentInteractiveKey(key), isTrue);
    }
    expect(isRuntimeAgentInteractiveKey('d'), isFalse);
  });

  test('terminal result preserves request identity', () {
    final request = RuntimeComponentControlRequest(
      requestId: 'request-1',
      launcherId: 'launcher-1',
      runtimeNonce: 'nonce-1',
      action: RuntimeComponentAction.start,
      target: RuntimeComponentTarget.agent,
      status: 'requested',
      requestedAt: DateTime.utc(2026, 7, 30),
    );

    final completed = request.copyWith(
      status: 'complete',
      message: 'agent start complete',
    );

    expect(completed.isTerminal, isTrue);
    expect(completed.requestId, request.requestId);
    expect(completed.launcherId, request.launcherId);
    expect(completed.message, 'agent start complete');
  });

  test('invalid action fails closed', () {
    expect(
      () => RuntimeComponentControlRequest.fromJson({
        'version': runtimeComponentControlVersion,
        'request_id': 'request-1',
        'launcher_id': 'launcher-1',
        'runtime_nonce': 'nonce-1',
        'action': 'kill',
        'target': 'agent',
        'status': 'requested',
        'requested_at': DateTime.utc(2026, 7, 30).toIso8601String(),
      }),
      throwsFormatException,
    );
  });
}
