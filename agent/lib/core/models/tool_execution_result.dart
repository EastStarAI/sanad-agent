import 'dart:convert';

/// The current durable schema for [ToolExecutionResult].
const int toolExecutionResultSchemaVersion = 1;

/// Image detail requested by the tool caller.
enum ToolImageDetail { low, auto, high, original }

/// Closed, provider-neutral failures produced by tool execution.
enum ToolResultErrorCode {
  invalidInput,
  permissionDenied,
  notFound,
  unsupportedFormat,
  tooLarge,
  timedOut,
  processingFailed,
  executionFailed,
  batchImageBudgetExceeded,
}

/// One ordered content block in a [ToolExecutionResult].
sealed class ToolResultBlock {
  const ToolResultBlock();

  factory ToolResultBlock.fromJson(Map<String, dynamic> json) {
    return switch (json['type']) {
      'text' => ToolTextBlock.fromJson(json),
      'image' => ToolImageBlock.fromJson(json),
      _ => throw const FormatException('Unsupported tool result block type.'),
    };
  }

  Map<String, dynamic> toJson();
}

/// A non-empty text projection visible to text-only consumers.
final class ToolTextBlock extends ToolResultBlock {
  ToolTextBlock({required this.text}) {
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be empty');
    }
  }

  factory ToolTextBlock.fromJson(Map<String, dynamic> json) {
    final text = json['text'];
    if (text is! String) {
      throw const FormatException('Tool text block requires string text.');
    }
    try {
      return ToolTextBlock(text: text);
    } on ArgumentError catch (error) {
      throw FormatException('Invalid tool text block: ${error.message}');
    }
  }

  final String text;

  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};
}

/// A validated inline image payload in a tool result.
final class ToolImageBlock extends ToolResultBlock {
  ToolImageBlock({
    required this.dataBase64,
    required this.mimeType,
    required this.width,
    required this.height,
    required this.detail,
  }) {
    _validate();
  }

  factory ToolImageBlock.fromJson(Map<String, dynamic> json) {
    final dataBase64 = json['dataBase64'];
    final mimeType = json['mimeType'];
    final width = json['width'];
    final height = json['height'];
    final detail = json['detail'];
    if (dataBase64 is! String ||
        mimeType is! String ||
        width is! int ||
        height is! int ||
        detail is! String) {
      throw const FormatException('Invalid tool image block shape.');
    }

    final parsedDetail = _imageDetailByWireValue[detail];
    if (parsedDetail == null) {
      throw const FormatException('Unsupported tool image detail.');
    }
    try {
      return ToolImageBlock(
        dataBase64: dataBase64,
        mimeType: mimeType,
        width: width,
        height: height,
        detail: parsedDetail,
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid tool image block: ${error.message}');
    }
  }

  static const Set<String> supportedMimeTypes = {
    'image/png',
    'image/jpeg',
    'image/webp',
  };

  final String dataBase64;
  final String mimeType;
  final int width;
  final int height;
  final ToolImageDetail detail;

  void _validate() {
    if (!supportedMimeTypes.contains(mimeType)) {
      throw ArgumentError.value(mimeType, 'mimeType', 'is not supported');
    }
    if (width <= 0) {
      throw ArgumentError.value(width, 'width', 'must be positive');
    }
    if (height <= 0) {
      throw ArgumentError.value(height, 'height', 'must be positive');
    }
    if (dataBase64.isEmpty) {
      throw ArgumentError.value(dataBase64, 'dataBase64', 'must not be empty');
    }
    try {
      final decoded = base64.decode(dataBase64);
      if (base64.encode(decoded) != dataBase64) {
        throw const FormatException('non-canonical base64');
      }
    } on FormatException {
      throw ArgumentError.value(
        dataBase64,
        'dataBase64',
        'must be canonical base64',
      );
    }
  }

  @override
  Map<String, dynamic> toJson() => {
    'type': 'image',
    'dataBase64': dataBase64,
    'mimeType': mimeType,
    'width': width,
    'height': height,
    'detail': detail.name,
  };
}

/// Provider-neutral, durable output from one tool execution.
final class ToolExecutionResult {
  ToolExecutionResult({
    this.schemaVersion = toolExecutionResultSchemaVersion,
    required List<ToolResultBlock> blocks,
    this.isError = false,
    this.errorCode,
  }) : blocks = List<ToolResultBlock>.unmodifiable(blocks) {
    _validate();
  }

  factory ToolExecutionResult.text(
    String text, {
    bool isError = false,
    ToolResultErrorCode? errorCode,
  }) {
    return ToolExecutionResult(
      blocks: [ToolTextBlock(text: text)],
      isError: isError,
      errorCode: errorCode,
    );
  }

  factory ToolExecutionResult.fromJson(Map<String, dynamic> json) {
    final schemaVersion = json['schemaVersion'];
    final rawBlocks = json['blocks'];
    final isError = json['isError'];
    final rawErrorCode = json['errorCode'];
    if (schemaVersion is! int || rawBlocks is! List || isError is! bool) {
      throw const FormatException('Invalid tool execution result shape.');
    }
    if (rawErrorCode != null && rawErrorCode is! String) {
      throw const FormatException('Invalid tool result error code.');
    }

    final errorCode = rawErrorCode == null
        ? null
        : _errorCodeByWireValue[rawErrorCode];
    if (rawErrorCode != null && errorCode == null) {
      throw const FormatException('Unsupported tool result error code.');
    }

    try {
      return ToolExecutionResult(
        schemaVersion: schemaVersion,
        blocks: rawBlocks
            .map((rawBlock) {
              if (rawBlock is! Map) {
                throw const FormatException(
                  'Tool result block must be an object.',
                );
              }
              return ToolResultBlock.fromJson(
                Map<String, dynamic>.from(rawBlock),
              );
            })
            .toList(growable: false),
        isError: isError,
        errorCode: errorCode,
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid tool execution result: ${error.message}');
    }
  }

  final int schemaVersion;
  final List<ToolResultBlock> blocks;
  final bool isError;
  final ToolResultErrorCode? errorCode;

  String get displayText =>
      blocks.whereType<ToolTextBlock>().map((block) => block.text).join('\n');

  void _validate() {
    if (schemaVersion != toolExecutionResultSchemaVersion) {
      throw ArgumentError.value(
        schemaVersion,
        'schemaVersion',
        'is not supported',
      );
    }
    if (!blocks.any((block) => block is ToolTextBlock)) {
      throw ArgumentError.value(
        blocks,
        'blocks',
        'must contain at least one text block',
      );
    }
    if (!isError && errorCode != null) {
      throw ArgumentError.value(
        errorCode,
        'errorCode',
        'requires isError=true',
      );
    }
  }

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'blocks': blocks.map((block) => block.toJson()).toList(growable: false),
    'isError': isError,
    if (errorCode != null) 'errorCode': _errorCodeWireValues[errorCode],
  };
}

const Map<String, ToolImageDetail> _imageDetailByWireValue = {
  'low': ToolImageDetail.low,
  'auto': ToolImageDetail.auto,
  'high': ToolImageDetail.high,
  'original': ToolImageDetail.original,
};

const Map<ToolResultErrorCode, String> _errorCodeWireValues = {
  ToolResultErrorCode.invalidInput: 'invalid_input',
  ToolResultErrorCode.permissionDenied: 'permission_denied',
  ToolResultErrorCode.notFound: 'not_found',
  ToolResultErrorCode.unsupportedFormat: 'unsupported_format',
  ToolResultErrorCode.tooLarge: 'too_large',
  ToolResultErrorCode.timedOut: 'timed_out',
  ToolResultErrorCode.processingFailed: 'processing_failed',
  ToolResultErrorCode.executionFailed: 'execution_failed',
  ToolResultErrorCode.batchImageBudgetExceeded: 'batch_image_budget_exceeded',
};

final Map<String, ToolResultErrorCode> _errorCodeByWireValue = {
  for (final entry in _errorCodeWireValues.entries) entry.value: entry.key,
};
