/// Raised when canonical history cannot satisfy an active compaction boundary.
class ModelProjectionException implements Exception {
  final String message;

  const ModelProjectionException(this.message);

  @override
  String toString() => 'ModelProjectionException: $message';
}
