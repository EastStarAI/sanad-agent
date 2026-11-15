part of '../../sanad_dev_cli.dart';

void printUsage() {
  print('Usage: sanad-dev <command> [target] [options]');
  print('');
  print('Commands:');
  print(
    '  run [all|agent|client]    Launch all components (default) or one component.',
  );
  print(
    '  status                    Show the runtime source and all attached clients.',
  );
  print(
    '  inventory [--all] [--pr] [--json] Show every worktree, runtime, client and orphaned record (read-only).',
  );
  print(
    '  cleanup-orphans [--confirm] [--json] List the dev-area orphans it can prune; delete only with --confirm.',
  );
  print(
    '  stop [all|agent|client]   Stop all components (default) or one component.',
  );
  print(
    '  doctor [--fix]            Diagnose ownership; remove only stale records.',
  );
  print(
    '                            Reports driver-host grants, the driver entry point, and port/Home ownership.',
  );
  print(
    '  reset                     Stop this worktree runtime, apply a Home fixture, then run --driver.',
  );
  print(
    '  apply [--dry-run]         Inspect changes since the runtime started; run the lightest correct action.',
  );
  print(
    '  refresh --at <+duration>  Schedule an out-of-tree pull, then restart agent and client.',
  );
  print(
    '  cli path agent|client     Print the cached compiled CLI artifact path.',
  );
  print('  cli agent|client -- <args>  Run the cached compiled CLI artifact.');
  print(
    '  takeover [--force]        Relaunch a complete manual pair, or reclaim this runtime when its port is served by a daemon that is not its lease.',
  );
  print(
    '  cleanup-target-orphans    Remove proven stale clients in this target only.',
  );
  print(
    '  switch --runtime current  Move the active runtime group to this worktree.',
  );
  print(
    '                            Pass --home <source-home> when this worktree has no runtime yet.',
  );
  print(
    '                            Requires direct user authorization; all sessions sharing the pair are affected.',
  );
  print(
    '  logs [client|agent]       Show logs for the client (default) or agent.',
  );
  print('  restart [client|agent]    Restart the client (default) or agent.');
  print('  reload [client]           Reload the client.');
  print(
    '  inspect [client]          Open Flutter DevTools / Inspector for the client.',
  );
  print(
    '  ui / driver <command>     Interact with client (snapshot, find, auth-url, tap, hover, enter-text, scroll, wait-for, screenshot, batch, ext).',
  );
  print('');
  print('Options:');
  print('  -f, --follow              Stream logs live in real-time.');
  print('  --wait                    Wait for a managed component journal.');
  print(
    '  --agent-port <port>       Select the journal group for a Client watcher.',
  );
  print(
    '  -n, --tail <lines>        Output only the last <lines> log entries.',
  );
  print(
    '  -p, --port <port>         Target a specific running instance by its port.',
  );
  print(
    '  --all                     Expand every inventory row with its full detail.',
  );
  print('  --json                    Print the stable inventory JSON document.');
  print(
    '  --pr                      Also query gh for each worktree pull request '
    '(cached, never required).',
  );
  print('  --no-pr                   Skip the pull request lookup (the default).');
  print(
    '  --confirm                 Actually delete the listed orphan targets.',
  );
  print('  --runtime current         Select the requester runtime for switch.');
  print(
    '  --port <port>             With switch, identify the requester agent when several runtimes are live.',
  );
  print('  --driver                  Run client/lib/driver_main.dart.');
  print(
    '  --cloud                   Explicitly enable cloud (already the default).',
  );
  print('  --no-cloud                Disable cloud and run local-only.');
  print(
    '  --home <user|absolute>    Select the run Home or explicitly override inferred discovery.',
  );
  print(
    '  -d, --device <id>         Flutter device for run client/all or stop client.',
  );
  print(
    '  --client-instance <slot>  Add a same-device Client with isolated preferences.',
  );
  print(
    '  --config <path>           Client config file (default: $defaultSanadDevClientConfig).',
  );
  print(
    '  --fixture <name>          Home fixture to restore during reset (atomic).',
  );
  print(
    '  --save-fixture <name>     Snapshot the Home databases and config before reset.',
  );
  print(
    '  --keep-data               Reset without restoring a fixture (the default).',
  );
  print(
    '  --include-mcp-config      Also capture mcp_config.json in a fixture (may '
    'contain secrets).',
  );
  print(
    '  --at <+duration>          Refresh delay, for example +2m, +90s, or +1h.',
  );
  print('  --dry-run                 Resolve and print runtime settings only.');
  print(
    '  --background              Launch detached and wait for a managed/failure result.',
  );
  print('  --fix                     Apply doctor safe stale-record repairs.');
  print(
    '  --timeout <seconds>       Agent restart safety timeout (default: 60).',
  );
  print(
    '  --force                   Force restart, cancel work for stop agent/all, or allow a forced reclaim in takeover.',
  );
  print('');
  print('Examples:');
  print('  sanad-dev run');
  print('  sanad-dev run --background');
  print('  sanad-dev inventory');
  print('  sanad-dev inventory --all');
  print('  sanad-dev inventory --json');
  print('  sanad-dev inventory --pr');
  print('  sanad-dev cleanup-orphans');
  print('  sanad-dev cleanup-orphans --confirm');
  print('  sanad-dev run agent');
  print('  sanad-dev run client -d macos');
  print('  sanad-dev stop client -d macos');
  print('  sanad-dev stop agent --force');
  print('  sanad-dev run --driver');
  print('  sanad-dev logs client -n 50 -f');
  print('  sanad-dev logs client -p 50139');
  print('  sanad-dev restart agent -p 58085');
  print('  sanad-dev reset --keep-data');
  print('  sanad-dev reset --fixture clean --save-fixture before-fix');
  print('  sanad-dev apply --dry-run');
  print('  sanad-dev cli agent -- session list');
  print('  sanad-dev refresh --at +5m');
}
