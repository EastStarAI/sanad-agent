#!/usr/bin/env dart

import 'dart:io';

// Frontmatter Regex Matchers
final RegExp frontmatterRegExp = RegExp(
  r'^---\s*\n(.*?)\n---\s*\n',
  dotAll: true,
);
final RegExp titleRegExp = RegExp(
  r'^title:\s*["' + "'" + r']?(.+?)["' + "'" + r']?\s*$',
  multiLine: true,
);
final RegExp descRegExp = RegExp(
  r'^description:\s*["' + "'" + r']?(.+?)["' + "'" + r']?\s*$',
  multiLine: true,
);

class DocMeta {
  final String relativePath;
  final String title;
  final String description;
  final String body;

  DocMeta({
    required this.relativePath,
    required this.title,
    required this.description,
    required this.body,
  });
}

/// Mirrors the generated-artifact rule in `scripts/lint_wiki.dart`: dependency
/// link trees that Flutter's tooling generates inside the workspace
/// (`ephemeral/.plugin_symlinks/` on Linux/Windows, `ephemeral/.symlinks/` on
/// macOS/iOS) resolve into the pub cache and are gitignored. Their `AGENTS.md`
/// files are third-party package contracts and must never enter this
/// repository's index. Keep this rule in sync with the linter.
bool isGeneratedDependencyPath(String cleanPath) {
  return cleanPath.contains('/.plugin_symlinks/') ||
      cleanPath.contains('/ephemeral/.symlinks/');
}

DocMeta parseFile(File file) {
  final content = file.readAsStringSync().replaceAll('\r\n', '\n');
  final match = frontmatterRegExp.firstMatch(content);

  String title = '';
  String description = '';
  String body = content;

  if (match != null) {
    final fmText = match.group(1) ?? '';
    body = content.substring(match.end);

    final titleMatch = titleRegExp.firstMatch(fmText);
    if (titleMatch != null) {
      title = titleMatch.group(1) ?? '';
    }

    final descMatch = descRegExp.firstMatch(fmText);
    if (descMatch != null) {
      description = descMatch.group(1) ?? '';
    }
  }

  // Fallbacks if no frontmatter
  final baseName = file.path
      .split('/')
      .last
      .split('\\')
      .last
      .replaceAll('.md', '');
  if (title.isEmpty) {
    title = baseName.toUpperCase();
  }
  if (description.isEmpty) {
    description = 'Technical specification for $baseName.';
  }

  final cleanRelPath = file.path.replaceAll('\\', '/');
  return DocMeta(
    relativePath: cleanRelPath,
    title: title,
    description: description,
    body: body,
  );
}

void main() async {
  final docsDir = Directory('docs');
  final rootDir = Directory('.');

  if (!docsDir.existsSync()) {
    docsDir.createSync(recursive: true);
  }

  final docMetas = <DocMeta>[];
  final agentsMetas = <DocMeta>[];

  // 1. Gather and parse all active documentation files
  if (docsDir.existsSync()) {
    docsDir.listSync(recursive: true).forEach((entity) {
      final cleanPath = entity.path.replaceAll('\\', '/');

      final isArchived = cleanPath.contains('docs/archive/');
      final isPlan = cleanPath.contains('docs/plans/');

      if (entity is File &&
          entity.path.endsWith('.md') &&
          !cleanPath.endsWith('llms.txt') &&
          !cleanPath.endsWith('llms-full.txt') &&
          !isArchived &&
          !isPlan) {
        docMetas.add(parseFile(entity));
      }
    });
  }

  // 2. Gather and parse all active AGENTS.md contract files
  rootDir.listSync(recursive: true).forEach((entity) {
    if (entity is File && entity.path.endsWith('AGENTS.md')) {
      final cleanPath = entity.path.replaceAll('\\', '/');
      if (!cleanPath.contains('/.git/') &&
          !cleanPath.contains('/.agent/') &&
          !cleanPath.contains('/build/') &&
          !cleanPath.contains('/.dart_tool/') &&
          !cleanPath.contains('/sanad-agent/') &&
          !cleanPath.contains('docs/archive/') &&
          !cleanPath.contains('/refrence_projects/') &&
          !cleanPath.startsWith('refrence_projects/') &&
          !cleanPath.contains('/node_modules/') &&
          !isGeneratedDependencyPath(cleanPath)) {
        agentsMetas.add(parseFile(entity));
      }
    }
  });

  // Sort files for deterministic output
  docMetas.sort((a, b) => a.relativePath.compareTo(b.relativePath));
  agentsMetas.sort((a, b) => a.relativePath.compareTo(b.relativePath));

  // 3. Build docs/llms.txt
  final llmsBuffer = StringBuffer();
  llmsBuffer.writeln('# Sanad Project Codebase Index');
  llmsBuffer.writeln();
  llmsBuffer.writeln(
    '> This file is the machine-readable index for LLMs and coding agents, conforming to https://llmstxt.org. It lists all active documentation and runtime system contracts.',
  );
  llmsBuffer.writeln();
  llmsBuffer.writeln(
    'Install: `fvm flutter run` for the UI Client, or `fvm dart run` for the Local Daemon.',
  );
  llmsBuffer.writeln('Repo: https://github.com/EastStarAI/sanad-agent');
  llmsBuffer.writeln();

  llmsBuffer.writeln('## System Rules & Runtime Contracts');
  llmsBuffer.writeln();
  llmsBuffer.writeln(
    'These files are mandatory execution contracts governing subdirectories. Always read them before editing files in their folders.',
  );
  llmsBuffer.writeln();
  for (final meta in agentsMetas) {
    llmsBuffer.writeln(
      '- [${meta.title}](${meta.relativePath}): Rules governing ${meta.relativePath.replaceAll('/AGENTS.md', '').replaceAll('AGENTS.md', 'workspace root')}.',
    );
  }
  llmsBuffer.writeln();

  llmsBuffer.writeln('## Functional Features & Architecture Guides');
  llmsBuffer.writeln();
  for (final meta in docMetas) {
    llmsBuffer.writeln(
      '- [${meta.title}](${meta.relativePath}): ${meta.description}',
    );
  }
  llmsBuffer.writeln(
    '- [Implementation Plans](docs/plans/): Architectural blueprints, milestones, and step-by-step implementation plans for project development phases.',
  );
  llmsBuffer.writeln();
  llmsBuffer.writeln('## Reference Projects');
  llmsBuffer.writeln();
  llmsBuffer.writeln(
    '- [Reference Projects](refrence_projects/): Directory containing reference projects for development inspiration.',
  );
  llmsBuffer.writeln();
  llmsBuffer.writeln('## Historical & Legacy Reference (Optional)');
  llmsBuffer.writeln();
  llmsBuffer.writeln(
    '- [Archived Documentation](docs/archive/): Obsolete plans, drafts, and legacy specifications archived chronologically.',
  );

  final llmsTextFile = File('docs/llms.txt');
  llmsTextFile.writeAsStringSync(llmsBuffer.toString());
  print(
    'Successfully wrote ${llmsTextFile.path} (${llmsTextFile.lengthSync()} bytes).',
  );

  // 4. Build docs/llms-full.txt (Concatenated)
  final fullBuffer = StringBuffer();
  fullBuffer.writeln('# Sanad Project — Full Unified Documentation');
  fullBuffer.writeln();
  fullBuffer.writeln(
    'This file concatenates all system contracts and guides for single-shot context ingestion.',
  );
  fullBuffer.writeln('Site Index: docs/llms.txt');
  fullBuffer.writeln();
  fullBuffer.writeln('---');
  fullBuffer.writeln();

  // Add system contracts first (front-load rules)
  for (final meta in agentsMetas) {
    fullBuffer.writeln('<!-- source: ${meta.relativePath} -->');
    fullBuffer.writeln('# Contract: ${meta.title} (${meta.relativePath})');
    fullBuffer.writeln();
    fullBuffer.writeln(meta.body.trim());
    fullBuffer.writeln();
    fullBuffer.writeln('---');
    fullBuffer.writeln();
  }

  // Add functional guides
  for (final meta in docMetas) {
    fullBuffer.writeln('<!-- source: ${meta.relativePath} -->');
    fullBuffer.writeln('# Guide: ${meta.title}');
    fullBuffer.writeln();
    fullBuffer.writeln(meta.body.trim());
    fullBuffer.writeln();
    fullBuffer.writeln('---');
    fullBuffer.writeln();
  }

  final llmsFullTextFile = File('docs/llms-full.txt');
  llmsFullTextFile.writeAsStringSync('${fullBuffer.toString().trimRight()}\n');
  print(
    'Successfully wrote ${llmsFullTextFile.path} (${llmsFullTextFile.lengthSync()} bytes).',
  );
}
