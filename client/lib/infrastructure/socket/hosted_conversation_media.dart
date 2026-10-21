import 'dart:typed_data';

final class HostedConversationMedia {
  const HostedConversationMedia({required this.bytes, required this.mimeType});

  final Uint8List bytes;
  final String mimeType;
}
