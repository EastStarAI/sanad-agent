/// Policy controlling host capability and executable discovery.
///
/// [disabled]: Host discovery is disabled completely. The discovery tool is omitted
/// from the runtime catalog.
/// [ownerOnly]: Host discovery is allowed only for authenticated owners, AND ONLY
/// when the session does not already have equivalent host execution access (e.g. direct shell).
enum HostDiscoveryPolicy {
  disabled('disabled'),
  ownerOnly('owner_only');

  const HostDiscoveryPolicy(this.value);

  final String value;

  static HostDiscoveryPolicy fromValue(String? value) {
    for (final policy in HostDiscoveryPolicy.values) {
      if (policy.value == value) {
        return policy;
      }
    }
    return HostDiscoveryPolicy.ownerOnly;
  }
}
