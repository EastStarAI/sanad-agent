import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'secure_runtime_file.dart';

const componentJournalSegmentBytes = 2 * 1024 * 1024;
const componentJournalRetainedSegments = 4;
const componentJournalMaxRecordBytes = 64 * 1024;

enum ComponentOutputSource { stdout, stderr, system }

String componentJournalDirectory(String sanadHome, int agentPort) =>
    '$sanadHome${Platform.pathSeparator}dev${Platform.pathSeparator}journals${Platform.pathSeparator}$agentPort';

String componentJournalKey({required String component, int? vmServicePort}) {
  final safeComponent = component.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  return vmServicePort == null
      ? safeComponent
      : '$safeComponent-$vmServicePort';
}

class ComponentJournalWriter {
  ComponentJournalWriter({
    required this.sanadHome,
    required this.agentPort,
    required this.component,
    required this.launcherId,
    required this.runtimeNonce,
    this.vmServicePort,
    this.maxSegmentBytes = componentJournalSegmentBytes,
    this.retainedSegments = componentJournalRetainedSegments,
  });

  final String sanadHome;
  final int agentPort;
  final String component;
  final String launcherId;
  final String runtimeNonce;
  final int? vmServicePort;
  final int maxSegmentBytes;
  final int retainedSegments;

  IOSink? _sink;
  int _segmentBytes = 0;
  int _sequence = 0;
  Future<void> _pending = Future.value();
  bool _closed = false;

  String get key =>
      componentJournalKey(component: component, vmServicePort: vmServicePort);

  Future<void> open({String reason = 'process started'}) => _enqueue(() async {
    await _openSegment();
    await _appendRecord(
      ComponentOutputSource.system,
      utf8.encode(
        '--- $component generation launcher=$launcherId nonce=$runtimeNonce: $reason ---\n',
      ),
    );
  });

  Future<void> add(ComponentOutputSource source, List<int> bytes) {
    if (bytes.isEmpty) return Future.value();
    return _enqueue(() async {
      if (_sink == null) await _openSegment();
      for (
        var offset = 0;
        offset < bytes.length;
        offset += componentJournalMaxRecordBytes
      ) {
        final end = min(offset + componentJournalMaxRecordBytes, bytes.length);
        await _appendRecord(
          source,
          redactComponentOutput(bytes.sublist(offset, end)),
        );
      }
    });
  }

  Future<void> close({int? exitCode}) => _enqueue(() async {
    if (_closed) return;
    if (exitCode != null) {
      await _appendRecord(
        ComponentOutputSource.system,
        utf8.encode('--- $component exited with code $exitCode ---\n'),
      );
    }
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    _closed = true;
  });

  Future<void> _appendRecord(
    ComponentOutputSource source,
    List<int> bytes,
  ) async {
    if (_closed) return;
    final encoded =
        '${jsonEncode({'sequence': _sequence++, 'time': DateTime.now().toUtc().toIso8601String(), 'source': source.name, 'bytes': base64Encode(bytes)})}\n';
    final encodedBytes = utf8.encode(encoded);
    if (_segmentBytes > 0 &&
        _segmentBytes + encodedBytes.length > maxSegmentBytes) {
      await _sink?.flush();
      await _sink?.close();
      _sink = null;
      await _openSegment();
    }
    _sink!.add(encodedBytes);
    await _sink!.flush();
    _segmentBytes += encodedBytes.length;
  }

  Future<void> _openSegment() async {
    final directory = Directory(
      componentJournalDirectory(sanadHome, agentPort),
    );
    await secureRuntimeDirectory(sanadHome, directory.path);
    final files = await componentJournalSegments(
      sanadHome: sanadHome,
      agentPort: agentPort,
      key: key,
    );
    final next = files.isEmpty ? 1 : _segmentNumber(files.last) + 1;
    final segment = File(
      '${directory.path}${Platform.pathSeparator}$key.${next.toString().padLeft(8, '0')}.journal',
    );
    await secureRuntimeAppendFile(sanadHome, segment.path);
    _sink = segment.openWrite(mode: FileMode.writeOnlyAppend);
    _segmentBytes = await segment.length();
    final retained = [...files, segment];
    while (retained.length > retainedSegments) {
      final stale = retained.removeAt(0);
      if (await stale.exists()) await stale.delete();
    }
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    _pending = _pending.then((_) => operation());
    return _pending;
  }
}

class ComponentProcessJournal {
  ComponentProcessJournal._(this.writer, this._subscriptions, this._completion);

  final ComponentJournalWriter writer;
  final List<StreamSubscription<List<int>>> _subscriptions;
  final Future<void> _completion;

  static Future<ComponentProcessJournal> attach({
    required Process process,
    required ComponentJournalWriter writer,
    bool mirrorStdout = false,
    bool mirrorStderr = false,
    void Function(ComponentOutputSource source, List<int> bytes)? onBytes,
  }) async {
    await writer.open();
    final subscriptions = <StreamSubscription<List<int>>>[
      process.stdout.listen((bytes) {
        unawaited(writer.add(ComponentOutputSource.stdout, bytes));
        onBytes?.call(ComponentOutputSource.stdout, bytes);
        if (mirrorStdout) stdout.add(bytes);
      }),
      process.stderr.listen((bytes) {
        unawaited(writer.add(ComponentOutputSource.stderr, bytes));
        onBytes?.call(ComponentOutputSource.stderr, bytes);
        if (mirrorStderr) stderr.add(bytes);
      }),
    ];
    final exitCode = process.exitCode;
    final outputDone = Future.wait<void>(
      subscriptions.map((subscription) => subscription.asFuture<void>()),
    );
    final completion = Future.wait<Object?>([
      exitCode,
      outputDone,
    ]).then((values) => writer.close(exitCode: values.first! as int));
    unawaited(completion);
    return ComponentProcessJournal._(writer, subscriptions, completion);
  }

  Future<void> cancel() async {
    try {
      await _completion.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      for (final subscription in _subscriptions) {
        await subscription.cancel();
      }
    }
  }
}

List<int> redactComponentOutput(List<int> bytes) {
  var text = utf8.decode(bytes, allowMalformed: true);
  text = text.replaceAllMapped(
    RegExp(r'(authorization\s*[:=]\s*bearer\s+)[^\s]+', caseSensitive: false),
    (match) => '${match.group(1)}[REDACTED]',
  );
  text = text.replaceAllMapped(
    RegExp(
      r'''((?:api[_-]?key|access[_-]?token|refresh[_-]?token|password)\s*[:=]\s*["']?)[^\s,"']+''',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}[REDACTED]',
  );
  return utf8.encode(text);
}

Future<void> cleanupStaleComponentJournals(
  String sanadHome, {
  Duration maxAge = const Duration(days: 14),
  DateTime? now,
}) async {
  final root = Directory(
    '$sanadHome${Platform.pathSeparator}dev${Platform.pathSeparator}journals',
  );
  if (!await root.exists()) return;
  final cutoff = (now ?? DateTime.now()).subtract(maxAge);
  await for (final entity in root.list(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.journal')) continue;
    if ((await entity.lastModified()).isBefore(cutoff)) await entity.delete();
  }
  final directories = await root
      .list(recursive: true)
      .where((entity) => entity is Directory)
      .cast<Directory>()
      .toList();
  directories.sort(
    (left, right) => right.path.length.compareTo(left.path.length),
  );
  for (final directory in directories) {
    if (await directory.list().isEmpty) await directory.delete();
  }
}

Future<List<File>> componentJournalSegments({
  required String sanadHome,
  required int agentPort,
  required String key,
}) async {
  final directory = Directory(componentJournalDirectory(sanadHome, agentPort));
  if (!await directory.exists()) return const [];
  final files = await directory
      .list()
      .where((entity) => entity is File && entity.path.endsWith('.journal'))
      .cast<File>()
      .where((file) => file.uri.pathSegments.last.startsWith('$key.'))
      .toList();
  files.sort((left, right) => left.path.compareTo(right.path));
  return files;
}

class ComponentJournalSnapshot {
  const ComponentJournalSnapshot(this.bytes, this.offsets);
  final List<int> bytes;
  final Map<String, int> offsets;
}

Future<ComponentJournalSnapshot> readComponentJournalSnapshot({
  required String sanadHome,
  required int agentPort,
  required String key,
}) async {
  final output = BytesBuilder(copy: false);
  final offsets = <String, int>{};
  for (final file in await componentJournalSegments(
    sanadHome: sanadHome,
    agentPort: agentPort,
    key: key,
  )) {
    final length = await file.length();
    offsets[file.path] = length;
    await for (final line
        in file
            .openRead(0, length)
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      final record = _decodeRecord(line);
      if (record != null) output.add(record.bytes);
    }
  }
  return ComponentJournalSnapshot(
    output.takeBytes(),
    Map.unmodifiable(offsets),
  );
}

Future<List<int>> readComponentJournalBytes({
  required String sanadHome,
  required int agentPort,
  required String key,
}) async => (await readComponentJournalSnapshot(
  sanadHome: sanadHome,
  agentPort: agentPort,
  key: key,
)).bytes;

Future<List<String>> readComponentJournalTail({
  required String sanadHome,
  required int agentPort,
  required String key,
  int? lines,
}) async {
  final text = utf8.decode(
    await readComponentJournalBytes(
      sanadHome: sanadHome,
      agentPort: agentPort,
      key: key,
    ),
    allowMalformed: true,
  );
  final values = const LineSplitter().convert(text);
  if (lines == null || lines <= 0 || values.length <= lines) return values;
  return values.sublist(values.length - lines);
}

Stream<List<int>> followComponentJournal({
  required String sanadHome,
  required int agentPort,
  required String key,
  Map<String, int> initialOffsets = const {},
  Future<bool> Function()? shouldContinue,
  Duration pollInterval = const Duration(milliseconds: 100),
}) async* {
  final offsets = <String, int>{...initialOffsets};
  while (shouldContinue == null || await shouldContinue()) {
    final segments = await componentJournalSegments(
      sanadHome: sanadHome,
      agentPort: agentPort,
      key: key,
    );
    for (final file in segments) {
      var offset = offsets[file.path] ?? 0;
      final length = await file.length();
      if (offset > length) offset = 0;
      if (length > offset) {
        final chunk = await file
            .openRead(offset, length)
            .fold<BytesBuilder>(
              BytesBuilder(copy: false),
              (builder, bytes) => builder..add(bytes),
            );
        final raw = utf8.decode(chunk.takeBytes(), allowMalformed: true);
        var consumed = 0;
        for (final match in RegExp(r'.*\n').allMatches(raw)) {
          consumed += utf8.encode(match.group(0)!).length;
          final record = _decodeRecord(match.group(0)!.trimRight());
          if (record != null) yield record.bytes;
        }
        offsets[file.path] = offset + consumed;
      }
    }
    final activePaths = segments.map((file) => file.path).toSet();
    offsets.removeWhere((path, _) => !activePaths.contains(path));
    await Future<void>.delayed(pollInterval);
  }
}

class _JournalRecord {
  const _JournalRecord(this.source, this.bytes);
  final ComponentOutputSource source;
  final List<int> bytes;
}

_JournalRecord? _decodeRecord(String line) {
  try {
    final value = jsonDecode(line);
    if (value is! Map) return null;
    final source = ComponentOutputSource.values.byName(
      value['source'] as String,
    );
    return _JournalRecord(source, base64Decode(value['bytes'] as String));
  } on Object {
    return null;
  }
}

int _segmentNumber(File file) {
  final name = file.uri.pathSegments.last;
  final pieces = name.split('.');
  return pieces.length >= 3 ? int.tryParse(pieces[pieces.length - 2]) ?? 0 : 0;
}
