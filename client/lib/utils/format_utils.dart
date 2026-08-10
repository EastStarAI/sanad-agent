import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';

class EventMetadataFormatter {
  EventMetadataFormatter._();

  static String responseMetaText(CanonicalEvent event, BuildContext context) {
    if (event.kind != EventKind.finalAnswer) return '';

    final model = event.model?.trim();
    final modelDisplay = event.modelDisplay?.trim();
    final runtimeMs = event.runtimeMs;
    final usage = event.usage;
    final selectedSession = context.select<SessionCubit, Session?>(
      (cubit) => cubit.state.selectedSession,
    );
    final contextTokens = event.contextTokens ?? selectedSession?.contextTokens;

    final parts = <String>[];
    final inputTokens = _readUsageNumber(usage, [
      'input',
      'inputTokens',
      'input_tokens',
      'prompt_tokens',
      'promptTokens',
    ]);
    final outputTokens = _readUsageNumber(usage, [
      'output',
      'outputTokens',
      'output_tokens',
      'completion_tokens',
      'completionTokens',
    ]);
    final cacheReadTokens = _readUsageNumber(usage, [
      'cacheRead',
      'cache_read_input_tokens',
      'cacheReadInputTokens',
    ]);
    final contextPercent = _formatContextPercent(inputTokens, contextTokens);
    if (inputTokens != null && inputTokens > 0) {
      parts.add('↑${_formatCompactNumber(inputTokens)}');
    }
    if (outputTokens != null && outputTokens > 0) {
      parts.add('↓${_formatCompactNumber(outputTokens)}');
    }
    if (cacheReadTokens != null && cacheReadTokens > 0) {
      parts.add('R${_formatCompactNumber(cacheReadTokens)}');
    }
    if (contextPercent.isNotEmpty) {
      parts.add(contextPercent);
    }
    final resolvedModel = (modelDisplay != null && modelDisplay.isNotEmpty) ? modelDisplay : _formatInlineModel(model);
    if (resolvedModel.isNotEmpty) {
      parts.add(resolvedModel);
    }
    final durationText = formatRuntime(runtimeMs);
    if (durationText.isNotEmpty) {
      parts.add(durationText);
    }
    return parts.join('  •  ');
  }

  static String timestampText(DateTime timestamp, BuildContext context) {
    return MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(timestamp.toLocal()),
      alwaysUse24HourFormat: false,
    );
  }

  static String formatRuntime(dynamic runtimeMs) {
    if (runtimeMs is! num) return '';
    final milliseconds = runtimeMs.round();
    if (milliseconds < 1000) return '${milliseconds}ms';
    final seconds = milliseconds / 1000;
    if (seconds < 60) {
      return '${seconds.toStringAsFixed(seconds >= 10 ? 0 : 1)}s';
    }

    final totalSeconds = (milliseconds / 1000).round();
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final remainingSeconds = totalSeconds % 60;

    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else {
      return '${minutes}m ${remainingSeconds}s';
    }
  }

  static num? _readUsageNumber(dynamic usage, List<String> keys) {
    if (usage is! Map) return null;
    for (final key in keys) {
      final value = usage[key];
      if (value is num) return value;
    }
    return null;
  }

  static String _formatContextPercent(num? inputTokens, dynamic contextTokens) {
    if (inputTokens == null || contextTokens is! num || inputTokens <= 0 || contextTokens <= 0) {
      return '';
    }
    final percent = (inputTokens / contextTokens) * 100;
    if (percent <= 0) return '';
    if (percent < 1) {
      return '${percent.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '')}% ctx';
    }
    return '${percent.round()}% ctx';
  }

  static String _formatInlineModel(String? model) {
    final trimmed = model?.trim() ?? '';
    if (trimmed.isEmpty) return '';
    final parts = trimmed.split('/').where((p) => p.isNotEmpty).toList();
    return parts.isNotEmpty ? parts.last : trimmed;
  }

  static String _formatCompactNumber(num value) {
    if (value >= 1000000) {
      final compact = value / 1000000;
      return '${compact.toStringAsFixed(compact >= 10 ? 0 : 1).replaceFirst(RegExp(r'\.0$'), '')}M';
    }
    if (value >= 1000) {
      final compact = value / 1000;
      return '${compact.toStringAsFixed(compact >= 10 ? 0 : 1).replaceFirst(RegExp(r'\.0$'), '')}k';
    }
    return value.round().toString();
  }
}
