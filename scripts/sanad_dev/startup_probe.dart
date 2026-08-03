import 'dart:async';

const sanadDevAgentStartupTimeout = Duration(minutes: 3);
const sanadDevComponentControlTimeout = Duration(minutes: 4);
const sanadDevStartupPollInterval = Duration(milliseconds: 250);

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
