import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import '../constants.dart';

class CliPathManager {
  static final _logger = Logger('CliPathManager');

  /// Ensures that the Sanad bin directory is added to the user's shell PATH.
  static Future<bool> ensureOnPath({
    String? customHomeDir,
    String? customBinDir,
  }) async {
    final home = customHomeDir ?? _getHomeDirectory();
    final binDir = customBinDir ?? p.join(getSanadHome(), 'bin');
    if (home.isEmpty) {
      return false;
    }

    if (Platform.isWindows) {
      return _ensureWindowsPath(binDir);
    } else {
      return _ensurePosixPath(home, binDir);
    }
  }

  static String _getHomeDirectory() {
    if (Platform.isWindows) {
      return Platform.environment['USERPROFILE'] ?? '';
    }
    return Platform.environment['HOME'] ?? '';
  }

  static Future<bool> _ensurePosixPath(String home, String binDir) async {
    var modifiedAny = false;
    final pathExportLine = 'export PATH="$binDir:\$PATH"';
    final commentLine = '# Added by Sanad';

    // Candidate shell profiles
    final candidateFiles = <String>[];

    if (Platform.isMacOS) {
      // On macOS, zsh is default. Always ensure .zshrc exists/is updated
      candidateFiles.add(p.join(home, '.zshrc'));
      for (final name in ['.bash_profile', '.bashrc', '.profile', '.zprofile']) {
        final path = p.join(home, name);
        if (File(path).existsSync() && !candidateFiles.contains(path)) {
          candidateFiles.add(path);
        }
      }
    } else {
      // Linux: .bashrc, .profile, .zshrc
      for (final name in ['.bashrc', '.profile', '.zshrc']) {
        final path = p.join(home, name);
        if (File(path).existsSync() && !candidateFiles.contains(path)) {
          candidateFiles.add(path);
        }
      }
      if (candidateFiles.isEmpty) {
        candidateFiles.add(p.join(home, '.bashrc'));
      }
    }

    for (final filePath in candidateFiles) {
      final file = File(filePath);
      try {
        if (file.existsSync()) {
          final content = await file.readAsString();
          if (content.contains('.sanad/bin') || content.contains(binDir)) {
            _logger.fine('Sanad bin is already present in $filePath');
            continue;
          }
          final separator = content.endsWith('\n') || content.isEmpty ? '' : '\n';
          await file.writeAsString(
            '$content$separator\n$commentLine\n$pathExportLine\n',
          );
          _logger.info('Added Sanad bin to $filePath');
          modifiedAny = true;
        } else {
          await file.parent.create(recursive: true);
          await file.writeAsString('$commentLine\n$pathExportLine\n');
          _logger.info('Created $filePath and added Sanad bin to PATH');
          modifiedAny = true;
        }
      } catch (e) {
        _logger.warning('Could not update shell profile $filePath: $e');
      }
    }

    // Attempt user-level symlink creation if ~/.local/bin exists
    await _tryCreateSymlink(binDir, p.join(home, '.local', 'bin'));

    return modifiedAny;
  }

  static Future<void> _tryCreateSymlink(String binDir, String targetDir) async {
    try {
      final targetDirObj = Directory(targetDir);
      if (targetDirObj.existsSync()) {
        final symlinkPath = p.join(targetDir, 'sanad');
        final targetExec = p.join(binDir, 'sanad');
        if (File(targetExec).existsSync() &&
            !File(symlinkPath).existsSync() &&
            !Link(symlinkPath).existsSync()) {
          await Link(symlinkPath).create(targetExec);
          _logger.info('Created symlink at $symlinkPath -> $targetExec');
        }
      }
    } catch (_) {
      // Best-effort, ignore permission or filesystem errors
    }
  }

  static Future<bool> _ensureWindowsPath(String binDir) async {
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '''
        \$currentPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if (\$currentPath -notlike "*$binDir*") {
            [Environment]::SetEnvironmentVariable('Path', "\$currentPath;$binDir", 'User')
            exit 0
        }
        exit 0
        ''',
      ]);
      return result.exitCode == 0;
    } catch (e) {
      _logger.warning('Could not update Windows user PATH: $e');
      return false;
    }
  }
}
