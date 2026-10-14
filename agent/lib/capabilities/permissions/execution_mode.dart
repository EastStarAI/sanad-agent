/// The execution posture for a workspace.
///
/// In [direct], the agent executes directly on the host with the developer's
/// ambient environment and tools.
/// In [protected], the agent executes inside an isolated sandbox backend
/// (e.g., container).
enum ExecutionMode {
  direct('direct'),
  protected('protected');

  const ExecutionMode(this.value);

  final String value;

  static ExecutionMode fromValue(String? value) {
    for (final mode in ExecutionMode.values) {
      if (mode.value == value) {
        return mode;
      }
    }
    return ExecutionMode.direct;
  }
}
