#!/usr/bin/env dart
import 'dart:io';

// Markdown Link Matcher
final RegExp linkRegExp = RegExp(r'\[([^\]]+)\]\(([^)]+)\)');
final RegExp frontmatterRegExp = RegExp(r'^---\s*\n(.*?)\n---\s*\n', dotAll: true);
final RegExp descRegExp = RegExp(r'^description:\s*["' + "'" + r']?(.+?)["' + "'" + r']?\s*$', multiLine: true);

class LintError {
  final String filePath;
  final String message;
  LintError(this.filePath, this.message);

  @override
  String toString() => '[$filePath] ERROR: $message';
}

/// True only for dependency link trees that Flutter's tooling generates inside
/// the workspace: the Linux/Windows plugin tree (`ephemeral/.plugin_symlinks/`)
/// and the macOS/iOS plugin tree (`ephemeral/.symlinks/`, for example
/// `client/macos/Flutter/ephemeral/.symlinks/`).
///
/// Every file below those directories resolves into the pub cache and is
/// gitignored, so an `AGENTS.md` found there is a third-party package contract,
/// not this repository's. Real repository contracts remain discoverable
/// anywhere else in the checkout.
bool isGeneratedDependencyPath(String cleanPath) {
  return cleanPath.contains('/.plugin_symlinks/') ||
      cleanPath.contains('/ephemeral/.symlinks/');
}

void main() async {
  print('Running docs linter (scripts/lint_wiki.dart)...');
  
  final docsDir = Directory('docs');
  final rootDir = Directory('.');
  final errors = <LintError>[];
  
  if (!docsDir.existsSync()) {
    print('No docs directory found. Skipping linting.');
    exit(0);
  }

  // 1. Gather all active markdown pages
  final mdFiles = <File>[];
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
      mdFiles.add(entity);
    }
  });

  // 2. Gather all active AGENTS.md contract files
  final agentsFiles = <File>[];
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
        agentsFiles.add(entity);
      }
    }
  });

  final allDocPaths = mdFiles.map((f) => f.path.replaceAll('\\', '/')).toSet();
  final allAgentsPaths = agentsFiles.map((f) => f.path.replaceAll('\\', '/')).toSet();
  final referencedPaths = <String>{};

  // 3. Verify llms.txt index matches existing files
  final llmsFile = File('docs/llms.txt');
  if (!llmsFile.existsSync()) {
    errors.add(LintError('docs/llms.txt', 'Index file does not exist. Run scripts/generate_llms_txt.dart first.'));
  } else {
    final llmsContent = llmsFile.readAsStringSync();
    
    // Scan all file paths to make sure they are referenced in llms.txt
    for (final docPath in allDocPaths) {
      if (!llmsContent.contains(docPath)) {
        errors.add(LintError(docPath, 'Document is not indexed in docs/llms.txt.'));
      }
    }
    for (final agentsPath in allAgentsPaths) {
      if (!llmsContent.contains(agentsPath)) {
        errors.add(LintError(agentsPath, 'Contract file is not indexed in docs/llms.txt.'));
      }
    }
  }

  // 4. Scan files for broken links & empty descriptions (only lint active, indexed files)
  final llmsContent = llmsFile.existsSync() ? llmsFile.readAsStringSync() : '';
  final allFilesToScan = <File>[];
  for (final file in [...mdFiles, ...agentsFiles]) {
    final cleanPath = file.path.replaceAll('\\', '/');
    if (llmsContent.contains(cleanPath)) {
      allFilesToScan.add(file);
    }
  }
  for (final file in allFilesToScan) {
    final cleanPath = file.path.replaceAll('\\', '/');
    final content = file.readAsStringSync().replaceAll('\r\n', '\n');

    // Verify description exists in frontmatter for documents
    if (file.path.endsWith('.md') && !file.path.endsWith('AGENTS.md')) {
      final match = frontmatterRegExp.firstMatch(content);
      if (match == null) {
        errors.add(LintError(cleanPath, 'Missing markdown frontmatter.'));
      } else {
        final fm = match.group(1) ?? '';
        if (!descRegExp.hasMatch(fm)) {
          errors.add(LintError(cleanPath, 'Missing description in frontmatter.'));
        }
      }
    }

    // Verify links are not broken
    final matches = linkRegExp.allMatches(content);
    for (final m in matches) {
      var url = m.group(2) ?? '';
      
      // Clean up protocol markers in gemini terminal links if any
      if (url.startsWith('file;file:///')) {
        url = url.replaceAll('file;file:///', '/');
      } else if (url.startsWith('file:///')) {
        url = url.replaceAll('file:///', '/');
      }
      
      // We only validate local file links (relative or pointing inside workspace root)
      if (!url.startsWith('http://') && 
          !url.startsWith('https://') && 
          !url.startsWith('mailto:') && 
          !url.startsWith('#') &&
          url.isNotEmpty) {
        
        // Clean fragment links like docs/workflow.md#section-name
        final hashIdx = url.indexOf('#');
        final cleanUrl = hashIdx != -1 ? url.substring(0, hashIdx) : url;

        if (cleanUrl.isNotEmpty) {
          // Resolve relative or absolute path within the workspace
          var targetPath = cleanUrl;
          final workspaceRoot = Directory.current.absolute.path.replaceAll('\\', '/');
          
          if (cleanUrl.startsWith(workspaceRoot)) {
            targetPath = cleanUrl.substring(workspaceRoot.length);
            if (targetPath.startsWith('/')) {
              targetPath = targetPath.substring(1);
            }
          } else if (cleanUrl.startsWith('/')) {
            targetPath = cleanUrl.substring(1); // relative from workspace root
          } else {
            // Resolve relative to the current file's parent directory
            final parentDir = file.parent.path.replaceAll('\\', '/');
            targetPath = parentDir == '.' ? cleanUrl : '$parentDir/$cleanUrl';
          }
          
          // Remove duplicate slashes and normalize
          targetPath = Uri.parse(targetPath).normalizePath().path;
          
          // Check if file exists
          final targetFile = File(targetPath);
          final targetDir = Directory(targetPath);
          if (!targetFile.existsSync() && !targetDir.existsSync()) {
            final isPlan = cleanPath.contains('docs/plans/');
            if (isPlan) {
              print('WARNING: Broken link in plan [$cleanPath]: "$url" (Resolved path: "$targetPath" does not exist).');
            } else {
              errors.add(LintError(cleanPath, 'Broken link to "$url" (Resolved path: "$targetPath" does not exist).'));
            }
          } else {
            referencedPaths.add(targetPath.replaceAll('\\', '/'));
          }
        }
      }
    }
  }

  // 5. Check for orphan pages in docs/
  for (final docPath in allDocPaths) {
    // index.md or home docs or pages linked by llms.txt are exempt from standard orphan check
    if (docPath == 'docs/index.md') continue;
    if (!referencedPaths.contains(docPath)) {
      // Check if referenced as relative path by another page
      var isReferenced = false;
      for (final ref in referencedPaths) {
        if (ref.endsWith(docPath)) {
          isReferenced = true;
          break;
        }
      }
      if (!isReferenced) {
        print('INFO: Orphan document detected: $docPath (No other pages link to this file).');
      }
    }
  }

  // 6. Report errors
  if (errors.isNotEmpty) {
    print('\nFAILED: Found ${errors.length} documentation errors:');
    for (final err in errors) {
      print(err);
    }
    exit(1);
  } else {
    print('\nSUCCESS: All documentation files are valid, indexed, and healthy!');
    exit(0);
  }
}
