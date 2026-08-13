import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/sanad_home/sanad_home_bootstrap.dart';
import 'generated_bundled_skills.dart';

class BundledSkillSyncResult {
  const BundledSkillSyncResult({
    required this.fastPath,
    this.installed = 0,
    this.updated = 0,
    this.removed = 0,
    this.preserved = 0,
  });

  final bool fastPath;
  final int installed;
  final int updated;
  final int removed;
  final int preserved;
}

class BundledSkillManager {
  BundledSkillManager({
    SanadHomeBootstrap? home,
    this.bundleRevision = bundledSkillsRevision,
    this.skills = bundledSkills,
  }) : _home = home ?? SanadHomeBootstrap.identity();

  static const statePath = 'skills/.sanad-managed.json';

  final SanadHomeBootstrap _home;
  final String bundleRevision;
  final List<BundledSkill> skills;

  BundledSkillSyncResult reconcileSync() {
    final state = _readState();
    if (state.bundleRevision == bundleRevision) {
      return const BundledSkillSyncResult(fastPath: true);
    }

    _home.ensureDirectoryPathSync('skills');
    var installed = 0;
    var updated = 0;
    var removed = 0;
    var preserved = 0;
    final currentIds = skills.map((skill) => skill.id).toSet();

    for (final skill in skills) {
      final bundledFiles = {
        for (final file in skill.files) file.path: file.decode(),
      };
      final executablePaths = {
        for (final file in skill.files)
          if (file.executable) file.path,
      };
      final bundledHash = _directoryHash(bundledFiles);
      final relative = 'skills/${skill.id}';
      final currentFiles = _home.readDirectoryBytesSync(relative);
      final previous = state.entries[skill.id];

      if (currentFiles.isEmpty) {
        if (previous?.status == _ManagedStatus.userDeleted) {
          state.entries[skill.id] = _ManagedEntry(
            originHash: bundledHash,
            status: _ManagedStatus.userDeleted,
          );
          preserved += 1;
        } else if (previous != null) {
          state.entries[skill.id] = _ManagedEntry(
            originHash: bundledHash,
            status: _ManagedStatus.userDeleted,
          );
          preserved += 1;
        } else {
          _home.replaceDirectoryBytesSync(
            relative,
            bundledFiles,
            executablePaths: executablePaths,
          );
          state.entries[skill.id] = _ManagedEntry(
            originHash: bundledHash,
            status: _ManagedStatus.managed,
          );
          installed += 1;
        }
        _writeProgress(state);
        continue;
      }

      final currentHash = _directoryHash(currentFiles);
      if (previous == null) {
        if (currentHash == bundledHash) {
          state.entries[skill.id] = _ManagedEntry(
            originHash: bundledHash,
            status: _ManagedStatus.managed,
          );
        } else {
          preserved += 1;
        }
        _writeProgress(state);
        continue;
      }

      if (currentHash == bundledHash) {
        state.entries[skill.id] = _ManagedEntry(
          originHash: bundledHash,
          status: _ManagedStatus.managed,
        );
      } else if (previous.status == _ManagedStatus.managed &&
          currentHash == previous.originHash) {
        _home.replaceDirectoryBytesSync(
          relative,
          bundledFiles,
          executablePaths: executablePaths,
        );
        updated += 1;
        state.entries[skill.id] = _ManagedEntry(
          originHash: bundledHash,
          status: _ManagedStatus.managed,
        );
      } else {
        state.entries.remove(skill.id);
        preserved += 1;
      }
      _writeProgress(state);
    }

    for (final id in state.entries.keys.toList(growable: false)) {
      if (currentIds.contains(id)) continue;
      final previous = state.entries[id]!;
      if (previous.status == _ManagedStatus.userDeleted) {
        state.entries.remove(id);
        _writeProgress(state);
        continue;
      }
      final relative = 'skills/$id';
      final currentFiles = _home.readDirectoryBytesSync(relative);
      if (currentFiles.isNotEmpty &&
          _directoryHash(currentFiles) == previous.originHash) {
        _home.deleteDirectorySync(relative);
        removed += 1;
      } else if (currentFiles.isNotEmpty) {
        preserved += 1;
      }
      state.entries.remove(id);
      _writeProgress(state);
    }

    state.bundleRevision = bundleRevision;
    _writeState(state);
    return BundledSkillSyncResult(
      fastPath: false,
      installed: installed,
      updated: updated,
      removed: removed,
      preserved: preserved,
    );
  }

  _ManagedState _readState() {
    if (!_home.fileExists(statePath)) return _ManagedState.empty();
    try {
      final raw = jsonDecode(utf8.decode(_home.readSecretBytes(statePath)));
      if (raw is! Map<String, dynamic> || raw['schema_version'] != 1) {
        return _ManagedState.empty();
      }
      final entriesRaw = raw['skills'];
      if (entriesRaw is! Map<String, dynamic>) return _ManagedState.empty();
      final entries = <String, _ManagedEntry>{};
      for (final item in entriesRaw.entries) {
        final value = item.value;
        if (value is! Map<String, dynamic>) continue;
        final hash = value['origin_hash'];
        final status = _ManagedStatus.values
            .where((candidate) => candidate.name == value['status'])
            .firstOrNull;
        if (hash is String && status != null) {
          entries[item.key] = _ManagedEntry(originHash: hash, status: status);
        }
      }
      return _ManagedState(
        bundleRevision: raw['bundle_revision']?.toString() ?? '',
        entries: entries,
      );
    } on Object {
      return _ManagedState.empty();
    }
  }

  void _writeProgress(_ManagedState state) {
    state.bundleRevision = '';
    _writeState(state);
  }

  void _writeState(_ManagedState state) {
    final skillsJson = <String, dynamic>{};
    for (final id in state.entries.keys.toList()..sort()) {
      final entry = state.entries[id]!;
      skillsJson[id] = {
        'origin_hash': entry.originHash,
        'status': entry.status.name,
      };
    }
    final content = jsonEncode({
      'schema_version': 1,
      'bundle_revision': state.bundleRevision,
      'skills': skillsJson,
    });
    _home.writeSecretBytesSync(statePath, utf8.encode(content));
  }

  static String _directoryHash(Map<String, List<int>> files) {
    final bytes = BytesBuilder(copy: false);
    for (final path in files.keys.toList()..sort()) {
      bytes
        ..add(utf8.encode(path))
        ..addByte(0)
        ..add(files[path]!)
        ..addByte(0);
    }
    return sha256.convert(bytes.takeBytes()).toString();
  }
}

enum _ManagedStatus { managed, userDeleted }

class _ManagedEntry {
  const _ManagedEntry({required this.originHash, required this.status});

  final String originHash;
  final _ManagedStatus status;
}

class _ManagedState {
  _ManagedState({required this.bundleRevision, required this.entries});

  factory _ManagedState.empty() =>
      _ManagedState(bundleRevision: '', entries: <String, _ManagedEntry>{});

  String bundleRevision;
  final Map<String, _ManagedEntry> entries;
}
