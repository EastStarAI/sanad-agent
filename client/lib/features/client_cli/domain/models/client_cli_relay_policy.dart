/// Caller-side relay policy for `sanad-client`.
///
/// One owner for the two decisions the caller must make before it forwards a
/// command to the remote Agent:
///
/// * the relay execution window (`timeout_seconds`) — the caller's window must
///   outlive the forwarded command's own `--timeout`, otherwise the relay kills
///   a run that is still within its negotiated runtime;
/// * whether piped standard input is forwarded at all — a background caller
///   often owns a non-TTY standard input that never reaches EOF, so reading it
///   for a command that does not consume standard input would block forever.
///
/// Protocol: `docs/technical/remote_cli_relay_protocol.md`.
library;

/// Default relay execution window when the forwarded command declares no
/// `--timeout` (protocol §6.2).
const int clientCliRelayDefaultTimeoutSeconds = 300;

/// Lower protocol bound for `timeout_seconds` (protocol §6.2).
const int clientCliRelayMinTimeoutSeconds = 1;

/// Upper protocol bound for `timeout_seconds` (protocol §6.2).
const int clientCliRelayMaxTimeoutSeconds = 86400;

/// Extra seconds the relay window keeps beyond the command's own `--timeout`
/// so the command's scoped stop, artifact write, and terminal result happen
/// before the relay window closes.
const int clientCliRelayTimeoutGraceSeconds = 30;

/// Host-local caller flag that forces forwarding piped standard input even for
/// a command shape that would not consume it. Never forwarded to the Agent.
const String clientCliForwardStdinFlag = '--stdin';

/// Host-to-caller status frame emitted while a Default-mode approval is
/// pending, so a headless caller can explain the wait on standard error.
const String clientCliApprovalPendingStatus = 'approval_pending';

/// Caller diagnostic printed on standard error while the approval is pending.
const String clientCliApprovalPendingMessage =
    'Waiting for approval in Sanad Client...';

/// Commands whose remote form reads standard input when it carries the prompt.
const Set<String> _clientCliStdinCommands = {'run', 'chat', 'cli'};

/// Options that consume the following argv token as their value.
const Set<String> _clientCliValueOptions = {
  '--workspace',
  '-w',
  '--session',
  '-s',
  '--model',
  '-m',
  '--provider',
  '--thinking-mode',
  '--timeout',
  '--account',
  '--home',
  '--gateway-url',
  '--url',
  '--prompt',
  '-p',
  '--brief-file',
  '-b',
  '--execution-root',
  '--out-dir',
  '-o',
};

/// Relay execution window in seconds for [argv].
///
/// The forwarded command's own `--timeout` (1..86400, last occurrence wins)
/// plus a small grace becomes the relay window. Without a usable `--timeout`
/// the protocol default stays in force, and the result is always clamped to the
/// protocol bounds so an out-of-range value cannot widen the relay.
int clientCliRelayTimeoutSecondsFor(List<String> argv) {
  int? requestedSeconds;
  for (var i = 0; i < argv.length; i++) {
    final token = argv[i];
    if (token == '--') break;
    if (token == '--timeout') {
      requestedSeconds = i + 1 < argv.length
          ? int.tryParse(argv[i + 1].trim())
          : null;
    } else if (token.startsWith('--timeout=')) {
      requestedSeconds = int.tryParse(
        token.substring('--timeout='.length).trim(),
      );
    }
  }

  if (requestedSeconds == null) return clientCliRelayDefaultTimeoutSeconds;

  final window = requestedSeconds + clientCliRelayTimeoutGraceSeconds;
  if (window < clientCliRelayMinTimeoutSeconds) {
    return clientCliRelayMinTimeoutSeconds;
  }
  if (window > clientCliRelayMaxTimeoutSeconds) {
    return clientCliRelayMaxTimeoutSeconds;
  }
  return window;
}

/// Whether [argv] forwards a command that reads its prompt from standard input.
///
/// A command that already carries its prompt — `--brief-file`, `--prompt`, or a
/// positional prompt — never reads standard input, so the caller must not wait
/// for EOF before it forwards anything.
bool clientCliRelayConsumesStdin(List<String> argv) {
  if (argv.isEmpty) return false;
  if (!_clientCliStdinCommands.contains(argv.first)) return false;

  for (var i = 1; i < argv.length; i++) {
    final token = argv[i];
    if (token == '--') return false;
    if (token.startsWith('-') && token.length > 1) {
      final name = token.contains('=')
          ? token.substring(0, token.indexOf('='))
          : token;
      if (name == '--brief-file' || name == '-b') return false;
      if (name == '--prompt' || name == '-p') return false;
      if (!token.contains('=') && _clientCliValueOptions.contains(name)) {
        i++;
      }
      continue;
    }
    // A positional prompt is supplied, so standard input is not the prompt.
    return false;
  }
  return true;
}

/// Whether the caller asked to forward piped standard input explicitly.
bool clientCliHasForwardStdinFlag(List<String> argv) =>
    argv.contains(clientCliForwardStdinFlag);
