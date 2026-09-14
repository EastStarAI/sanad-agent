import 'dart:convert';

import '../../core/models/message.dart';
import '../../core/models/tool_execution_result.dart';

abstract final class ToolResultWireCodec {
  static Object responsesOutput(Message message) {
    final result = message.toolResult;
    if (result == null || !_hasImage(result)) {
      return message.content ?? '';
    }
    return result.blocks.map(_responsesBlock).toList(growable: false);
  }

  static Object anthropicContent(Message message) {
    final result = message.toolResult;
    if (result == null || !_hasImage(result)) {
      return message.content ?? '';
    }
    return result.blocks.map(_anthropicBlock).toList(growable: false);
  }

  static Map<String, dynamic> _responsesBlock(ToolResultBlock block) =>
      switch (block) {
        ToolTextBlock(:final text) => {'type': 'input_text', 'text': text},
        ToolImageBlock() => {
          'type': 'input_image',
          'image_url': _dataUrl(block),
          'detail': block.detail == ToolImageDetail.original
              ? ToolImageDetail.high.name
              : block.detail.name,
        },
      };

  static Map<String, dynamic> _anthropicBlock(ToolResultBlock block) =>
      switch (block) {
        ToolTextBlock(:final text) => {'type': 'text', 'text': text},
        ToolImageBlock() => {
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': block.mimeType,
            'data': _validatedBase64(block),
          },
        },
      };

  static String _dataUrl(ToolImageBlock block) =>
      'data:${block.mimeType};base64,${_validatedBase64(block)}';

  static String _validatedBase64(ToolImageBlock block) {
    if (!ToolImageBlock.supportedMimeTypes.contains(block.mimeType) ||
        block.width <= 0 ||
        block.height <= 0) {
      throw const FormatException('Malformed image tool result block.');
    }
    try {
      final bytes = base64.decode(block.dataBase64);
      if (bytes.isEmpty || base64.encode(bytes) != block.dataBase64) {
        throw const FormatException('Malformed image tool result block.');
      }
    } on FormatException {
      throw const FormatException('Malformed image tool result block.');
    }
    return block.dataBase64;
  }

  static bool _hasImage(ToolExecutionResult result) =>
      result.blocks.any((block) => block is ToolImageBlock);
}
