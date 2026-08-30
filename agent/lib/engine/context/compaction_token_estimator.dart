import 'dart:convert';

import 'package:sanad_agent/core/models/message.dart';

/// Conservative token estimator for compaction preflight (Plan 53c C0).
///
/// Text uses a fixed chars-per-token heuristic. Media payloads (data URIs,
/// long base64 blobs, or declared `media_bytes`) use byte-based accounting
/// instead of treating encoded media as ordinary text.
abstract final class CompactionTokenEstimator {
  CompactionTokenEstimator._();

  static const int charsPerToken = 4;

  /// Conservative tokens per ~1 KiB of media payload (image/audio/file bytes).
  static const int tokensPerKiBMedia = 85;

  static final RegExp _dataUriPattern = RegExp(
    r'data:[^;]+;base64,([A-Za-z0-9+/=\s]+)',
    caseSensitive: false,
  );
  static final RegExp _longBase64Pattern = RegExp(
    r'^[A-Za-z0-9+/=\s]{500,}$',
  );

  static int estimateText(String? text) {
    if (text == null || text.isEmpty) {
      return 0;
    }
    return (text.length / charsPerToken).ceil();
  }

  static int estimateMessage(Message message) {
    var total = 0;
    final content = message.content;
    if (content != null && content.isNotEmpty) {
      if (!_looksLikeMediaPayload(content)) {
        total += estimateText(content);
      }
    }
    total += estimateText(message.thought);
    total += estimateText(message.reasoning);
    if (message.toolCalls != null) {
      for (final call in message.toolCalls!) {
        total += estimateText(call.name);
        total += estimateText(jsonEncode(call.arguments));
      }
    }
    if (message.providerState != null) {
      total += estimateText(jsonEncode(message.providerState!.toJson()));
    }
    return total;
  }

  static int estimateMessages(Iterable<Message> messages) {
    return messages.fold(0, (sum, message) => sum + estimateMessage(message));
  }

  static int estimateToolSchemas(Iterable<Map<String, dynamic>> schemas) {
    return schemas.fold(
      0,
      (sum, schema) => sum + estimateText(jsonEncode(schema)),
    );
  }

  /// Byte-aware media accounting; never treats base64 as chars/4 text.
  static int estimateMediaTokens(Iterable<Message> messages) {
    var total = 0;
    for (final message in messages) {
      final metadata = message.metadata;
      final mediaBytes = metadata?['media_bytes'];
      if (mediaBytes is int && mediaBytes > 0) {
        total += _tokensForMediaBytes(mediaBytes);
        continue;
      }
      final content = message.content;
      if (content == null || content.isEmpty) {
        continue;
      }
      final fromDataUri = _dataUriPattern.firstMatch(content);
      if (fromDataUri != null) {
        final encoded = fromDataUri.group(1)!.replaceAll(RegExp(r'\s'), '');
        total += _tokensForMediaBytes((encoded.length * 3) ~/ 4);
        continue;
      }
      if (_isEncodedMediaBlob(content)) {
        final encoded = content.replaceAll(RegExp(r'\s'), '');
        total += _tokensForMediaBytes((encoded.length * 3) ~/ 4);
      }
    }
    return total;
  }

  static bool _looksLikeMediaPayload(String content) {
    if (_dataUriPattern.hasMatch(content)) {
      return true;
    }
    return _isEncodedMediaBlob(content);
  }

  /// True only for data-URI payloads or long base64 that includes alphabet markers.
  /// Homogeneous filler text (e.g. repeated `x`) must stay on the text estimator.
  static bool _isEncodedMediaBlob(String content) {
    final trimmed = content.trim();
    if (!_longBase64Pattern.hasMatch(trimmed)) {
      return false;
    }
    return trimmed.contains('+') ||
        trimmed.contains('/') ||
        trimmed.endsWith('=');
  }

  static int _tokensForMediaBytes(int bytes) {
    if (bytes <= 0) {
      return 0;
    }
    return (bytes / 1024).ceil() * tokensPerKiBMedia;
  }
}
