String resolveUserDisplayName({required String username, Object? displayName}) {
  final normalizedDisplayName = displayName?.toString().trim() ?? '';
  return normalizedDisplayName.isNotEmpty ? normalizedDisplayName : username;
}
