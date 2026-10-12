import 'dart:async';

const sanadDevAgentStartupTimeout = Duration(minutes: 3);
const sanadDevClientStartupTimeout = Duration(minutes: 5);
const sanadDevComponentControlTimeout = Duration(minutes: 6);
const sanadDevStartupPollInterval = Duration(milliseconds: 250);

bool matchesSanadDevAgentHealth(
  Object? decoded, {
  required String launcherId,
  required String runtimeNonce,
}) {
  return decoded is Map &&
      decoded['status'] == 'ok' &&
      decoded['dev_launcher_id'] == launcherId &&
      decoded['dev_runtime_nonce'] == runtimeNonce;
}

Future<bool> waitForSanadDevStartupProbe({
  required Future<bool> Function() probe,
  Duration timeout = sanadDevAgentStartupTimeout,
  Duration pollInterval = sanadDevStartupPollInterval,
  DateTime Function()? clock,
  Future<void> Function(Duration)? delay,
}) async {
  final now = clock ?? DateTime.now;
  final pause = delay ?? Future<void>.delayed;
  final deadline = now().add(timeout);

  while (true) {
    if (await probe()) return true;
    if (!now().isBefore(deadline)) return false;
    await pause(pollInterval);
  }
}
