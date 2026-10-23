import 'dart:io';

import 'package:sanad_agent/core/models/user_attachment.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';

/// Owns the local daemon's authenticated media streaming routes:
/// `GET /media/attachment/<media_id>` and `GET /media/view-image/<media_id>`.
///
/// Dependencies are explicit constructor inputs; this owner never resolves a
/// runtime owner through the service locator.
class LocalMediaStreamHandler {
  /// Session history the media projections resolve their bytes through.
  final ViewImageMediaHistoryLoader? viewImageMediaHistoryLoader;

  final String Function() _localDeviceId;
  final AttachmentStore Function() _attachmentStore;

  LocalMediaStreamHandler({
    required String Function() localDeviceId,
    required AttachmentStore Function() attachmentStore,
    this.viewImageMediaHistoryLoader,
  }) : _localDeviceId = localDeviceId,
       _attachmentStore = attachmentStore;

  /// Returns whether a media route answered the request.
  Future<bool> handle(HttpRequest request) async {
    if (request.uri.pathSegments.length == 3 &&
        request.uri.pathSegments[0] == 'media' &&
        request.uri.pathSegments[1] == 'view-image') {
      await _handleViewImageMedia(request, request.uri.pathSegments[2]);
      return true;
    }
    if (request.uri.pathSegments.length == 3 &&
        request.uri.pathSegments[0] == 'media' &&
        request.uri.pathSegments[1] == 'attachment') {
      await _handleAttachmentMedia(request, request.uri.pathSegments[2]);
      return true;
    }
    return false;
  }

  Future<void> _handleAttachmentMedia(
    HttpRequest request,
    String mediaId,
  ) async {
    final hasBody =
        request.headers.contentLength > 0 ||
        request.headers.value(HttpHeaders.transferEncodingHeader) != null;
    final query = request.uri.queryParameters;
    final sessionId = query['session_id']?.trim();
    final deviceId = query['device_id']?.trim();
    final validMediaId = RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(mediaId);
    if (request.method != 'GET' ||
        hasBody ||
        query.length != 2 ||
        sessionId == null ||
        sessionId.isEmpty ||
        deviceId == null ||
        deviceId.isEmpty ||
        !validMediaId) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    if (deviceId != _localDeviceId()) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }

    UserAttachment? attachment;
    try {
      for (final message
          in viewImageMediaHistoryLoader?.call(sessionId) ?? const []) {
        for (final candidate in message.attachments) {
          if (candidate.mediaId == mediaId) {
            attachment = candidate;
            break;
          }
        }
        if (attachment != null) break;
      }
    } on Object {
      attachment = null;
    }
    if (attachment == null ||
        attachment.status != UserAttachmentStatus.available ||
        attachment.agentLocalReference.trim().isEmpty) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    List<int>? bytes;
    try {
      bytes = await _attachmentStore().readVerifiedAttachment(attachment);
    } on Object {
      bytes = null;
    }
    if (bytes == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final disposition = attachment.kind == UserAttachmentKind.image
        ? 'inline'
        : 'attachment';
    request.response.headers
      ..contentType = ContentType.parse(attachment.mimeType)
      ..set(HttpHeaders.cacheControlHeader, 'private, no-store')
      ..set('X-Content-Type-Options', 'nosniff')
      ..set(
        'content-disposition',
        '$disposition; filename="${_safeAttachmentDownloadName(attachment.safeName)}"',
      )
      ..contentLength = bytes.length;
    request.response.add(bytes);
    await request.response.close();
  }

  String _safeAttachmentDownloadName(String safeName) {
    final extension = RegExp(
      r'\.([A-Za-z0-9]{1,10})$',
    ).firstMatch(safeName)?.group(1);
    return extension == null
        ? 'attachment'
        : 'attachment.${extension.toLowerCase()}';
  }

  Future<void> _handleViewImageMedia(
    HttpRequest request,
    String mediaId,
  ) async {
    final hasBody =
        request.headers.contentLength > 0 ||
        request.headers.value(HttpHeaders.transferEncodingHeader) != null;
    final query = request.uri.queryParameters;
    final sessionId = query['session_id']?.trim();
    final deviceId = query['device_id']?.trim();
    final validMediaId = RegExp(r'^[a-f0-9]{64}$').hasMatch(mediaId);
    if (request.method != 'GET' ||
        hasBody ||
        query.length != 2 ||
        sessionId == null ||
        sessionId.isEmpty ||
        deviceId == null ||
        deviceId.isEmpty ||
        !validMediaId) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    if (deviceId != _localDeviceId()) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      return;
    }

    CanonicalViewImageMedia? media;
    try {
      final loader = viewImageMediaHistoryLoader;
      if (loader != null) {
        media = ViewImageMediaProjection.resolve(
          sessionId: sessionId,
          mediaId: mediaId,
          messages: loader(sessionId),
        );
      }
    } on Object {
      media = null;
    }
    final bytes = media?.bytes;
    if (media == null ||
        media.availability != CanonicalMediaAvailability.available ||
        bytes == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    var start = 0;
    var end = bytes.length - 1;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null) {
      final match = RegExp(r'^bytes=([0-9]+)-([0-9]*)$').firstMatch(range);
      final requestedStart = match == null
          ? null
          : int.tryParse(match.group(1)!);
      final requestedEnd = match == null || match.group(2)!.isEmpty
          ? bytes.length - 1
          : int.tryParse(match.group(2)!);
      if (requestedStart == null ||
          requestedEnd == null ||
          requestedStart < 0 ||
          requestedStart >= bytes.length ||
          requestedEnd < requestedStart) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */${bytes.length}',
        );
        await request.response.close();
        return;
      }
      start = requestedStart;
      end = requestedEnd.clamp(start, bytes.length - 1);
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${bytes.length}',
      );
    }

    request.response.headers
      ..contentType = ContentType.parse(media.mimeType)
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.cacheControlHeader, 'private, no-store')
      ..set('X-Content-Type-Options', 'nosniff')
      ..set('content-disposition', 'inline; filename="${media.safeName}"')
      ..contentLength = end - start + 1;
    request.response.add(bytes.sublist(start, end + 1));
    await request.response.close();
  }
}
