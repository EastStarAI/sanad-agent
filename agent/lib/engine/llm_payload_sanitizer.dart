import 'dart:convert';

import '../core/secrets_redactor.dart';

/// Sanitizes LLM request and response payloads before a request dump writes
/// them to disk.
///
/// `LLMRequestDumper` owns dump lifecycle, file naming, and capture state; this
/// owner owns the credential masking, image metadata, MIME sniffing, and string
/// sanitization applied to every value a dump writes.
class LLMPayloadSanitizer {
  /// Central secrets redactor — applied to every string value written to disk
  /// so API keys, bearer tokens, and auth headers never appear in dump files.
  static const _redactor = SecretsRedactor();

  /// Records only credential presence. No prefix or suffix of a credential
  /// is ever written: providers issue keys without recognizable prefixes, so
  /// any retained fragment is an unbounded partial disclosure (Task 116).
  static String? maskApiKey(String? key) {
    if (key == null || key.isEmpty) return null;
    return '***';
  }

  /// Masks a scalar value stored under a credential-bearing field or header
  /// name, keeping only the non-secret `Bearer` scheme marker.
  static Object? _maskSensitiveScalar(Object? value) {
    if (value is! String || value.isEmpty) return value;
    return value.toLowerCase().startsWith('bearer ') ? 'Bearer ***' : '***';
  }

  /// Serialize error objects including custom status code and response body details.
  static Map<String, dynamic> serializeError(Object error) {
    final Map<String, dynamic> errorMap = {
      'type': error.runtimeType.toString(),
      // Redact the message immediately so secrets never appear in dump files.
      'message': _redactor.redact(error.toString()),
    };

    try {
      final dynamic err = error;
      if (err.statusCode != null) {
        errorMap['status_code'] = err.statusCode;
      }
    } catch (_) {}

    try {
      final dynamic err = error;
      if (err.uri != null) {
        errorMap['uri'] = _redactor.redact(err.uri.toString());
      }
    } catch (_) {}

    try {
      final dynamic err = error;
      if (err.response != null) {
        errorMap['response_status'] = err.response.statusCode;
        errorMap['response_body'] = _redactor.redact(
          err.response.body.toString(),
        );
      }
    } catch (_) {}

    return errorMap;
  }

  /// Recursively traverses a payload, replacing typed image blocks, native Ollama
  /// image arrays, and data URIs before generic secret/string redaction.
  static dynamic sanitizePayload(dynamic value) {
    if (value is Map) {
      final image = _imagePayloadMetadata(value);
      if (image != null) return image;
      return value.map((key, child) {
        if (key == 'images') {
          if (child is List) {
            return MapEntry(key, child.map(_sanitizeNativeImage).toList());
          }
          if (child is String) {
            return MapEntry(key, _sanitizeNativeImage(child));
          }
        }
        if (key is String &&
            child is String &&
            _redactor.isSensitiveFieldName(key)) {
          return MapEntry(key, _maskSensitiveScalar(child));
        }
        return MapEntry(key, sanitizePayload(child));
      });
    }
    if (value is List) return value.map(sanitizePayload).toList();
    if (value is String) return _sanitizeString(value);
    if (value != null && value is! num && value is! bool) {
      try {
        return sanitizePayload((value as dynamic).toJson());
      } catch (_) {
        return value;
      }
    }
    return value;
  }

  static Map<String, dynamic>? _imagePayloadMetadata(Map value) {
    final type = value['type']?.toString();
    if (type != 'image' && type != 'image_url' && type != 'input_image') {
      return null;
    }

    String? mimeType;
    String? payload;
    if (value['dataBase64'] is String) {
      payload = value['dataBase64'] as String;
      mimeType = value['mimeType']?.toString();
    } else if (value['data'] is String) {
      payload = value['data'] as String;
      mimeType = value['mimeType']?.toString();
    } else if (value['source'] is Map) {
      final source = value['source'] as Map;
      payload = source['data'] is String ? source['data'] as String : null;
      mimeType = (source['media_type'] ?? source['mimeType'])?.toString();
    } else if (value['image_url'] is Map) {
      final imageUrl = value['image_url'] as Map;
      payload = imageUrl['url'] is String ? imageUrl['url'] as String : null;
    } else if (value['image_url'] is String) {
      payload = value['image_url'] as String;
    }
    if (payload == null) return null;

    final dataUri = _parseDataUri(payload);
    mimeType ??= dataUri?.mimeType;
    final base64Value = dataUri?.payload ?? payload;
    final decodedBytes = _decodedBase64Bytes(base64Value);
    if (decodedBytes != null &&
        (mimeType == null ||
            mimeType == 'unknown' ||
            mimeType == 'application/octet-stream')) {
      mimeType = _sniffMimeTypeFromBase64(base64Value);
    }
    return {
      'type': 'image_redacted',
      'mime_type': mimeType ?? 'unknown',
      'decoded_bytes': decodedBytes,
    };
  }

  static Map<String, dynamic> _sanitizeNativeImage(dynamic item) {
    if (item is Map) {
      final image = _imagePayloadMetadata(item);
      if (image != null) return image;
    }
    if (item is! String) {
      return const {
        'type': 'image_redacted',
        'mime_type': 'unknown',
        'decoded_bytes': null,
      };
    }

    final dataUri = _parseDataUri(item);
    final String base64Payload;
    String? mimeType;
    if (dataUri != null) {
      base64Payload = dataUri.payload;
      if (dataUri.mimeType.isNotEmpty) {
        mimeType = dataUri.mimeType;
      }
    } else {
      base64Payload = item;
    }

    final decodedBytes = _decodedBase64Bytes(base64Payload);
    if (decodedBytes == null) {
      return {
        'type': 'image_redacted',
        'mime_type': mimeType ?? 'unknown',
        'decoded_bytes': null,
      };
    }

    if (mimeType == null ||
        mimeType == 'unknown' ||
        mimeType == 'application/octet-stream') {
      mimeType = _sniffMimeTypeFromBase64(base64Payload);
    }

    return {
      'type': 'image_redacted',
      'mime_type': mimeType,
      'decoded_bytes': decodedBytes,
    };
  }

  static String _sniffMimeTypeFromBase64(String base64Payload) {
    if (base64Payload.isEmpty) return 'unknown';
    try {
      final headerLength = base64Payload.length >= 16
          ? 16
          : base64Payload.length;
      final bytes = base64.decode(base64Payload.substring(0, headerLength));
      return _sniffMimeTypeFromBytes(bytes);
    } catch (_) {
      return 'unknown';
    }
  }

  static String _sniffMimeTypeFromBytes(List<int> bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0d &&
        bytes[5] == 0x0a &&
        bytes[6] == 0x1a &&
        bytes[7] == 0x0a) {
      return 'image/png';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4e &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[2] == 0xff) {
      return 'image/jpeg';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return 'image/gif';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'image/webp';
    }
    return 'unknown';
  }

  static ({String mimeType, String payload})? _parseDataUri(String value) {
    if (!value.toLowerCase().startsWith('data:')) return null;
    final separator = value.toLowerCase().indexOf(';base64,');
    if (separator <= 5) return null;
    final mimeType = value.substring(5, separator);
    if (mimeType.contains(',') || mimeType.contains(';')) return null;
    return (
      mimeType: mimeType,
      payload: value.substring(separator + ';base64,'.length),
    );
  }

  static int? _decodedBase64Bytes(String value) {
    if (value.isEmpty ||
        value.length % 4 != 0 ||
        !RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(value)) {
      return null;
    }
    final padding = value.endsWith('==')
        ? 2
        : value.endsWith('=')
        ? 1
        : 0;
    return (value.length * 3 ~/ 4) - padding;
  }

  /// Sanitizes one string without retaining any sample of binary payloads.
  static String _sanitizeString(String val) {
    final dataUri = _parseDataUri(val);
    if (dataUri != null) {
      final bytes = _decodedBase64Bytes(dataUri.payload);
      return '[image payload redacted: mime=${dataUri.mimeType}, bytes=${bytes ?? 'unknown'}]';
    }

    val = _redactor.redact(val);
    if (val.length > 1000 &&
        !val.contains(RegExp(r'\s')) &&
        RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(val)) {
      return '[binary payload redacted: mime=unknown, bytes=${_decodedBase64Bytes(val) ?? 'unknown'}]';
    }
    if (val.startsWith('sk-') && val.length > 20) {
      return maskApiKey(val) ?? val;
    }
    if (val.startsWith('nvapi-') && val.length > 20) {
      return maskApiKey(val) ?? val;
    }
    if (val.startsWith('Bearer ') && val.length > 30) {
      final token = val.substring(7);
      return 'Bearer ${maskApiKey(token)}';
    }
    return val;
  }
}
