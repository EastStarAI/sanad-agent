/// Declared-modality evidence grammar shared by endpoint model metadata and the
/// `models.dev` catalog.
///
/// A declaration is evidence only in its own modality form: a modality list
/// establishes image input when it contains `image` or a MIME subtype such as
/// `image/jpeg` (case-insensitively), and establishes a positive text-only
/// declaration when every entry is a non-image modality. A malformed list, or
/// one carrying a wildcard that names no modality (`*`, `*/*`), establishes
/// neither state. Nothing here is inferred from a model name, and no coercion
/// can establish support.
library;

/// Wildcards that claim "any modality" without naming one. They stay
/// unestablished rather than becoming a positive text-only declaration.
const Set<String> _wildcardModalities = {'*', '*/*'};

/// Normalized declared modalities, or `null` when [raw] is not a non-empty list
/// of non-empty strings.
///
/// A malformed complete-list declaration establishes neither state, so a single
/// unusable entry invalidates the whole list.
Set<String>? declaredModalityTokens(Object? raw) {
  if (raw is! List || raw.isEmpty) return null;
  final tokens = <String>{};
  for (final entry in raw) {
    if (entry is! String) return null;
    final token = entry.trim().toLowerCase();
    if (token.isEmpty) return null;
    tokens.add(token);
  }
  return tokens;
}

/// Whether [token] declares image input: the bare modality or any MIME subtype.
bool declaresImageModality(String token) {
  final normalized = token.trim().toLowerCase();
  return normalized == 'image' || normalized.startsWith('image/');
}

/// Whether [token] declares image input in a provider capability list, where
/// `vision` is the native name for the same capability.
bool declaresVisionOrImageModality(String token) =>
    token.trim().toLowerCase() == 'vision' || declaresImageModality(token);

/// Tri-state image-input evidence from a raw declared modality list.
///
/// `true` when an entry declares image input, `false` when the list positively
/// declares modalities without one, and `null` when the declaration is
/// malformed or wildcard-only.
bool? declaredImageModalitySupport(Object? raw) {
  final tokens = declaredModalityTokens(raw);
  if (tokens == null) return null;
  var wildcard = false;
  for (final token in tokens) {
    if (declaresImageModality(token)) return true;
    if (_wildcardModalities.contains(token)) wildcard = true;
  }
  return wildcard ? null : false;
}
