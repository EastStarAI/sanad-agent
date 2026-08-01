# Sanad Agent Release Contract

Sanad Agent compiles to a native executable for macOS, Linux, and Windows.
GitHub Releases owns immutable public binaries and their checksums/signatures.
Official installer scripts download those verified assets.

## Source and distribution ownership

- Agent source, compilation, updater behavior, and release automation belong
  to this repository.
- Building the native executable does not require the source code of the
  optional hosted Portal or Gateway.
- GitHub Releases is the immutable artifact source used by installers and the
  updater.
- Public checksums and verification material can be published with the
  release; private signing and deployment credentials cannot.

## Required assets

- `sanad-agent-<version>-macos-arm64`
- `sanad-agent-<version>-macos-x64`
- `sanad-agent-<version>-linux-x64`
- `sanad-agent-<version>-windows-x64.exe`

The release workflow must verify each asset's platform and architecture,
version output, checksum/signature, clean installation, service lifecycle,
update, rollback, and uninstall behavior.

Artifact naming is a compatibility contract shared by the workflow, install
scripts, user documentation, and updater. A release must fail rather than
publish when one of those consumers expects a different name or target.

## Updating

The installed `sanad` command updates from the public
`EastStarAI/sanad-agent` GitHub Releases channel:

```bash
sanad update
```

The updater must select the correct target, verify release metadata, and use a
safe replacement path appropriate to the operating system.

The release manifest and updater implementation are shared through
`release/contract/`; the CLI and local daemon both delegate replacement
to `AgentUpdateService`. Source/FVM execution returns `source_managed` and never
modifies Git.

Update validation includes upgrading from the previous supported release,
preserving Sanad Home and service registration, recovering from an interrupted
replacement, and returning to the previous version through the documented
rollback path.

Release automation, public verification material, and asset naming belong to
this repository. Signing keys and deployment credentials never enter the
source tree.
