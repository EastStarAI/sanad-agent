import 'dart:convert';

import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/core/models/user_attachment.dart';

/// Conservative token estimator for compaction preflight (Plan 53c C0).
///
/// Text uses chars/4 for ASCII and an encoding-aware rule for other text. Model-facing image material is
/// priced from its dimensions (tiles) rather than from the compressed or
/// base64-encoded transport that carries it, because the transport size of an
/// image has no relationship to what the provider charges for it. Declared
/// `media_bytes` and other encoded payloads keep byte-based accounting.
abstract final class CompactionTokenEstimator {
  CompactionTokenEstimator._();

  static const int charsPerToken = 4;

  /// Wire keys carrying opaque provider-owned state (for example Codex
  /// `encrypted_content` reasoning replay). The provider prices that state
  /// under its own token model, so the text estimate never prices it; its
  /// actual cost is known only from a proven provider receipt.
  static const Set<String> opaqueWireKeys = {'encrypted_content'};

  /// Conservative tokens per ~1 KiB of media payload (image/audio/file bytes).
  static const int tokensPerKiBMedia = 85;

  /// Model-facing image accounting (tile class used by OpenAI-compatible
  /// vision pricing): a base charge per image plus a charge per 512x512 tile
  /// after the image is fitted to the model's maximum edge and its shortest
  /// side is scaled to the model's minimum short side.
  static const int imageBaseTokens = 85;
  static const int imageTileTokens = 170;
  static const int imageTileEdge = 512;
  static const int imageMaxEdge = 2048;
  static const int imageMinShortSide = 768;

  /// Upper bound for one image whose dimensions are not known: the largest
  /// supported model-facing image (2048x2048) at the high-detail tile grid.
  /// Used instead of transport bytes so encoding size can never inflate an
  /// estimate the provider would never charge.
  static const int maxImageTokensPerImage =
      imageBaseTokens + imageTileTokens * 16;

  static final RegExp _dataUriPattern = RegExp(
    r'data:[^;]+;base64,([A-Za-z0-9+/=\s]+)',
    caseSensitive: false,
  );
  static final RegExp _longBase64Pattern = RegExp(r'^[A-Za-z0-9+/=\s]{500,}$');

  /// Text estimate (Task 118b round 5). ASCII costs `ceil(chars / 4)`.
  /// Other text is priced from its encoding, because chars/4 counted Arabic,
  /// Cyrillic, Greek and Indic text at about half its real BPE cost: CJK,
  /// Hangul and Kana code points cost one token each, and every other code
  /// point costs its UTF-8 bytes, `ceil(bytes / 4)` in total. Accented Latin
  /// barely moves. A lone surrogate is priced as a 3-byte code point.
  static int estimateText(String? text) {
    if (text == null || text.isEmpty) {
      return 0;
    }
    var ascii = true;
    for (final unit in text.codeUnits) {
      if (unit > 0x7f) {
        ascii = false;
        break;
      }
    }
    if (ascii) {
      return (text.length / charsPerToken).ceil();
    }
    var dense = 0;
    var bytes = 0;
    for (final rune in text.runes) {
      if (_isTokenDense(rune)) {
        dense++;
      } else if (rune < 0x80) {
        bytes += 1;
      } else if (rune < 0x800) {
        bytes += 2;
      } else if (rune < 0x10000) {
        bytes += 3;
      } else {
        bytes += 4;
      }
    }
    return dense + (bytes / charsPerToken).ceil();
  }

  /// CJK, Hangul and Kana blocks, where one code point is about one token.
  static bool _isTokenDense(int rune) =>
      (rune >= 0x1100 && rune <= 0x11ff) ||
      (rune >= 0x2e80 && rune <= 0x9fff) ||
      (rune >= 0xa960 && rune <= 0xa97f) ||
      (rune >= 0xac00 && rune <= 0xd7af) ||
      (rune >= 0xf900 && rune <= 0xfaff) ||
      (rune >= 0xff00 && rune <= 0xffef);

  /// Model-facing cost of one image at the requested detail.
  ///
  /// `low` detail is charged the base rate only. Every other detail —
  /// including canonical `ToolImageDetail.original`, which the tool-result
  /// wire codec maps to wire `high` — charges the tile grid. The fitted tile
  /// grid is bounded by [maxImageTokensPerImage], so a thin image that only
  /// reaches the minimum short side through an extreme upscale can never
  /// demand hundreds of thousands of tokens. This is a deliberate, bounded
  /// estimate of model-facing image material and never claims exact vendor
  /// pricing.
  static int estimateImageTokens({
    required int width,
    required int height,
    bool lowDetail = false,
  }) {
    if (width <= 0 || height <= 0) {
      return 0;
    }
    if (lowDetail) {
      return imageBaseTokens;
    }
    var scaledWidth = width;
    var scaledHeight = height;
    final longest = width > height ? width : height;
    if (longest > imageMaxEdge) {
      final scale = imageMaxEdge / longest;
      scaledWidth = _scaledPixels(width * scale);
      scaledHeight = _scaledPixels(height * scale);
    }
    final shortest = scaledWidth < scaledHeight ? scaledWidth : scaledHeight;
    if (shortest < imageMinShortSide) {
      // [shortest] is at least one pixel, so this division stays finite.
      final scale = imageMinShortSide / shortest;
      scaledWidth = _scaledPixels(scaledWidth * scale);
      scaledHeight = _scaledPixels(scaledHeight * scale);
    }
    final tilesWide = (scaledWidth / imageTileEdge).ceil();
    final tilesHigh = (scaledHeight / imageTileEdge).ceil();
    final tiled = imageBaseTokens + imageTileTokens * tilesWide * tilesHigh;
    return tiled > maxImageTokensPerImage ? maxImageTokensPerImage : tiled;
  }

  /// Rounds one fitted image dimension, never to a zero or negative pixel.
  ///
  /// A thin positive image (for example `1x10000`) rounds its fitted short
  /// side to zero before the minimum-short-side scale; keeping at least one
  /// pixel keeps that division finite instead of producing `NaN`/infinity.
  static int _scaledPixels(double value) {
    final rounded = value.round();
    return rounded < 1 ? 1 : rounded;
  }

  static int estimateMessage(Message message) {
    var total = 0;
    final content = message.content;
    if (content != null && content.isNotEmpty) {
      if (!_looksLikeMediaPayload(content)) {
        total += estimateText(content);
      }
    }
    if (message.toolCalls != null) {
      for (final call in message.toolCalls!) {
        total += estimateText(call.name);
        total += estimateText(jsonEncode(call.arguments));
        if (call.id.isNotEmpty) {
          total += estimateText(call.id);
        }
      }
    }
    if (message.toolCallId != null && message.toolCallId!.isNotEmpty) {
      total += estimateText(message.toolCallId);
    }
    // Wire shadowing: reasoning, thought, and opaque providerState do not
    // reach the model request wire as input context and are deliberately
    // excluded from wire token estimates.
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

  /// Prices a provider wire payload tree for request measurement.
  ///
  /// Text nodes use the text rate. Encoded media strings (data URIs and long
  /// base64 blobs) are charged nothing here because they are transport for
  /// media that the owning request measures from its canonical, dimension-
  /// bearing history through [estimateMediaTokens]; pricing the encoding
  /// instead would charge hundreds of thousands of tokens for one image. Keys
  /// listed in [opaqueKeys] carry provider-owned state (for example Codex
  /// `encrypted_content` reasoning replay) that the provider prices under its
  /// own token models and are excluded from the text estimate.
  static int estimateWirePayload(
    Object? value, {
    Set<String> opaqueKeys = const <String>{},
  }) {
    if (value is Map) {
      var total = 0;
      for (final entry in value.entries) {
        if (opaqueKeys.contains(entry.key.toString())) continue;
        total += estimateWirePayload(entry.value, opaqueKeys: opaqueKeys);
      }
      return total;
    }
    if (value is List) {
      var total = 0;
      for (final item in value) {
        total += estimateWirePayload(item, opaqueKeys: opaqueKeys);
      }
      return total;
    }
    if (value is String) {
      if (value.isEmpty) {
        return 0;
      }
      return _isEncodedMediaPayload(value) ? 0 : estimateText(value);
    }
    if (value is num || value is bool) {
      return estimateText(value.toString());
    }
    return 0;
  }

  /// True for strings that carry encoded media transport rather than text.
  static bool _isEncodedMediaPayload(String value) {
    if (_dataUriPattern.hasMatch(value)) {
      return true;
    }
    return _isEncodedMediaBlob(value);
  }

  /// Byte-aware pricing for an encoded media payload string, or null for text.
  static int? _encodedMediaBytes(String value) {
    final dataUri = _dataUriPattern.firstMatch(value);
    if (dataUri != null) {
      final encoded = dataUri.group(1)!.replaceAll(RegExp(r'\s'), '');
      return _tokensForMediaBytes((encoded.length * 3) ~/ 4);
    }
    if (_isEncodedMediaBlob(value)) {
      final encoded = value.replaceAll(RegExp(r'\s'), '');
      return _tokensForMediaBytes((encoded.length * 3) ~/ 4);
    }
    return null;
  }

  /// Model-facing media accounting for one request.
  ///
  /// Tool-result images are priced from their observed dimensions, image
  /// attachments without recorded dimensions use the bounded per-image ceiling,
  /// declared `media_bytes` keep byte-based accounting, and encoded media left
  /// in message content is priced as bytes rather than as ordinary text.
  static int estimateMediaTokens(Iterable<Message> messages) {
    var total = 0;
    for (final message in messages) {
      final toolResult = message.toolResult;
      if (toolResult != null) {
        for (final block in toolResult.blocks) {
          if (block is ToolImageBlock) {
            total += estimateImageTokens(
              width: block.width,
              height: block.height,
              lowDetail: block.detail == ToolImageDetail.low,
            );
          }
        }
      }
      for (final attachment in message.attachments) {
        final isImage =
            attachment.kind == UserAttachmentKind.image ||
            attachment.mimeType.toLowerCase().startsWith('image/');
        if (isImage) {
          total += maxImageTokensPerImage;
        }
      }
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
      total += _encodedMediaBytes(content) ?? 0;
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
