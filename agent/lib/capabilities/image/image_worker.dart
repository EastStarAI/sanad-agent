import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../core/models/tool_execution_result.dart';
import 'image_policy.dart';

class ImageWorker {
  ImageWorker({Duration timeout = ImagePolicy.processingTimeout})
    : _timeout = timeout;

  final Duration _timeout;
  static final _semaphore = _AsyncSemaphore(ImagePolicy.maxConcurrency);

  Future<ImagePolicyResult> process(
    Uint8List bytes, {
    required ToolImageDetail detail,
  }) async {
    if (bytes.isEmpty) {
      return const ImagePolicyFailure(
        code: ToolResultErrorCode.unsupportedFormat,
        message: 'Image data is empty.',
      );
    }
    if (!ImagePolicy.isInputWithinLimit(bytes.length)) {
      return const ImagePolicyFailure(
        code: ToolResultErrorCode.tooLarge,
        message: 'Image exceeds the 20 MiB input limit.',
      );
    }
    final mimeType = ImagePolicy.sniffMimeType(bytes);
    if (mimeType == null) {
      return const ImagePolicyFailure(
        code: ToolResultErrorCode.unsupportedFormat,
        message:
            'Image format is unsupported or does not match valid magic bytes.',
      );
    }

    return _semaphore.withPermit(
      () => _runKillable(bytes, detail: detail, mimeType: mimeType),
    );
  }

  Future<ImagePolicyResult> _runKillable(
    Uint8List bytes, {
    required ToolImageDetail detail,
    required String mimeType,
  }) async {
    final receivePort = ReceivePort();
    Isolate? isolate;
    Timer? timer;
    final completer = Completer<ImagePolicyResult>();
    try {
      isolate = await Isolate.spawn<List<Object>>(_processImageInIsolate, [
        receivePort.sendPort,
        TransferableTypedData.fromList([bytes]),
        detail.index,
        mimeType,
      ], errorsAreFatal: true);
      timer = Timer(_timeout, () {
        isolate?.kill(priority: Isolate.immediate);
        if (!completer.isCompleted) {
          completer.complete(
            const ImagePolicyFailure(
              code: ToolResultErrorCode.timedOut,
              message: 'Image processing timed out after 15 seconds.',
            ),
          );
        }
      });
      receivePort.listen((message) {
        if (!completer.isCompleted) {
          completer.complete(_resultFromMessage(message));
        }
      });
      return await completer.future;
    } catch (_) {
      return const ImagePolicyFailure(
        code: ToolResultErrorCode.processingFailed,
        message: 'Image processing failed.',
      );
    } finally {
      timer?.cancel();
      isolate?.kill(priority: Isolate.immediate);
      receivePort.close();
    }
  }

  ImagePolicyResult _resultFromMessage(Object? message) {
    if (message is! Map) {
      return const ImagePolicyFailure(
        code: ToolResultErrorCode.processingFailed,
        message: 'Image processing failed.',
      );
    }
    final map = Map<String, Object?>.from(message);
    if (map['ok'] != true) {
      final codeName = map['code']?.toString();
      return ImagePolicyFailure(
        code: ToolResultErrorCode.values.firstWhere(
          (value) => value.name == codeName,
          orElse: () => ToolResultErrorCode.processingFailed,
        ),
        message: map['message']?.toString() ?? 'Image processing failed.',
      );
    }
    final data = map['bytes'];
    if (data is! TransferableTypedData) {
      return const ImagePolicyFailure(
        code: ToolResultErrorCode.processingFailed,
        message: 'Image processing failed.',
      );
    }
    return ImagePolicySuccess(
      bytes: data.materialize().asUint8List(),
      mimeType: map['mimeType']! as String,
      width: map['width']! as int,
      height: map['height']! as int,
    );
  }
}

void _processImageInIsolate(List<Object> input) {
  final sendPort = input[0] as SendPort;
  try {
    final bytes = (input[1] as TransferableTypedData)
        .materialize()
        .asUint8List();
    final detail = ToolImageDetail.values[input[2] as int];
    final sourceMime = input[3] as String;
    final decoder = switch (sourceMime) {
      'image/png' => img.PngDecoder(),
      'image/jpeg' => img.JpegDecoder(),
      'image/webp' => img.WebPDecoder(),
      _ => null,
    };
    final info = decoder?.startDecode(bytes);
    if (decoder == null || info == null || info.numFrames != 1) {
      _sendFailure(
        sendPort,
        ToolResultErrorCode.unsupportedFormat,
        info != null && info.numFrames != 1
            ? 'Animated or multi-frame images are unsupported.'
            : 'Image data is corrupt or unsupported.',
      );
      return;
    }
    final width = info.width;
    final height = info.height;
    if (width <= 0 || height <= 0) {
      _sendFailure(
        sendPort,
        ToolResultErrorCode.unsupportedFormat,
        'Image dimensions are invalid.',
      );
      return;
    }
    if (!ImagePolicy.areDimensionsWithinLimits(width, height)) {
      _sendFailure(
        sendPort,
        ToolResultErrorCode.tooLarge,
        'Image dimensions exceed the safe processing limit.',
      );
      return;
    }
    final decoded = decoder.decodeFrame(0);
    if (decoded == null) {
      _sendFailure(
        sendPort,
        ToolResultErrorCode.processingFailed,
        'Image data could not be decoded.',
      );
      return;
    }

    final sourceBase64Length = ImagePolicy.base64LengthForBytes(bytes.length);
    if (detail == ToolImageDetail.original) {
      if (!ImagePolicy.isBase64WithinLimitForBytes(bytes.length)) {
        _sendFailure(
          sendPort,
          ToolResultErrorCode.tooLarge,
          'Original image exceeds the 4 MiB encoded payload limit.',
        );
        return;
      }
      _sendSuccess(sendPort, bytes, sourceMime, width, height);
      return;
    }

    final targetEdge = ImagePolicy.detailMaxEdge(detail);
    final longestEdge = width > height ? width : height;
    if (longestEdge <= targetEdge &&
        sourceBase64Length <= ImagePolicy.maxBase64Chars) {
      _sendSuccess(sendPort, bytes, sourceMime, width, height);
      return;
    }

    var normalized = decoded;
    if (longestEdge > targetEdge) {
      final scale = targetEdge / longestEdge;
      normalized = img.copyResize(
        decoded,
        width: (width * scale).round().clamp(1, targetEdge),
        height: (height * scale).round().clamp(1, targetEdge),
        interpolation: img.Interpolation.average,
      );
    }
    final hasTransparentPixel =
        normalized.hasAlpha &&
        normalized.any((pixel) => pixel.aNormalized < 1.0);
    final outputMime = hasTransparentPixel ? 'image/png' : 'image/jpeg';
    final outputBytes = hasTransparentPixel
        ? img.encodePng(normalized, level: ImagePolicy.pngCompression)
        : img.encodeJpg(normalized, quality: ImagePolicy.jpegQuality);
    if (!ImagePolicy.isBase64WithinLimitForBytes(outputBytes.length)) {
      _sendFailure(
        sendPort,
        ToolResultErrorCode.tooLarge,
        'Normalized image exceeds the 4 MiB encoded payload limit.',
      );
      return;
    }
    _sendSuccess(
      sendPort,
      outputBytes,
      outputMime,
      normalized.width,
      normalized.height,
    );
  } catch (_) {
    _sendFailure(
      sendPort,
      ToolResultErrorCode.processingFailed,
      'Image processing failed.',
    );
  }
}

void _sendSuccess(
  SendPort sendPort,
  Uint8List bytes,
  String mimeType,
  int width,
  int height,
) {
  sendPort.send({
    'ok': true,
    'bytes': TransferableTypedData.fromList([bytes]),
    'mimeType': mimeType,
    'width': width,
    'height': height,
  });
}

void _sendFailure(SendPort sendPort, ToolResultErrorCode code, String message) {
  sendPort.send({'ok': false, 'code': code.name, 'message': message});
}

final class _AsyncSemaphore {
  _AsyncSemaphore(this._available);

  int _available;
  final List<Completer<void>> _waiters = [];

  Future<T> withPermit<T>(Future<T> Function() operation) async {
    await _acquire();
    try {
      return await operation();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_available > 0) {
      _available--;
      return Future.value();
    }
    final completer = Completer<void>();
    _waiters.add(completer);
    return completer.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _available++;
    }
  }
}
