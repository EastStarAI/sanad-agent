/// Where a workspace executes host commands.
///
/// [direct] runs commands on the host with the inherited developer
/// environment (Sanad-owned secrets removed). [protected] requires an isolated
/// sandbox backend and fails closed when none is available; it never falls
/// back to the host.
enum ExecutionMode {
  direct('direct'),
  protected('protected');

  const ExecutionMode(this.value);

  final String value;

  /// Parses a value from a trusted source (the daemon database).
  ///
  /// An unknown stored value resolves to [protected], the restrictive posture,
  /// so a value written by a newer agent never widens host access here.
  static ExecutionMode fromStored(String? value) =>
      tryParse(value) ?? ExecutionMode.protected;

  /// Parses an untrusted mutation value; `null` when it is not recognized.
  static ExecutionMode? tryParse(String? value) {
    for (final mode in ExecutionMode.values) {
      if (mode.value == value) return mode;
    }
    return null;
  }
}
