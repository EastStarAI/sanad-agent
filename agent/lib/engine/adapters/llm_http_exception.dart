import 'dart:io';

import 'package:http/http.dart' as http;

import '../../core/secrets_redactor.dart';

/// Structured transport error surfaced by LLM adapters.
///
/// Plan 30 needs the runtime to classify real HTTP failures (429, 402, 503,
/// etc.) and respect `Retry-After`. String-only exceptions are not sufficient,
/// so adapters throw this wrapper whenever the provider returns a non-2xx
/// response.
class LlmHttpException implements IOException {
  final int statusCode;
  final String body;
  final Map<String, String> headers;
  final String operation;
  /// Actual request target; sanitize it before using it in diagnostics.
  final Uri? requestUri;

  const LlmHttpException({
    required this.statusCode,
    required this.body,
    required this.headers,
    required this.operation,
    this.requestUri,
  });

  factory LlmHttpException.fromResponse(
    http.Response response, {
    required String operation,
    Uri? requestUri,
  }) {
    return LlmHttpException(
      statusCode: response.statusCode,
      body: response.body,
      headers: response.headers,
      operation: operation,
      requestUri: requestUri ?? response.request?.url,
    );
  }

  factory LlmHttpException.fromStreamedResponse(
    http.StreamedResponse response,
    String body, {
    required String operation,
    Uri? requestUri,
  }) {
    return LlmHttpException(
      statusCode: response.statusCode,
      body: body,
      headers: response.headers,
      operation: operation,
      requestUri: requestUri ?? response.request?.url,
    );
  }

  static final RegExp _openAiRemainingHeader = RegExp(
    r'^x-ratelimit-remaining-(.+)$',
  );
  static final RegExp _openAiResetHeader = RegExp(r'^x-ratelimit-reset-(.+)$');
  static final RegExp _anthropicHeader = RegExp(
    r'^anthropic-ratelimit-(.+)-(remaining|reset)$',
  );
  static final RegExp _durationHint = RegExp(
    r'^\s*(\d+(?:\.\d+)?)\s*(ms|s|m|h)\s*$',
    caseSensitive: false,
  );
  static final RegExp _bodyResetAt = RegExp(
    r'reset\s+at\s+([0-9]{4}-[0-9]{2}-[0-9]{2}(?:[ T])[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.\d+)?(?:Z|[+-][0-9]{2}:?[0-9]{2})?|[A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2} GMT)',
    caseSensitive: false,
  );
  static const int _maxDurationMilliseconds = 9223372036854775;

  Duration? get retryAfter {
    return resolveRetryAfter(
      headers: headers,
      body: body,
      now: DateTime.now().toUtc(),
    );
  }

  static const _redactor = SecretsRedactor();

  static Duration? resolveRetryAfter({
    required Map<String, String> headers,
    required String body,
    DateTime? now,
  }) {
    final resolved = _resolveRetryAfter(
      headers: headers,
      body: body,
      now: (now ?? DateTime.now()).toUtc(),
    );
    return resolved?.duration;
  }

  @override
  String toString() =>
      'LlmHttpException($statusCode $operation): ${_redactor.redact(_summarizeBody(body))}';

  static String _summarizeBody(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return 'empty response body';
    }
    if (trimmed.length <= 180) {
      return trimmed;
    }
    return '${trimmed.substring(0, 177)}...';
  }

  static _RetryAfterResolution? _resolveRetryAfter({
    required Map<String, String> headers,
    required String body,
    required DateTime now,
  }) {
    final normalizedHeaders = <String, String>{};
    for (final entry in headers.entries) {
      normalizedHeaders[entry.key.toLowerCase()] = entry.value;
    }

    final retryAfterMs = _parseRetryAfterMs(
      normalizedHeaders['retry-after-ms'],
    );
    if (retryAfterMs != null) {
      return _RetryAfterResolution(
        retryAfterMs,
        _RetryAfterSource.retryAfterMs,
      );
    }

    final retryAfter = _parseRetryAfterHeader(
      normalizedHeaders['retry-after'],
      now: now,
    );
    if (retryAfter != null) {
      return _RetryAfterResolution(retryAfter, _RetryAfterSource.retryAfter);
    }

    final providerReset = _parseProviderResetHeaders(
      normalizedHeaders,
      now: now,
    );
    if (providerReset != null) {
      return _RetryAfterResolution(
        providerReset,
        _RetryAfterSource.providerResetHeader,
      );
    }

    final bodyReset = _parseBodyReset(body, now: now);
    if (bodyReset != null) {
      return _RetryAfterResolution(bodyReset, _RetryAfterSource.bodyReset);
    }

    return null;
  }

  static Duration? _parseRetryAfterMs(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final millis = double.tryParse(raw.trim());
    if (millis == null || millis.isNaN || millis.isInfinite || millis < 0) {
      return null;
    }
    return _durationFromMilliseconds(millis.ceil());
  }

  static Duration? _parseRetryAfterHeader(
    String? raw, {
    required DateTime now,
  }) {
    if (raw == null || raw.trim().isEmpty) return null;
    final value = raw.trim();
    final seconds = double.tryParse(value);
    if (seconds != null && !seconds.isNaN && !seconds.isInfinite) {
      if (seconds < 0) return null;
      return _durationFromMilliseconds((seconds * 1000).ceil());
    }
    return _parseAbsoluteDateTime(value, now: now);
  }

  static Duration? _parseProviderResetHeaders(
    Map<String, String> headers, {
    required DateTime now,
  }) {
    final remainingByDimension = <String, String>{};
    final resetByDimension = <String, String>{};

    for (final entry in headers.entries) {
      final openAiRemaining = _openAiRemainingHeader.firstMatch(entry.key);
      if (openAiRemaining != null) {
        remainingByDimension[openAiRemaining.group(1)!] = entry.value;
        continue;
      }

      final openAiReset = _openAiResetHeader.firstMatch(entry.key);
      if (openAiReset != null) {
        resetByDimension[openAiReset.group(1)!] = entry.value;
        continue;
      }

      final anthropic = _anthropicHeader.firstMatch(entry.key);
      if (anthropic != null) {
        final dimension = anthropic.group(1)!;
        final kind = anthropic.group(2)!;
        if (kind == 'remaining') {
          remainingByDimension[dimension] = entry.value;
        } else {
          resetByDimension[dimension] = entry.value;
        }
      }
    }

    Duration? selected;
    for (final entry in resetByDimension.entries) {
      final remainingRaw = remainingByDimension[entry.key];
      if (!_isExhaustedDimension(remainingRaw)) continue;
      final candidate = _parseResetValue(entry.value, now: now);
      if (candidate == null) continue;
      if (selected == null || candidate > selected) {
        selected = candidate;
      }
    }
    return selected;
  }

  static bool _isExhaustedDimension(String? raw) {
    if (raw == null || raw.trim().isEmpty) return false;
    final remaining = double.tryParse(raw.trim());
    if (remaining == null || !remaining.isFinite || remaining < 0) {
      return false;
    }
    return remaining == 0;
  }

  static Duration? _parseBodyReset(String body, {required DateTime now}) {
    final match = _bodyResetAt.firstMatch(body);
    if (match == null) return null;
    final rawTimestamp = match.group(1);
    if (rawTimestamp == null || rawTimestamp.trim().isEmpty) return null;
    return _parseAbsoluteDateTime(rawTimestamp.trim(), now: now);
  }

  static Duration? _parseResetValue(String raw, {required DateTime now}) {
    final value = raw.trim();
    if (value.isEmpty) return null;

    final durationMatch = _durationHint.firstMatch(value);
    if (durationMatch != null) {
      final amount = double.tryParse(durationMatch.group(1)!);
      final unit = durationMatch.group(2)!.toLowerCase();
      if (amount == null || amount.isNaN || amount.isInfinite || amount < 0) {
        return null;
      }
      switch (unit) {
        case 'ms':
          return _durationFromMilliseconds(amount.ceil());
        case 's':
          return _durationFromMilliseconds((amount * 1000).ceil());
        case 'm':
          return _durationFromMilliseconds((amount * 60 * 1000).ceil());
        case 'h':
          return _durationFromMilliseconds((amount * 60 * 60 * 1000).ceil());
      }
    }

    final epochValue = num.tryParse(value);
    if (epochValue != null &&
        !(epochValue is double &&
            (epochValue.isNaN || epochValue.isInfinite)) &&
        epochValue >= 0) {
      final fromEpoch = _parseEpochTimestamp(epochValue, now: now);
      if (fromEpoch != null) return fromEpoch;
    }

    return _parseAbsoluteDateTime(value, now: now);
  }

  static Duration? _parseEpochTimestamp(num value, {required DateTime now}) {
    final rounded = value.round();
    DateTime timestamp;
    try {
      if (rounded >= 1000000000000) {
        timestamp = DateTime.fromMillisecondsSinceEpoch(rounded, isUtc: true);
      } else if (rounded >= 1000000000) {
        timestamp = DateTime.fromMillisecondsSinceEpoch(
          rounded * 1000,
          isUtc: true,
        );
      } else {
        return null;
      }
    } catch (_) {
      return null;
    }
    final diff = timestamp.difference(now);
    if (diff <= Duration.zero) return null;
    return diff;
  }

  static Duration? _parseAbsoluteDateTime(String raw, {required DateTime now}) {
    final value = raw.trim();
    if (value.isEmpty) return null;

    DateTime? parsed;
    try {
      parsed = HttpDate.parse(value);
    } catch (_) {
      parsed = null;
    }

    parsed ??= _parseIsoLikeDateTime(value);
    if (parsed == null) return null;

    final utc = parsed.toUtc();
    final diff = utc.difference(now);
    if (diff <= Duration.zero) return null;
    return diff;
  }

  static DateTime? _parseIsoLikeDateTime(String raw) {
    final normalized = raw.trim().replaceFirst(' ', 'T');
    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(?:(Z|z)|([+-])(\d{2}):?(\d{2}))?$',
    ).firstMatch(normalized);
    if (match == null) return null;

    final year = int.tryParse(match.group(1)!);
    final month = int.tryParse(match.group(2)!);
    final day = int.tryParse(match.group(3)!);
    final hour = int.tryParse(match.group(4)!);
    final minute = int.tryParse(match.group(5)!);
    final second = int.tryParse(match.group(6)!);
    final microseconds = _fractionToMicroseconds(match.group(7));
    if (year == null ||
        month == null ||
        day == null ||
        hour == null ||
        minute == null ||
        second == null ||
        microseconds == null) {
      return null;
    }

    if (month < 1 ||
        month > 12 ||
        day < 1 ||
        day > 31 ||
        hour < 0 ||
        hour > 23 ||
        minute < 0 ||
        minute > 59 ||
        second < 0 ||
        second > 59) {
      return null;
    }

    try {
      final calendarCheck = DateTime.utc(
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
        int.parse(match.group(3)!),
        int.parse(match.group(4)!),
        int.parse(match.group(5)!),
        int.parse(match.group(6)!),
        microseconds ~/ 1000,
        microseconds % 1000,
      );
      if (calendarCheck.year != year ||
          calendarCheck.month != month ||
          calendarCheck.day != day ||
          calendarCheck.hour != hour ||
          calendarCheck.minute != minute ||
          calendarCheck.second != second) {
        return null;
      }

      var utc = calendarCheck;
      final sign = match.group(8);
      final offsetHoursRaw = match.group(9);
      final offsetMinutesRaw = match.group(10);
      if (sign != null && offsetHoursRaw != null && offsetMinutesRaw != null) {
        final offsetHours = int.tryParse(offsetHoursRaw);
        final offsetMinutes = int.tryParse(offsetMinutesRaw);
        if (offsetHours == null ||
            offsetMinutes == null ||
            offsetHours > 23 ||
            offsetMinutes > 59) {
          return null;
        }
        final offset = Duration(hours: offsetHours, minutes: offsetMinutes);
        utc = sign == '+' ? utc.subtract(offset) : utc.add(offset);
      }
      return utc;
    } catch (_) {
      return null;
    }
  }

  static int? _fractionToMicroseconds(String? fraction) {
    if (fraction == null || fraction.isEmpty) return 0;
    final digits = fraction.substring(1);
    final padded = '${digits}000000';
    return int.tryParse(padded.substring(0, 6));
  }

  static Duration? _durationFromMilliseconds(num milliseconds) {
    if (milliseconds is double &&
        (milliseconds.isNaN || milliseconds.isInfinite)) {
      return null;
    }
    if (milliseconds < 0) return null;
    final rounded = milliseconds.ceil();
    if (rounded > _maxDurationMilliseconds) return null;
    try {
      return Duration(milliseconds: rounded);
    } catch (_) {
      return null;
    }
  }
}

class _RetryAfterResolution {
  final Duration duration;
  final _RetryAfterSource source;

  const _RetryAfterResolution(this.duration, this.source);
}

enum _RetryAfterSource {
  retryAfterMs,
  retryAfter,
  providerResetHeader,
  bodyReset,
}
