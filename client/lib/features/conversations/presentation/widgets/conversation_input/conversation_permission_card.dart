import 'package:flutter/material.dart';

import '../../../domain/models/device_suspended_request.dart';
import 'clarifying_question_card.dart';
import 'permission_request_card.dart';
import 'secret_request_card.dart';

class ConversationPermissionCard extends StatelessWidget {
  final DeviceSuspendedRequest request;
  final Color borderColor;

  const ConversationPermissionCard({
    super.key,
    required this.request,
    required this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    if (request.toolName == 'system_ask_user') {
      return ClarifyingQuestionCard(
        request: request,
        borderColor: borderColor,
      );
    }
    if (request.isSecretRequest) {
      return SecretRequestCard(
        request: request,
        borderColor: borderColor,
      );
    }
    return PermissionRequestCard(
      request: request,
      borderColor: borderColor,
    );
  }
}
