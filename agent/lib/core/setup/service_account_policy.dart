/// The account and Home a Linux system-scope install uses.
///
/// One rule owns this decision so the installer and `sanad service install`
/// cannot disagree about which account will run the unit:
///
/// * a root install (entered directly or through `sudo`) uses the dedicated
///   `sanad-agent` account and its `/var/lib/sanad-agent` Home;
/// * `SUDO_USER` never selects the unit account, because `install.sh` cannot see
///   the Agent's next decision and a root Home systemd cannot traverse failed
///   with `203/EXEC` after the device authorization was already spent;
/// * an operator may name an existing account explicitly, which is the only way
///   a system unit runs as anything other than the dedicated account.
///
/// A non-root install never reaches this policy: it runs as the caller, which is
/// also the account the installer places the artifact for.
abstract final class SystemServiceAccount {
  /// The unprivileged account a root install registers the unit for.
  static const String dedicatedUser = 'sanad-agent';

  /// The Sanad Home of [dedicatedUser]; its passwd home directory is the same
  /// path, so the account owns the artifact, the state, and the logs.
  static const String dedicatedHome = '/var/lib/sanad-agent';

  /// Whether a system-scope install registers the [dedicatedUser] account.
  ///
  /// [runAsUser] is the explicit operator override; an empty or null value
  /// means the operator did not choose, so only a root install selects the
  /// dedicated account. Naming [dedicatedUser] itself keeps the dedicated
  /// path (and the Home ownership it manages).
  static bool usesDedicatedAccount({required bool isRoot, String? runAsUser}) {
    final requested = runAsUser?.trim() ?? '';
    if (requested.isEmpty) return isRoot;
    return requested == dedicatedUser;
  }
}
