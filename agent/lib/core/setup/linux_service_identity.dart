/// The account a Linux service definition runs as, and the directories that
/// hold its definitions.
class LinuxServiceIdentity {
  const LinuxServiceIdentity({
    required this.userName,
    required this.groupName,
    required this.uid,
    required this.home,
    required this.isRoot,
    this.dedicated = false,
  });

  final String userName;
  final String groupName;
  final int uid;
  final String home;
  final bool isRoot;

  /// True while [userName] is the dedicated account this Agent manages, whose
  /// Home it creates and restricts.
  final bool dedicated;
}

class LinuxServicePaths {
  const LinuxServicePaths({
    this.systemUnitDirectory = '/etc/systemd/system',
    this.openRcInitDirectory = '/etc/init.d',
    this.systemdRuntimeDirectory = '/run/systemd/system',
    this.userRuntimeDirectory = '/run/user',
  });

  final String systemUnitDirectory;
  final String openRcInitDirectory;
  final String systemdRuntimeDirectory;
  final String userRuntimeDirectory;
}
