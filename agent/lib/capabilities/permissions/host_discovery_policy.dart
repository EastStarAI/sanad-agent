/// Owner ceiling for the typed host executable discovery tool.
///
/// [ownerOnly] is a permission ceiling, not a presence rule: the tool appears
/// only for a turn with proven owner authority and only when no other
/// tool in that turn already reaches the host `PATH`. [disabled] removes it
/// for every caller. No value exposes it to unverified callers.
enum HostDiscoveryPolicy {
  disabled('disabled'),
  ownerOnly('owner_only');

  const HostDiscoveryPolicy(this.value);

  final String value;

  /// Parses a stored value; unknown values resolve to [disabled].
  static HostDiscoveryPolicy fromStored(String? value) =>
      tryParse(value) ?? HostDiscoveryPolicy.disabled;

  /// Parses an untrusted mutation value; `null` when it is not recognized.
  static HostDiscoveryPolicy? tryParse(String? value) {
    for (final policy in HostDiscoveryPolicy.values) {
      if (policy.value == value) return policy;
    }
    return null;
  }

  /// Whether the discovery tool belongs in a turn's catalog.
  static bool isToolPresent({
    required HostDiscoveryPolicy policy,
    required bool isOwner,
    required bool hasHostPathAccess,
  }) {
    if (policy == HostDiscoveryPolicy.disabled) return false;
    if (!isOwner) return false;
    return !hasHostPathAccess;
  }
}
