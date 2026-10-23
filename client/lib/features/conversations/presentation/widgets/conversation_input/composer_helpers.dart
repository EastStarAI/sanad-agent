import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';

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

