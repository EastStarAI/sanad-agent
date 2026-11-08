import 'package:sanad_client/features/provider_setup/data/models/provider_dto.dart';

/// Presentation-only search filtering for the provider picker.
///
/// The agent's provider registry stays authoritative: this helper never sorts,
/// re-ranks, renames, or mutates the catalog it receives, so the order
/// delivered by the daemon survives filtering unchanged. It also holds no
/// state, which keeps provider search out of the cubit and off the protocol.
class ProviderSearchFilter {
  const ProviderSearchFilter._();

  /// Returns the providers matching [query] in their original order.
  ///
  /// An empty or whitespace-only query returns [providers] unchanged.
  static List<ProviderDto> apply(List<ProviderDto> providers, String query) {
    if (isBlank(query)) return providers;
    return <ProviderDto>[
      for (final provider in providers)
        if (matches(provider, query)) provider,
    ];
  }

  /// Whether [provider] matches [query] against its display name, template id,
  /// or any alias the provider template carries.
  ///
  /// The match is trimmed and case-insensitive. Case folding is
  /// locale-independent, so an Arabic query neither throws nor shifts the
  /// surrounding layout direction; RTL rendering stays owned by
  /// `Directionality`.
  static bool matches(ProviderDto provider, String query) {
    final needle = normalize(query);
    if (needle.isEmpty) return true;
    if (_containsNeedle(provider.displayName, needle)) return true;
    if (_containsNeedle(provider.id, needle)) return true;
    for (final alias in provider.aliases) {
      if (_containsNeedle(alias, needle)) return true;
    }
    return false;
  }

  /// Whether [query] carries no searchable text.
  static bool isBlank(String query) => normalize(query).isEmpty;

  /// Trims and case-folds [value] for comparison.
  static String normalize(String value) => value.trim().toLowerCase();

  static bool _containsNeedle(String value, String needle) => normalize(value).contains(needle);
}
