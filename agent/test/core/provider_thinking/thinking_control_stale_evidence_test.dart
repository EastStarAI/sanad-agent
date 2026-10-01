import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_stale_evidence.dart';
import 'package:test/test.dart';

void main() {
  test('marks old live evidence stale after ttl', () {
    final descriptor = ThinkingControlDescriptor(
      status: ThinkingCapabilityStatus.supported,
      kind: ThinkingControlKind.effort,
      options: const [
        ThinkingControlOption(id: 'low', label: 'Low'),
      ],
      capabilityRevision: 'rev-1',
      source: 'live',
      observedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 6)),
    );

    expect(ThinkingControlStaleEvidence.isStale(descriptor), isTrue);
  });

  test('keeps fresh live evidence within ttl', () {
    final descriptor = ThinkingControlDescriptor(
      status: ThinkingCapabilityStatus.supported,
      kind: ThinkingControlKind.effort,
      options: const [
        ThinkingControlOption(id: 'low', label: 'Low'),
      ],
      capabilityRevision: 'rev-1',
      source: 'live',
      observedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
    );

    expect(ThinkingControlStaleEvidence.isStale(descriptor), isFalse);
  });

  test('marks live evidence without observedAt as stale', () {
    const descriptor = ThinkingControlDescriptor(
      status: ThinkingCapabilityStatus.supported,
      kind: ThinkingControlKind.effort,
      options: [
        ThinkingControlOption(id: 'low', label: 'Low'),
      ],
      capabilityRevision: 'rev-1',
      source: 'live',
    );

    expect(ThinkingControlStaleEvidence.isStale(descriptor), isTrue);
  });

  test('marks transient probe failure unknown as stale not unsupported', () {
    final descriptor = ThinkingControlDescriptor.unknown(
      capabilityRevision: 'rev-1',
      source: 'live_probe_failed',
    );

    expect(descriptor.status, ThinkingCapabilityStatus.unknown);
    expect(ThinkingControlStaleEvidence.isStale(descriptor), isTrue);
  });

  test('does not treat profile-sourced descriptors as stale', () {
    const descriptor = ThinkingControlDescriptor(
      status: ThinkingCapabilityStatus.supported,
      kind: ThinkingControlKind.effort,
      options: [
        ThinkingControlOption(id: 'low', label: 'Low'),
      ],
      capabilityRevision: 'rev-1',
      source: 'profile',
    );

    expect(ThinkingControlStaleEvidence.isStale(descriptor), isFalse);
  });
}
