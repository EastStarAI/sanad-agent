import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_cubit.dart';

/// Formats a draft attachment's size for the composer attachment rail.
String formatAttachmentBytes(int bytes) {
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '$bytes B';
}

/// Reads the composer's input cubit, or `null` when this subtree has none.
ConversationInputCubit? maybeInputCubit(BuildContext context) {
  try {
    return context.read<ConversationInputCubit>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// Reads the dictation cubit, or `null` on surfaces without dictation.
///
/// Uses `watch` on purpose: the send button has to rebuild the moment a
/// dictation session starts or ends, because that is when it becomes enabled
/// even though the composer is still empty.
DictationCubit? maybeDictationCubit(BuildContext context) {
  try {
    return context.watch<DictationCubit>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// Same lookup for event handlers and shortcut callbacks.
///
/// `watch` is illegal outside the build phase, so anything triggered by a tap
/// or a key must read the cubit instead of subscribing to it.
DictationCubit? readDictationCubit(BuildContext context) {
  try {
    return context.read<DictationCubit>();
  } on ProviderNotFoundException {
    return null;
  }
}

