import 'package:flutter/material.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_test_result_dto.dart';

import 'provider_discovery_notice.dart';
import 'provider_instance_test_notice.dart';

/// Keeps the durable discovery notice (and its fallback details) when Test
/// returns the same failure. A separate model verdict is not a duplicate.
class ProviderConnectionNotices extends StatelessWidget {
  const ProviderConnectionNotices({
    super.key,
    required this.instance,
    this.latestTest,
  });

  final ProviderInstanceDto instance;
  final ProviderInstanceTestResultDto? latestTest;

  @override
  Widget build(BuildContext context) {
    final result = latestTest;
    final checked = result?.instance;
    final error = instance.discoveryError;
    final failure = result?.failure;
    final sameFailure = error != null && failure != null &&
        error.kind == failure.kind && error.statusCode == failure.statusCode &&
        error.endpoint == failure.endpoint && error.definitive == failure.definitive;
    final currentModel = result?.model == null || result!.model == instance.defaultModel;
    final currentRevision = checked == null ||
        (checked.configRevision == instance.configRevision &&
         checked.credentialRevision == instance.credentialRevision);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ProviderDiscoveryNotice(
          instanceId: instance.id,
          error: error,
          modelCache: instance.modelCache,
        ),
        if (result != null && currentModel && currentRevision && !sameFailure)
          ProviderInstanceTestNotice(instanceId: instance.id, result: result),
      ],
    );
  }
}
