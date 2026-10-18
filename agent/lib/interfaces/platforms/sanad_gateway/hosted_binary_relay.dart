import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

import '../../../core/models/message.dart';
import '../../../core/models/user_attachment.dart';
import '../../../evolution/attachments/attachment_store.dart';
import 'protocol/canonical_events.dart';

final class HostedBinaryRelay {
  HostedBinaryRelay({
    required AttachmentStore store,
    required List<Message> Function(String sessionId) historyLoader,
  }) : _store = store,
       _historyLoader = historyLoader;

  static const _version = 'v1';
  static const _chunkBytes = 256 * 1024;

  final AttachmentStore _store;
  final List<Message> Function(String sessionId) _historyLoader;
  final Map<String, _HostedUpload> _uploads = {};
  final Set<String> _activeMediaRoutes = {};
  final Set<String> _cancelledMediaRoutes = {};

  void bind(io.Socket socket) {
    socket.on('attachment_upload_start', (data) => _start(socket, data));
    socket.on('attachment_upload_chunk', (data) => _chunk(socket, data));
    socket.on('attachment_upload_commit', (data) => _commit(socket, data));
    socket.on('attachment_upload_cancel', (data) => _cancel(data));
    socket.on('conversation_media_fetch', (data) => _media(socket, data));
    socket.on('conversation_media_cancel', _cancelMedia);
    socket.on('disconnect', (_) => _disconnect());
  }

  Future<void> _disconnect() async {
    final active = _uploads.values.toList(growable: false);
    _uploads.clear();
    _cancelledMediaRoutes.addAll(_activeMediaRoutes);
    await Future.wait([
      for (final state in active) _store.cancel(state.upload),
    ]);
  }

  Future<void> _start(io.Socket socket, Object? raw) async {
    final data = _map(raw);
    final uploadId = _id(data?['upload_id']);
    final sessionId = _id(data?['session_id']);
    final requestId = _id(data?['request_id']);
    final name = data?['name'];
    final mime = data?['mime_type'];
    final size = data?['size_bytes'];
    final hash = data?['sha256'];
    final chunkCount = data?['chunk_count'];
    final fileIndex = data?['file_index'];
    final turnFileCount = data?['turn_file_count'];
    final turnTotalBytes = data?['turn_total_bytes'];
    final expectedChunkCount = size is int
        ? ((size + _chunkBytes - 1) ~/ _chunkBytes).clamp(1, 20)
        : null;
    if (!_base(data) ||
        uploadId == null ||
        sessionId == null ||
        requestId == null ||
        name is! String ||
        mime is! String ||
        size is! int ||
        size < 0 ||
        size > UserAttachmentPolicy.maxFileBytes ||
        hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        chunkCount is! int ||
        chunkCount != expectedChunkCount ||
        fileIndex is! int ||
        fileIndex < 0 ||
        turnFileCount is! int ||
        turnFileCount < 1 ||
        turnFileCount > UserAttachmentPolicy.maxFilesPerMessage ||
        fileIndex >= turnFileCount ||
        turnTotalBytes is! int ||
        turnTotalBytes < size ||
        turnTotalBytes > UserAttachmentPolicy.maxTotalBytesPerMessage ||
        _uploads.containsKey(uploadId)) {
      _result(socket, uploadId ?? '', 'rejected', error: 'invalid_request');
      return;
    }
    try {
      final upload = await _store.create(
        fileName: name,
        declaredMime: mime,
        expectedSize: size,
        expectedSha256: hash,
      );
      _uploads[uploadId] = _HostedUpload(
        upload: upload,
        sessionId: sessionId,
        requestId: requestId,
        chunkCount: chunkCount,
      );
    } on Object {
      _result(socket, uploadId, 'rejected', error: 'unavailable');
    }
  }

  Future<void> _chunk(io.Socket socket, Object? raw) async {
    final data = _map(raw);
    final uploadId = _id(data?['upload_id']);
    final bytes = data?['data'];
    final index = data?['index'];
    final hash = data?['sha256'];
    final state = uploadId == null ? null : _uploads[uploadId];
    if (!_base(data) ||
        state == null ||
        bytes is! List<int> ||
        bytes.length > _chunkBytes ||
        index is! int ||
        index != state.nextIndex ||
        hash is! String ||
        sha256.convert(bytes).toString() != hash) {
      _result(socket, uploadId ?? '', 'rejected', error: 'invalid_request');
      return;
    }
    state.nextIndex++;
    state.pendingWrite = state.pendingWrite.then(
      (_) => _store.write(state.upload, bytes),
    );
    try {
      await state.pendingWrite;
    } on Object {
      if (identical(_uploads[uploadId], state)) {
        _uploads.remove(uploadId);
        await _store.cancel(state.upload);
        _result(socket, uploadId!, 'rejected', error: 'invalid_request');
      }
    }
  }

  Future<void> _commit(io.Socket socket, Object? raw) async {
    final data = _map(raw);
    final uploadId = _id(data?['upload_id']);
    final state = uploadId == null ? null : _uploads[uploadId];
    if (!_base(data) || state == null || state.nextIndex != state.chunkCount) {
      _result(socket, uploadId ?? '', 'rejected', error: 'invalid_request');
      return;
    }
    _uploads.remove(uploadId);
    try {
      await state.pendingWrite;
      final attachment = await _store.commit(
        state.upload,
        sessionId: state.sessionId,
        admissionId: state.requestId,
      );
      _result(socket, uploadId!, 'accepted', attachmentId: attachment.id);
    } on Object {
      await _store.cancel(state.upload);
      _result(socket, uploadId!, 'rejected', error: 'invalid_request');
    }
  }

  Future<void> _cancel(Object? raw) async {
    final uploadId = _id(_map(raw)?['upload_id']);
    final state = uploadId == null ? null : _uploads.remove(uploadId);
    if (state != null) await _store.cancel(state.upload);
  }

  void _cancelMedia(Object? raw) {
    final data = _map(raw);
    final routeId = _id(data?['route_id']);
    if (_base(data) &&
        routeId != null &&
        _activeMediaRoutes.contains(routeId)) {
      _cancelledMediaRoutes.add(routeId);
    }
  }

  Future<void> _media(io.Socket socket, Object? raw) async {
    final data = _map(raw);
    final routeId = _id(data?['route_id']);
    final sessionId = _id(data?['session_id']);
    final mediaId = _id(data?['media_id']);
    if (!_base(data) ||
        routeId == null ||
        sessionId == null ||
        mediaId == null) {
      _mediaError(socket, routeId ?? '', 'invalid_request');
      return;
    }
    _activeMediaRoutes.add(routeId);
    try {
      final media = await _resolveMedia(sessionId, mediaId);
      if (_cancelledMediaRoutes.contains(routeId)) return;
      if (media == null) {
        _mediaError(socket, routeId, 'unavailable');
        return;
      }
      if (media.bytes.length > UserAttachmentPolicy.maxFileBytes) {
        _mediaError(socket, routeId, 'size_limit');
        return;
      }
      final fullHash = sha256.convert(media.bytes).toString();
      final count = (media.bytes.length + _chunkBytes - 1) ~/ _chunkBytes;
      socket.emit('conversation_media_start', {
        'version': _version,
        'route_id': routeId,
        'session_id': sessionId,
        'size_bytes': media.bytes.length,
        'sha256': fullHash,
        'mime_type': media.mimeType,
        'chunk_count': count == 0 ? 1 : count,
      });
      await Future<void>.delayed(Duration.zero);
      if (_cancelledMediaRoutes.contains(routeId)) return;
      if (media.bytes.isEmpty) {
        socket.emit('conversation_media_chunk', {
          'version': _version,
          'route_id': routeId,
          'index': 0,
          'sha256': sha256.convert(const <int>[]).toString(),
          'data': Uint8List(0),
        });
      } else {
        for (
          var offset = 0, index = 0;
          offset < media.bytes.length;
          offset += _chunkBytes, index++
        ) {
          if (_cancelledMediaRoutes.contains(routeId)) return;
          final end = (offset + _chunkBytes).clamp(0, media.bytes.length);
          final chunk = Uint8List.sublistView(media.bytes, offset, end);
          socket.emit('conversation_media_chunk', {
            'version': _version,
            'route_id': routeId,
            'index': index,
            'sha256': sha256.convert(chunk).toString(),
            'data': chunk,
          });
          await Future<void>.delayed(Duration.zero);
        }
      }
      if (_cancelledMediaRoutes.contains(routeId)) return;
      socket.emit('conversation_media_complete', {
        'version': _version,
        'route_id': routeId,
      });
    } on Object {
      if (!_cancelledMediaRoutes.contains(routeId)) {
        _mediaError(socket, routeId, 'unavailable');
      }
    } finally {
      _activeMediaRoutes.remove(routeId);
      _cancelledMediaRoutes.remove(routeId);
    }
  }

  Future<_HostedMedia?> _resolveMedia(String sessionId, String mediaId) async {
    final history = _historyLoader(sessionId);
    for (final message in history) {
      for (final attachment in message.attachments) {
        if (attachment.mediaId != mediaId ||
            attachment.status != UserAttachmentStatus.available) {
          continue;
        }
        final bytes = await _store.readVerifiedAttachment(attachment);
        if (bytes == null) return null;
        return _HostedMedia(bytes, attachment.mimeType);
      }
    }
    final projected = ViewImageMediaProjection.resolve(
      sessionId: sessionId,
      mediaId: mediaId,
      messages: history,
    );
    final bytes = projected?.bytes;
    if (projected == null || bytes == null) return null;
    return _HostedMedia(Uint8List.fromList(bytes), projected.mimeType);
  }

  void _result(
    io.Socket socket,
    String uploadId,
    String outcome, {
    String? attachmentId,
    String? error,
  }) {
    socket.emit('attachment_upload_result', {
      'version': _version,
      'upload_id': uploadId,
      'outcome': outcome,
      'attachment_id': ?attachmentId,
      'error_code': ?error,
    });
  }

  void _mediaError(io.Socket socket, String routeId, String error) {
    socket.emit('conversation_media_error', {
      'version': _version,
      'route_id': routeId,
      'error_code': error,
    });
  }

  bool _base(Map<String, dynamic>? data) =>
      data != null && data['version'] == _version;

  static Map<String, dynamic>? _map(Object? value) => value is Map
      ? value.map((key, value) => MapEntry(key.toString(), value))
      : null;

  static String? _id(Object? value) {
    final id = value is String ? value.trim() : '';
    return id.isNotEmpty && id.length <= 128 ? id : null;
  }
}

final class _HostedUpload {
  _HostedUpload({
    required this.upload,
    required this.sessionId,
    required this.requestId,
    required this.chunkCount,
  });

  final AttachmentUpload upload;
  final String sessionId;
  final String requestId;
  final int chunkCount;
  int nextIndex = 0;
  Future<void> pendingWrite = Future.value();
}

final class _HostedMedia {
  const _HostedMedia(this.bytes, this.mimeType);

  final Uint8List bytes;
  final String mimeType;
}
