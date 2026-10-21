import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'package:sanad_client/infrastructure/socket/hosted_conversation_media.dart';
import 'package:sanad_client/infrastructure/socket/socket_connection_controller.dart';

/// Owns hosted attachment admission and hosted conversation media fetching over
/// the cloud socket relay.
class HostedMediaRelayClient {
  final SocketConnectionController _connection;
  final _attachmentRelayController = StreamController<Map<String, dynamic>>.broadcast();
  bool _isDisposed = false;

  HostedMediaRelayClient({
    required SocketConnectionController connection,
  }) : _connection = connection;

  SocketConnectionController get connection => _connection;

  void handleRelayEvent(String event, dynamic data) {
    if (_isDisposed) return;
    final payload = _asMap(data);
    if (payload != null) {
      _attachmentRelayController.add({...payload, '_event': event});
    }
  }

  Future<List<String>> admitHostedAttachments({
    required String deviceId,
    required String sessionId,
    required String requestId,
    required List<Map<String, dynamic>> attachments,
  }) async {
    if (!_connection.isConnected || _connection.isLocalTransport) {
      throw StateError('Hosted attachment relay is unavailable.');
    }
    final decoded = attachments
        .map((attachment) {
          final encoded = attachment['data_base64'];
          if (encoded is! String) {
            throw StateError('Attachment bytes are unavailable.');
          }
          return base64Decode(encoded);
        })
        .toList(growable: false);
    final turnTotalBytes = decoded.fold<int>(
      0,
      (total, bytes) => total + bytes.length,
    );
    if (attachments.isEmpty ||
        attachments.length > 4 ||
        decoded.any((bytes) => bytes.length > 5 * 1024 * 1024) ||
        turnTotalBytes > 20 * 1024 * 1024) {
      throw StateError('Attachment limits exceeded.');
    }
    try {
      final results = await Future.wait([
        for (var fileIndex = 0; fileIndex < attachments.length; fileIndex++)
          _admitHostedAttachment(
            deviceId: deviceId,
            sessionId: sessionId,
            requestId: requestId,
            source: attachments[fileIndex],
            bytes: decoded[fileIndex],
            fileIndex: fileIndex,
            turnFileCount: attachments.length,
            turnTotalBytes: turnTotalBytes,
          ),
      ], eagerError: true);
      return List.unmodifiable(results);
    } on Object {
      for (var fileIndex = 0; fileIndex < attachments.length; fileIndex++) {
        _connection.socket?.emit('attachment_upload_cancel', {
          'version': 'v1',
          'upload_id': '${requestId}_$fileIndex',
        });
      }
      rethrow;
    }
  }

  Future<String> _admitHostedAttachment({
    required String deviceId,
    required String sessionId,
    required String requestId,
    required Map<String, dynamic> source,
    required Uint8List bytes,
    required int fileIndex,
    required int turnFileCount,
    required int turnTotalBytes,
  }) async {
    final uploadId = '${requestId}_$fileIndex';
    try {
      final started = _waitForUpload(
        uploadId,
        (event) => event['state'] == 'started',
      );
      final chunkCount = (bytes.length + 256 * 1024 - 1) ~/ (256 * 1024);
      _connection.socket!.emit('attachment_upload_start', {
        'version': 'v1',
        'upload_id': uploadId,
        'device_id': deviceId,
        'session_id': sessionId,
        'request_id': requestId,
        'name': source['name'],
        // Composer admission has no MIME hint; the Agent inspects magic bytes.
        'mime_type': source['mime_type'] ?? 'application/octet-stream',
        'size_bytes': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
        'chunk_count': chunkCount == 0 ? 1 : chunkCount,
        'file_index': fileIndex,
        'turn_file_count': turnFileCount,
        'turn_total_bytes': turnTotalBytes,
      });
      await started;
      if (bytes.isEmpty) {
        await _emitHostedChunk(uploadId, 0, Uint8List(0));
      } else {
        for (var offset = 0, index = 0; offset < bytes.length; offset += 256 * 1024, index++) {
          final end = (offset + 256 * 1024).clamp(0, bytes.length);
          await _emitHostedChunk(
            uploadId,
            index,
            Uint8List.sublistView(bytes, offset, end),
          );
        }
      }
      final terminalResult = _waitForUpload(
        uploadId,
        (event) => event['state'] == 'terminal',
      );
      _connection.socket!.emit('attachment_upload_commit', {
        'version': 'v1',
        'upload_id': uploadId,
      });
      final terminal = await terminalResult;
      final attachmentId = terminal['attachment_id'];
      if (terminal['outcome'] != 'accepted' || attachmentId is! String) {
        throw StateError('Attachment admission failed.');
      }
      return attachmentId;
    } on Object {
      _connection.socket?.emit('attachment_upload_cancel', {
        'version': 'v1',
        'upload_id': uploadId,
      });
      rethrow;
    }
  }

  Future<void> _emitHostedChunk(
    String uploadId,
    int index,
    Uint8List bytes,
  ) async {
    final acknowledged = _waitForUpload(
      uploadId,
      (event) => event['state'] == 'chunk' && event['index'] == index,
    );
    _connection.socket!.emit('attachment_upload_chunk', {
      'version': 'v1',
      'upload_id': uploadId,
      'index': index,
      'sha256': sha256.convert(bytes).toString(),
      'data': bytes,
    });
    await acknowledged;
  }

  Future<Map<String, dynamic>> _waitForUpload(
    String uploadId,
    bool Function(Map<String, dynamic>) accepted,
  ) async {
    // A terminal rejection may arrive while any phase (start, chunk) is still
    // waiting; it ends the upload at once instead of waiting for the timeout.
    bool rejected(Map<String, dynamic> event) =>
        event['_event'] == 'attachment_upload_error' ||
        (event['state'] == 'terminal' && event['outcome'] != 'accepted');
    final event = await _attachmentRelayController.stream
        .firstWhere(
          (event) => event['upload_id'] == uploadId && (rejected(event) || accepted(event)),
        )
        .timeout(const Duration(seconds: 30));
    if (rejected(event)) {
      throw StateError('Attachment admission failed: ${event['error_code']}');
    }
    return event;
  }

  Future<HostedConversationMedia> fetchHostedConversationMedia({
    required String deviceId,
    required String sessionId,
    required String mediaId,
    required String purpose,
    void Function(void Function())? registerCancel,
  }) async {
    if (!_connection.isConnected || _connection.isLocalTransport) {
      throw StateError('Hosted media relay is unavailable.');
    }
    final routeId = const Uuid().v4();
    final completer = Completer<HostedConversationMedia>();
    var routeCancelled = false;
    registerCancel?.call(() {
      if (completer.isCompleted) return;
      routeCancelled = true;
      _connection.socket?.emit('conversation_media_cancel', {
        'version': 'v1',
        'route_id': routeId,
      });
      completer.completeError(StateError('Media fetch cancelled.'));
    });
    final chunks = <int, Uint8List>{};
    String? mimeType;
    String? fullHash;
    int? sizeBytes;
    int? chunkCount;
    late final StreamSubscription<Map<String, dynamic>> subscription;
    subscription = _attachmentRelayController.stream.listen((event) {
      if (event['route_id'] != routeId || completer.isCompleted) return;
      try {
        switch (event['_event']) {
          case 'conversation_media_error':
            throw StateError('Media fetch failed: ${event['error_code']}');
          case 'conversation_media_start':
            if (event['session_id'] != sessionId ||
                event['size_bytes'] is! int ||
                event['sha256'] is! String ||
                event['mime_type'] is! String ||
                event['chunk_count'] is! int) {
              throw const FormatException('Invalid media metadata.');
            }
            sizeBytes = event['size_bytes'] as int;
            fullHash = event['sha256'] as String;
            mimeType = event['mime_type'] as String;
            chunkCount = event['chunk_count'] as int;
            if (sizeBytes! < 0 || sizeBytes! > 5 * 1024 * 1024) {
              throw const FormatException('Invalid media size.');
            }
            break;
          case 'conversation_media_chunk':
            final index = event['index'];
            final data = event['data'];
            if (chunkCount == null || index is! int || index != chunks.length || data is! List<int>) {
              throw const FormatException('Invalid media sequence.');
            }
            final bytes = Uint8List.fromList(data);
            if (sha256.convert(bytes).toString() != event['sha256']) {
              throw const FormatException('Invalid media chunk hash.');
            }
            chunks[index] = bytes;
            break;
          case 'conversation_media_complete':
            if (chunkCount == null || chunks.length != chunkCount) {
              throw const FormatException('Incomplete media payload.');
            }
            final builder = BytesBuilder(copy: false);
            for (var index = 0; index < chunkCount!; index++) {
              builder.add(chunks[index]!);
            }
            final bytes = builder.takeBytes();
            if (bytes.length != sizeBytes || sha256.convert(bytes).toString() != fullHash) {
              throw const FormatException('Invalid media payload.');
            }
            completer.complete(
              HostedConversationMedia(bytes: bytes, mimeType: mimeType!),
            );
        }
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    _connection.socket!.emit('conversation_media_fetch', {
      'version': 'v1',
      'route_id': routeId,
      'device_id': deviceId,
      'session_id': sessionId,
      'request_id': routeId,
      'media_id': mediaId,
      'purpose': purpose,
    });
    try {
      return await completer.future.timeout(const Duration(seconds: 30));
    } on Object {
      if (!routeCancelled) {
        _connection.socket?.emit('conversation_media_cancel', {
          'version': 'v1',
          'route_id': routeId,
        });
      }
      rethrow;
    } finally {
      await subscription.cancel();
    }
  }

  void dispose() {
    _isDisposed = true;
    unawaited(_attachmentRelayController.close());
  }

  static Map<String, dynamic>? _asMap(dynamic data) {
    if (data is Map<String, dynamic>) {
      return data;
    }
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    return null;
  }
}
