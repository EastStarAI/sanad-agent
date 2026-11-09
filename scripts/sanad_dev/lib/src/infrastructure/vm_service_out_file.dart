import 'dart:io';

import 'package:path/path.dart' as p;

import 'secure_runtime_file.dart';

/// Maximum age of a recorder VM-service handoff file.
///
/// The launcher deletes the file before every client launch, so a live file is
/// always written by the process that currently owns the port. The age bound is
/// a second fail-closed guard against a leftover file from a crashed launcher.
const vmServiceOutFileMaxAge = Duration(hours: 12);

/// One owner-only handoff path per client VM service port.
///
/// It lives under the runtime Home so it follows the same isolation boundary as
/// the journals, and it is never inside the repository.
String vmServiceOutFilePath({
  required String sanadHome,
  required int vmServicePort,
}) => p.join(sanadHome, 'dev', 'vm-service-$vmServicePort.uri');

/// Creates the owner-only placeholder the Flutter tool truncates.
///
/// Flutter's documented `--vmservice-out-file` handoff writes the authenticated
/// DDS websocket URI after the app is ready; because the file already exists at
/// 0600, that write truncates the same inode and keeps the owner-only mode. A
/// previous launch's file is removed first, so discovery can never accept a
/// foreign or stale recording. Returns null when the path cannot be prepared,
/// in which case the launch simply keeps the documented fallback discovery.
Future<String?> prepareVmServiceOutFile({
  required String sanadHome,
  required int vmServicePort,
}) async {
  try {
    final path = vmServiceOutFilePath(
      sanadHome: sanadHome,
      vmServicePort: vmServicePort,
    );
    final directory = Directory(p.dirname(path));
    await directory.create(recursive: true);
    await restrictRuntimePath(directory.path, directory: true);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.link) return null;
    if (type == FileSystemEntityType.file) await File(path).delete();
    final file = await File(path).create(exclusive: true);
    await restrictRuntimePath(file.path);
    return file.path;
  } on Object {
    return null;
  }
}

/// Reads the authenticated DDS auth code recorded for one live client.
///
/// Every acceptance condition fails closed: the recording must be named by the
/// live client's own argument vector, be a regular owner-only file inside this
/// Home, be fresh, and describe a loopback websocket URI on the exact expected
/// DDS port. A URI whose port differs from the expected bind port is rejected
/// instead of splicing an upstream token onto a different DDS endpoint.
Future<String?> readVmServiceAuthCodeFromOutFile({
  required String outFilePath,
  required int expectedPort,
  required Iterable<String> liveClientArguments,
  DateTime Function() now = DateTime.now,
}) async {
  try {
    if (!liveClientArguments.contains('--vmservice-out-file=$outFilePath')) {
      return null;
    }
    final type = await FileSystemEntity.type(outFilePath, followLinks: false);
    if (type != FileSystemEntityType.file) return null;
    final stat = await File(outFilePath).stat();
    if (!Platform.isWindows && (stat.mode & 0x1FF) != 0x180) return null;
    if (now().difference(stat.modified) > vmServiceOutFileMaxAge) return null;
    final raw = (await File(outFilePath).readAsString()).trim();
    if (raw.isEmpty || raw.length > 512) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'ws') return null;
    if (!_isLoopbackHost(uri.host)) return null;
    if (uri.port != expectedPort) return null;
    final segments = uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty) return null;
    final code = segments.first;
    if (!RegExp(r'^[A-Za-z0-9_\-=]{8,128}$').hasMatch(code)) return null;
    return code;
  } on Object {
    return null;
  }
}

/// Removes the handoff file once its client is stopped.
Future<void> removeVmServiceOutFile({
  required String sanadHome,
  required int vmServicePort,
}) async {
  try {
    final file = File(
      vmServiceOutFilePath(sanadHome: sanadHome, vmServicePort: vmServicePort),
    );
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.file) await file.delete();
  } on Object {
    // Cleanup is best effort; the next launch removes the file anyway.
  }
}

bool _isLoopbackHost(String host) =>
    host == '127.0.0.1' || host == 'localhost' || host == '::1';
