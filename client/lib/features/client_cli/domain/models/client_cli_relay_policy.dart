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

/// Long options that consume a value, using the Agent CLI's own grammar.
///
/// This is the whole `SanadCommandRunner` surface, not just the options this
/// policy acts on: every value option must consume its value so a value that
/// looks like an option (for example `--message -s`) is never re-read as a
/// session flag.
const Set<String> _clientCliLongValueOptions = {
  'account',
  'answer',
  'brief-file',
  'comment',
  'decision',
  'execution-root',
  'expected-version',
  'file',
  'gateway-url',
  // Registered alias of `--gateway-url`.
  'url',
  'health-timeout',
  'home',
  'max-entries',
  'message',
  'message-file',
  'model',
  'name',
  'out-dir',
  'path',
  'prompt',
  'provider',
  'ref',
  'request-id',
  'scope',
  'session',
  'skill',
  'sub-path',
  'thinking-mode',
  'timeout',
  'workspace',
};

/// Short options and whether each one consumes a value (`args` abbreviations).
const Map<String, bool> _clientCliShortOptions = {
  'a': true, // --answer
  'b': true, // --brief-file
  'c': true, // --comment
  'd': true, // --decision
  'f': true, // --message-file / --file
  'm': true, // --model
  'n': true, // --name
  'o': true, // --out-dir
  'p': true, // --prompt
  'q': false, // --quiet
  'r': true, // --request-id
  's': true, // --session
  'v': false, // --version
  'w': true, // --workspace
};

/// Long name of each short option, so both forms resolve identically.
const Map<String, String> _clientCliShortNames = {
  'a': 'answer',
  'b': 'brief-file',
  'c': 'comment',
  'd': 'decision',
  'f': 'message-file',
  'm': 'model',
  'n': 'name',
  'o': 'out-dir',
  'p': 'prompt',
  'q': 'quiet',
  'r': 'request-id',
  's': 'session',
  'v': 'version',
  'w': 'workspace',
};

/// `session` subcommands that carry no positional session id.
const Set<String> _clientCliSessionlessSubcommands = {'list', 'new'};

/// Session target named by a relayed argv, resolved with the Agent's grammar.
class ClientCliSessionTarget {
  const ClientCliSessionTarget({this.sessionId, this.conflict = false});

  /// The argv names no session at all.
  static const none = ClientCliSessionTarget();

  /// The session the command will act on, when exactly one is provable.
  final String? sessionId;

  /// The argv names two different sessions (`--session A <sub> B`).
  ///
  /// A caller must refuse to relay rather than approve one of them: the
  /// forwarded command would act on the other one.
  final bool conflict;
}

/// Resolves the session a relayed argv targets, for approval scoping.
///
/// The resolver tokenizes the argv with the Agent's `args` grammar so an
/// approval can only ever name the session the forwarded command acts on:
///
/// * every value option consumes its value, so `session steer B --message -s A`
///   carries the literal text `-s` and targets `B`;
/// * a short option accepts an attached value (`-sA` is `--session A`), and the
///   attached text is the value verbatim, exactly as `args` reads it (`-s=A`
///   names the id `=A`, not `A`);
/// * `--name=value` and `--name value` are equivalent;
/// * `--` ends option parsing, so nothing after it is a session flag;
/// * the first positional token is the root command, the next is the `session`
///   subcommand, and only the positional after that is a session id.
///
/// Every session id the argv names — in any placement, because the Agent reads
/// a global `--session` and a subcommand `--session` through the same accessor —
/// is collected. Two different ids are reported as
/// [ClientCliSessionTarget.conflict] and the caller must refuse to relay, rather
/// than prefer one of them the way the Agent's own "last value wins" accessor
/// would.
ClientCliSessionTarget clientCliSessionTargetFor(List<String> argv) {
  if (argv.isEmpty) return ClientCliSessionTarget.none;

  final ids = <String>{};
  var commandSeen = false;
  var isSessionCommand = false;
  var subcommandSeen = false;
  var takesPositionalSessionId = false;

  for (final token in _tokenize(argv)) {
    if (token.isOption) {
      if (token.name == 'session' && token.takesValue) {
        final id = _nonEmpty(token.value);
        if (id != null) ids.add(id);
      }
      continue;
    }
    if (!commandSeen) {
      commandSeen = true;
      isSessionCommand = token.value == 'session';
      continue;
    }
    if (isSessionCommand && !subcommandSeen) {
      subcommandSeen = true;
      takesPositionalSessionId = !_clientCliSessionlessSubcommands.contains(
        token.value,
      );
      continue;
    }
    if (takesPositionalSessionId) {
      // Only the first positional after the subcommand is the session id;
      // a later one is a request id or another argument.
      takesPositionalSessionId = false;
      final id = _nonEmpty(token.value);
      if (id != null) ids.add(id);
    }
  }

  if (ids.length > 1) return const ClientCliSessionTarget(conflict: true);
  if (ids.isEmpty) return ClientCliSessionTarget.none;
  return ClientCliSessionTarget(sessionId: ids.single);
}

/// One classified argv token, mirroring how the Agent's `args` parser reads it.
class _ClientCliToken {
  const _ClientCliToken.option(
    this.name,
    this.value, {
    required this.takesValue,
  }) : isOption = true;

  const _ClientCliToken.argument(this.value)
    : isOption = false,
      name = '',
      takesValue = false;

  final bool isOption;

  /// Long option name for an option, or the literal text for an argument.
  final String name;
  final String? value;
  final bool takesValue;
}

/// Splits [argv] into option and argument tokens with the Agent's grammar.
///
/// Only [ _clientCliLongValueOptions] and [_clientCliShortOptions] are known.
/// An unknown option is treated as a flag, which cannot desynchronize the walk:
/// the Agent rejects an unknown option before it acts, so a misread there can
/// never approve a session the command goes on to use. A collapsed short group
/// (`-qs`) is read as flags too; a group whose first short takes a value is
/// always an attached value (`-sA`), and the Agent rejects a value-taking short
/// that follows a flag in the same token.
List<_ClientCliToken> _tokenize(List<String> argv) {
  final tokens = <_ClientCliToken>[];
  var optionsEnded = false;

  for (var i = 0; i < argv.length; i++) {
    final token = argv[i];
    if (!optionsEnded) {
      if (token == '--') {
        optionsEnded = true;
        continue;
      }
      if (token.startsWith('--') && token.length > 2) {
        final equalsAt = token.indexOf('=');
        final name = equalsAt == -1
            ? token.substring(2)
            : token.substring(2, equalsAt);
        final takesValue = _clientCliLongValueOptions.contains(name);
        var value = equalsAt == -1 ? null : token.substring(equalsAt + 1);
        if (takesValue && value == null && i + 1 < argv.length) {
          value = argv[++i];
        }
        tokens.add(
          _ClientCliToken.option(name, value, takesValue: takesValue),
        );
        continue;
      }
      if (token.startsWith('-') && token.length > 1) {
        final body = token.substring(1);
        final short = body[0];
        final shortName = _clientCliShortNames[short] ?? short;
        if (_clientCliShortOptions[short] ?? false) {
          // `args` treats the rest of the token as the value verbatim; an empty
          // rest takes the next token instead.
          var value = body.substring(1);
          if (value.isEmpty && i + 1 < argv.length) value = argv[++i];
          tokens.add(
            _ClientCliToken.option(shortName, value, takesValue: true),
          );
          continue;
        }
        tokens.add(
          _ClientCliToken.option(shortName, null, takesValue: false),
        );
        continue;
      }
    }
    tokens.add(_ClientCliToken.argument(token));
  }
  return tokens;
}

String? _nonEmpty(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Relay execution window in seconds for [argv].
///
/// The forwarded command's own `--timeout` (1..86400, last occurrence wins)
/// plus a small grace becomes the relay window. Without a usable `--timeout`
/// the protocol default stays in force, and the result is always clamped to the
/// protocol bounds so an out-of-range value cannot widen the relay.
int clientCliRelayTimeoutSecondsFor(List<String> argv) {
  int? requestedSeconds;
  for (final token in _tokenize(argv)) {
    if (!token.isOption || token.name != 'timeout' || !token.takesValue) {
      continue;
    }
    final value = token.value?.trim();
    if (value == null) continue;
    requestedSeconds = int.tryParse(value);
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

  // Skip the command token itself; everything after it decides the prompt.
  for (final token in _tokenize(argv).skip(1)) {
    if (token.isOption) {
      if (token.name == 'brief-file' || token.name == 'prompt') return false;
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
