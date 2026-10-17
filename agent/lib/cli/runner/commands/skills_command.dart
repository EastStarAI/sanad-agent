import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../capabilities/skills/skill_install_service.dart';
import '../../../capabilities/skills/skill_registry.dart';
import '../../../capabilities/skills/skill_scanner.dart';
import '../../../capabilities/skills/skill_source.dart';
import '../../../core/constants.dart';
import '../sanad_command.dart';

const int _usageExit = 64;

/// List, install, remove, and update Agent Skills available to the daemon.
class SkillsCommand extends SanadCommand {
  SkillsCommand({super.customAction}) {
    addSubcommand(
      SkillsListCommand(
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      SkillsAddCommand(
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      SkillsRemoveCommand(
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      SkillsUpdateCommand(
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
  }

  @override
  String get name => 'skills';

  @override
  String get description => 'List, install, remove, and update Agent Skills';

  @override
  String get invocation => 'sanad skills <list|add|remove|update> [options]';

  @override
  Future<int> execute() async {
    // `sanad skills` with no subcommand lists, which is what people expect.
    return listSkills(this, json: flagOf(this, 'json'));
  }
}

class SkillsListCommand extends SanadCommand {
  SkillsListCommand({super.customAction}) {
    addCommonOptions(argParser);
  }

  @override
  String get name => 'list';

  @override
  String get description =>
      'List installed skills, their origin, and precedence';

  @override
  Future<int> execute() async => listSkills(this, json: flagOf(this, 'json'));
}

class SkillsAddCommand extends SanadCommand {
  SkillsAddCommand({super.customAction}) {
    addCommonOptions(argParser);
    argParser
      ..addOption(
        'skill',
        help: 'Install only this skill when the source contains several',
        valueHelp: 'name',
      )
      ..addOption(
        'ref',
        help: 'Branch, tag, or commit for a GitHub source (default: HEAD)',
        valueHelp: 'ref',
      )
      ..addOption(
        'sub-path',
        aliases: const ['sub'],
        help: 'Sub-directory inside the source that holds the skills',
        valueHelp: 'path',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Replace a skill that is already installed under the same name',
      )
      ..addFlag(
        'allow-flagged',
        negatable: false,
        help: 'Install a skill even if security screening flagged findings',
      );
  }

  @override
  String get name => 'add';

  @override
  String get description =>
      'Install skills from owner/repo, a GitHub URL, or a local directory';

  @override
  Future<int> execute() async {
    final args = argResults?.rest ?? const <String>[];
    if (args.isEmpty) {
      stderrSink.writeln(
        'Usage: sanad skills add <owner/repo | github-url | local-path> '
        '[--skill <name>] [--ref <ref>] [--workspace <path>]',
      );
      return _usageExit;
    }

    final resolved = _workspaceOverride(this);
    if (resolved.error != null) {
      stderrSink.writeln(resolved.error);
      return _usageExit;
    }
    final service = _serviceFor(this, workspace: resolved.path);
    try {
      final source = SkillSource.parse(
        args.first,
        ref: getOption('ref'),
        subPath: getOption('sub-path'),
      );
      final outcome = await service.install(
        source,
        skill: getOption('skill'),
        force: flagOf(this, 'force'),
        allowFlagged: flagOf(this, 'allow-flagged'),
      );
      if (flagOf(this, 'json')) {
        stdoutSink.writeln(
          jsonEncode({
            'status': outcome.changed ? 'installed' : 'unchanged',
            'skill': outcome.name,
            'scope': outcome.scope.name,
            'path': outcome.path,
            'digest': outcome.digest,
          }),
        );
      } else {
        stdoutSink.writeln(
          '${outcome.changed ? 'Installed' : 'Unchanged'} ${outcome.name} '
          '(${outcome.scope.name}) → ${outcome.path}',
        );
        stdoutSink.writeln(
          'Available to the agent on the next turn; no daemon restart needed.',
        );
      }
      return 0;
    } on SkillSourceException catch (error) {
      stderrSink.writeln(error.message);
      return _usageExit;
    } on SkillScanException catch (error) {
      stderrSink.writeln(error.message);
      return 1;
    } on SkillInstallException catch (error) {
      stderrSink.writeln(error.message);
      return 1;
    } finally {
      service.close();
    }
  }
}

class SkillsRemoveCommand extends SanadCommand {
  SkillsRemoveCommand({super.customAction}) {
    addCommonOptions(argParser);
    argParser.addFlag(
      'force',
      negatable: false,
      help: 'Delete a skill that this command did not install',
    );
  }

  @override
  String get name => 'remove';

  @override
  String get description =>
      'Delete an installed skill and its provenance entry';

  @override
  Future<int> execute() async {
    final args = argResults?.rest ?? const <String>[];
    if (args.isEmpty) {
      stderrSink.writeln(
        'Usage: sanad skills remove <name> [--force] [--workspace <path>]',
      );
      return _usageExit;
    }

    final resolved = _workspaceOverride(this);
    if (resolved.error != null) {
      stderrSink.writeln(resolved.error);
      return _usageExit;
    }
    final service = _serviceFor(this, workspace: resolved.path);
    try {
      service.remove(args.first, force: flagOf(this, 'force'));
      if (flagOf(this, 'json')) {
        stdoutSink.writeln(
          jsonEncode({'status': 'removed', 'skill': args.first}),
        );
      } else {
        stdoutSink.writeln('Removed ${args.first}.');
      }
      return 0;
    } on SkillInstallException catch (error) {
      stderrSink.writeln(error.message);
      return 1;
    } finally {
      service.close();
    }
  }
}

class SkillsUpdateCommand extends SanadCommand {
  SkillsUpdateCommand({super.customAction}) {
    addCommonOptions(argParser);
    argParser.addFlag(
      'force',
      negatable: false,
      help: 'Overwrite locally modified skills with remote versions',
    );
  }

  @override
  String get name => 'update';

  @override
  String get description =>
      'Re-fetch installed skills from the sources recorded at install time';

  @override
  Future<int> execute() async {
    final args = argResults?.rest ?? const <String>[];
    final resolved = _workspaceOverride(this);
    if (resolved.error != null) {
      stderrSink.writeln(resolved.error);
      return _usageExit;
    }
    final service = _serviceFor(this, workspace: resolved.path);
    try {
      final outcomes = await service.update(
        name: args.isEmpty ? null : args.first,
        force: flagOf(this, 'force'),
      );
      if (flagOf(this, 'json')) {
        stdoutSink.writeln(
          jsonEncode({
            'skills': [
              for (final outcome in outcomes)
                {
                  'skill': outcome.name,
                  'status':
                      outcome.status == SkillInstallStatus.skippedLocalEdits
                      ? 'skippedLocalEdits'
                      : (outcome.changed ? 'updated' : 'unchanged'),
                  'path': outcome.path,
                  'digest': outcome.digest,
                },
            ],
          }),
        );
      } else {
        for (final outcome in outcomes) {
          if (outcome.status == SkillInstallStatus.skippedLocalEdits) {
            stdoutSink.writeln(
              'Skipped ${outcome.name} (local edits; re-run with --force)',
            );
          } else {
            stdoutSink.writeln(
              '${outcome.changed ? 'Updated' : 'Up to date'} ${outcome.name}',
            );
          }
        }
      }
      return 0;
    } on SkillSourceException catch (error) {
      stderrSink.writeln(error.message);
      return _usageExit;
    } on SkillInstallException catch (error) {
      stderrSink.writeln(error.message);
      return 1;
    } finally {
      service.close();
    }
  }
}

Future<int> listSkills(SanadCommand command, {required bool json}) async {
  final registry = SkillRegistry(environment: _environmentFor(command));
  final workspace = workspacePath(command);
  final report = await registry.list(workspacePath: workspace);
  final installed = <String, InstalledSkillRecord>{};
  for (final root in _provenanceRoots(workspace)) {
    final service = SkillInstallService(
      skillsRoot: root,
      scope: SkillScope.user,
    );
    try {
      installed.addAll(service.readProvenance());
    } on SkillInstallException {
      // A corrupt provenance file must not hide the skills themselves.
    } finally {
      service.close();
    }
  }

  if (json) {
    command.stdoutSink.writeln(
      jsonEncode({
        'skills': [
          for (final entry in report.skills)
            {
              ...entry.toJson(),
              if (installed[entry.name] != null)
                'installed_from': installed[entry.name]!.source,
            },
        ],
      }),
    );
    return 0;
  }

  if (report.skills.isEmpty) {
    command.stdoutSink.writeln(
      'No skills found. Install one with: '
      'sanad skills add <owner/repo> --skill <name>',
    );
    return 0;
  }

  final rows = [
    ['NAME', 'SCOPE', 'STATUS', 'SOURCE'],
    for (final entry in report.skills)
      [
        entry.name,
        entry.origin.scope.name,
        entry.active ? 'active' : 'shadowed',
        installed[entry.name]?.source ?? entry.origin.rootKind.name,
      ],
  ];
  final widths = List<int>.generate(
    rows.first.length,
    (index) =>
        rows.map((row) => row[index].length).reduce((a, b) => a > b ? a : b),
  );
  command.stdoutSink.writeln('Skills (${report.skills.length}):');
  for (final row in rows) {
    command.stdoutSink.writeln(
      '  ${[for (var i = 0; i < row.length; i++) i == row.length - 1 ? row[i] : row[i].padRight(widths[i])].join('  ')}',
    );
  }
  return 0;
}

SkillInstallService _serviceFor(
  SanadCommand command, {
  required String? workspace,
}) {
  _environmentFor(command);
  if (workspace == null) {
    return SkillInstallService(
      skillsRoot: Directory(p.join(getSanadHome(), 'skills')),
      scope: SkillScope.user,
    );
  }
  return SkillInstallService(
    skillsRoot: Directory(p.join(workspace, '.sanad', 'skills')),
    scope: SkillScope.workspace,
  );
}

/// Resolves the shared `--workspace` option for a skills subcommand.
///
/// These commands run standalone and never open the daemon, so they accept an
/// existing directory path rather than a registered workspace ID. Omitting the
/// option means the Sanad Home scope.
({String? path, String? error}) _workspaceOverride(SanadCommand command) {
  final configured = command.getOption('workspace')?.trim();
  if (configured == null || configured.isEmpty) {
    return (path: null, error: null);
  }
  final directory = Directory(configured);
  if (!directory.existsSync()) {
    return (
      path: null,
      error:
          'Workspace path not found: $configured\n'
          'Pass an existing directory to --workspace, or omit it to use the '
          'Sanad Home.',
    );
  }
  return (path: directory.absolute.path, error: null);
}

List<Directory> _provenanceRoots(String workspace) => [
  Directory(p.join(getSanadHome(), 'skills')),
  Directory(p.join(workspace, '.sanad', 'skills')),
];

/// Applies `--home` before any path is resolved, then mirrors the platform
/// environment so the registry scans the same roots the daemon would.
Map<String, String> _environmentFor(SanadCommand command) {
  final home = command.getOption('home');
  if (home != null && home.isNotEmpty) {
    setSanadHomeOverride(home);
  }
  final environment = Map<String, String>.from(Platform.environment);
  environment['SANAD_HOME'] = getSanadHome();
  return environment;
}

String workspacePath(SanadCommand command) {
  final configured = command.getOption('workspace');
  if (configured != null && configured.isNotEmpty) return configured;
  return Directory.current.path;
}

bool flagOf(SanadCommand command, String name) {
  final results = command.argResults;
  if (results != null &&
      results.options.contains(name) &&
      results.wasParsed(name)) {
    return (results[name] as bool?) ?? false;
  }
  final globals = command.globalResults;
  if (globals != null &&
      globals.options.contains(name) &&
      globals.wasParsed(name)) {
    return (globals[name] as bool?) ?? false;
  }
  return false;
}
