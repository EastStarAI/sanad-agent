import 'dart:collection';

const int userAttachmentSchemaVersion = 1;

/// Stable classification used by history and client projections.
enum UserAttachmentKind { image, file }

/// Durable availability of an attachment already admitted by the Agent.
enum UserAttachmentStatus { available, unavailable }

/// Canonical metadata for one ordered user-message attachment.
///
/// [agentLocalReference] is deliberately present only in [toJson]. Public
/// protocol/cache consumers must use [toPublicJson].
enum AttachmentAdmissionErrorCode {
  invalidMetadata,
  tooManyFiles,
  fileTooLarge,
  totalTooLarge,
}

sealed class AttachmentAdmissionResult {
  const AttachmentAdmissionResult();
}

final class AttachmentAdmissionSuccess extends AttachmentAdmissionResult {
  AttachmentAdmissionSuccess(List<UserAttachment> attachments)
    : attachments = List<UserAttachment>.unmodifiable(attachments);

  final List<UserAttachment> attachments;
}

final class AttachmentAdmissionFailure extends AttachmentAdmissionResult {
  const AttachmentAdmissionFailure(this.code, this.message);

  final AttachmentAdmissionErrorCode code;
  final String message;
}

/// Receiver-authoritative limits shared by every attachment admission route.
abstract final class UserAttachmentPolicy {
  static const int maxFileBytes = 5 * 1024 * 1024;
  static const int maxFilesPerMessage = 4;
  static const int maxTotalBytesPerMessage = 20 * 1024 * 1024;

  static AttachmentAdmissionResult validate(
    Iterable<UserAttachment> attachments,
  ) {
    final ordered = attachments.toList(growable: false);
    if (ordered.length > maxFilesPerMessage) {
      return const AttachmentAdmissionFailure(
        AttachmentAdmissionErrorCode.tooManyFiles,
        'A message accepts at most 4 attachments.',
      );
    }
    var totalBytes = 0;
    for (final attachment in ordered) {
      if (attachment.sizeBytes > maxFileBytes) {
        return const AttachmentAdmissionFailure(
          AttachmentAdmissionErrorCode.fileTooLarge,
          'Each attachment must be 5 MiB or smaller.',
        );
      }
      totalBytes += attachment.sizeBytes;
      if (totalBytes > maxTotalBytesPerMessage) {
        return const AttachmentAdmissionFailure(
          AttachmentAdmissionErrorCode.totalTooLarge,
          'Attachments must total 20 MiB or less per message.',
        );
      }
    }
    return AttachmentAdmissionSuccess(ordered);
  }

  static List<Map<String, dynamic>> publicProjection(
    Iterable<UserAttachment> attachments,
  ) => List<Map<String, dynamic>>.unmodifiable(
    attachments.map((attachment) => attachment.toPublicJson()),
  );

  static AttachmentAdmissionResult parseAndValidate(Iterable<Object?> json) {
    final attachments = <UserAttachment>[];
    try {
      for (final value in json) {
        if (value is! Map) {
          throw const FormatException('Attachment metadata must be an object.');
        }
        attachments.add(
          UserAttachment.fromJson(Map<String, dynamic>.from(value)),
        );
      }
    } on Object {
      return const AttachmentAdmissionFailure(
        AttachmentAdmissionErrorCode.invalidMetadata,
        'Attachment metadata is invalid.',
      );
    }
    return validate(attachments);
  }
}

final class UserAttachment {
  static const _jsonKeys = {
    'schemaVersion',
    'id',
    'safeName',
    'mimeType',
    'sizeBytes',
    'sha256',
    'kind',
    'agentLocalReference',
    'mediaId',
    'status',
  };

  UserAttachment({
    this.schemaVersion = userAttachmentSchemaVersion,
    required this.id,
    required this.safeName,
    required this.mimeType,
    required this.sizeBytes,
    required this.sha256,
    required this.kind,
    required this.agentLocalReference,
    required this.mediaId,
    this.status = UserAttachmentStatus.available,
  }) {
    _validate();
  }

  factory UserAttachment.fromJson(Map<String, dynamic> json) {
    final unknown = json.keys.toSet().difference(_jsonKeys);
    if (unknown.isNotEmpty) {
      throw FormatException('Unknown attachment fields: ${unknown.join(', ')}');
    }
    final schemaVersion = json['schemaVersion'];
    final id = json['id'];
    final safeName = json['safeName'];
    final mimeType = json['mimeType'];
    final sizeBytes = json['sizeBytes'];
    final sha256 = json['sha256'];
    final kind = _enumByName(UserAttachmentKind.values, json['kind']);
    final agentLocalReference = json['agentLocalReference'];
    final mediaId = json['mediaId'];
    final status = _enumByName(UserAttachmentStatus.values, json['status']);
    if (schemaVersion is! int ||
        id is! String ||
        safeName is! String ||
        mimeType is! String ||
        sizeBytes is! int ||
        sha256 is! String ||
        kind == null ||
        agentLocalReference is! String ||
        mediaId is! String ||
        status == null) {
      throw const FormatException('Invalid user attachment shape.');
    }
    try {
      return UserAttachment(
        schemaVersion: schemaVersion,
        id: id,
        safeName: safeName,
        mimeType: mimeType,
        sizeBytes: sizeBytes,
        sha256: sha256,
        kind: kind,
        agentLocalReference: agentLocalReference,
        mediaId: mediaId,
        status: status,
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid user attachment: ${error.message}');
    }
  }

  final int schemaVersion;
  final String id;
  final String safeName;
  final String mimeType;
  final int sizeBytes;
  final String sha256;
  final UserAttachmentKind kind;
  final String agentLocalReference;
  final String mediaId;
  final UserAttachmentStatus status;

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'id': id,
    'safeName': safeName,
    'mimeType': mimeType,
    'sizeBytes': sizeBytes,
    'sha256': sha256,
    'kind': kind.name,
    'agentLocalReference': agentLocalReference,
    'mediaId': mediaId,
    'status': status.name,
  };

  Map<String, dynamic> toPublicJson() => UnmodifiableMapView({
    'schemaVersion': schemaVersion,
    'id': id,
    'safeName': safeName,
    'mimeType': mimeType,
    'sizeBytes': sizeBytes,
    'sha256': sha256,
    'kind': kind.name,
    'mediaId': mediaId,
    'status': status.name,
  });

  void _validate() {
    if (schemaVersion != userAttachmentSchemaVersion) {
      throw ArgumentError.value(
        schemaVersion,
        'schemaVersion',
        'is not supported',
      );
    }
    _requireOpaque(id, 'id');
    _requireOpaque(mediaId, 'mediaId');
    if (safeName.isEmpty ||
        safeName == '.' ||
        safeName == '..' ||
        safeName.contains('/') ||
        safeName.contains(r'\') ||
        safeName.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
      throw ArgumentError.value(
        safeName,
        'safeName',
        'must be a safe basename',
      );
    }
    if (!RegExp(
      r'^[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*$',
    ).hasMatch(mimeType)) {
      throw ArgumentError.value(mimeType, 'mimeType', 'must be normalized');
    }
    if (sizeBytes < 0) {
      throw ArgumentError.value(sizeBytes, 'sizeBytes', 'must not be negative');
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw ArgumentError.value(sha256, 'sha256', 'must be lowercase SHA-256');
    }
    if (agentLocalReference.isEmpty ||
        agentLocalReference.toLowerCase().startsWith('data:') ||
        agentLocalReference.contains('://')) {
      throw ArgumentError.value(
        agentLocalReference,
        'agentLocalReference',
        'must be an Agent-local filesystem reference',
      );
    }
    if ((kind == UserAttachmentKind.image) != mimeType.startsWith('image/')) {
      throw ArgumentError.value(kind, 'kind', 'must agree with MIME type');
    }
  }

  static void _requireOpaque(String value, String name) {
    if (value.isEmpty ||
        value.length > 200 ||
        value.contains('/') ||
        value.contains(r'\') ||
        value.runes.any((rune) => rune < 0x21 || rune == 0x7f)) {
      throw ArgumentError.value(value, name, 'must be an opaque identifier');
    }
  }

  static T? _enumByName<T extends Enum>(List<T> values, Object? name) {
    if (name is! String) return null;
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }
}
