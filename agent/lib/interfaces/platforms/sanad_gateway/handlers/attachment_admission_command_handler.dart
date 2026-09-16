import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sanad_agent/core/models/user_attachment.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';

import '../protocol/canonical_events.dart';
import '../sanad_protocol_bridge.dart';

final class AttachmentAdmissionCommandHandler {
  AttachmentAdmissionCommandHandler({
    required AttachmentStore store,
    required SanadProtocolBridge bridge,
  }) : _store = store,
       _bridge = bridge;

  final AttachmentStore _store;
  final SanadProtocolBridge _bridge;

  Future<void> handle(
    CanonicalEvent event,
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  ) async {
    final sessionId =
        event.sessionId ?? event.payload['session_id']?.toString().trim() ?? '';
    final requestId = event.payload['request_id']?.toString().trim() ?? '';
    final rawAttachments = event.payload['attachments'];
    if (sessionId.isEmpty ||
        requestId.isEmpty ||
        rawAttachments is! List ||
        rawAttachments.isEmpty ||
        rawAttachments.length > UserAttachmentPolicy.maxFilesPerMessage) {
      await _emitResult(
        emitEnvelope,
        sessionId: sessionId,
        requestId: requestId,
        outcome: 'invalid_request',
      );
      return;
    }

    final staged = <UserAttachment>[];
    var declaredTotalBytes = 0;
    try {
      for (final raw in rawAttachments) {
        if (raw is! Map) throw const FormatException();
        final json = Map<String, dynamic>.from(raw);
        const keys = {'name', 'size_bytes', 'sha256', 'data_base64'};
        if (json.keys.toSet().difference(keys).isNotEmpty ||
            json.keys.length != keys.length ||
            json['name'] is! String ||
            json['size_bytes'] is! int ||
            json['sha256'] is! String ||
            json['data_base64'] is! String) {
          throw const FormatException();
        }
        final declaredSize = json['size_bytes'] as int;
        final declaredSha = json['sha256'] as String;
        final encoded = json['data_base64'] as String;
        declaredTotalBytes += declaredSize;
        final maxEncodedLength =
            ((UserAttachmentPolicy.maxFileBytes + 2) ~/ 3) * 4;
        if (declaredSize < 0 ||
            declaredSize > UserAttachmentPolicy.maxFileBytes ||
            declaredTotalBytes > UserAttachmentPolicy.maxTotalBytesPerMessage ||
            encoded.length > maxEncodedLength) {
          throw const FormatException();
        }
        final bytes = base64Decode(encoded);
        if (declaredSize != bytes.length ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(declaredSha) ||
            sha256.convert(bytes).toString() != declaredSha) {
          throw const FormatException();
        }
        final upload = await _store.create(
          fileName: json['name'] as String,
          expectedSize: declaredSize,
          expectedSha256: declaredSha,
        );
        try {
          await _store.write(upload, bytes);
          staged.add(
            await _store.commit(
              upload,
              sessionId: sessionId,
              admissionId: requestId,
            ),
          );
        } on Object {
          await _store.cancel(upload);
          rethrow;
        }
      }
      if (UserAttachmentPolicy.validate(staged) is AttachmentAdmissionFailure) {
        throw const FormatException();
      }
      await _emitResult(
        emitEnvelope,
        sessionId: sessionId,
        requestId: requestId,
        outcome: 'accepted',
        attachmentIds: staged
            .map((attachment) => attachment.id)
            .toList(growable: false),
      );
    } on Object {
      await _store.discardAdmission(
        sessionId: sessionId,
        admissionId: requestId,
      );
      await _emitResult(
        emitEnvelope,
        sessionId: sessionId,
        requestId: requestId,
        outcome: 'admission_failed',
      );
    }
  }

  Future<void> _emitResult(
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope, {
    required String sessionId,
    required String requestId,
    required String outcome,
    List<String> attachmentIds = const [],
  }) => emitEnvelope(
    _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: 'attachment.admission_result',
        sessionId: sessionId,
        payload: {
          'session_id': sessionId,
          'request_id': requestId,
          'outcome': outcome,
          if (attachmentIds.isNotEmpty) 'attachment_ids': attachmentIds,
        },
      ),
    ),
  );
}
