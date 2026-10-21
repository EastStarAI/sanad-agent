# Fast Google Cloud installation skill

## Goal

Extend `install-sanad` with a short interactive packaged-Agent provisioning path
for Google Cloud Free Tier, with informed cost approval, safe reuse, just-in-time
single-use device pairing, and no unnecessary acceptance ceremony.

## Locked scope

Documentation and skill instructions only. Use packaged releases, preserve
existing infrastructure, and accept only the explicitly approved short-lived
creation command; durable credentials remain excluded. No Client, installer,
Agent runtime, release artifact, or cloud production changes belong to delivery.
Optional removal of the offline test-device entry remains user-owned and is
not a blocker for this documentation task.

## Gates

- [x] Review existing installer, installation skill, Linux service ownership,
  and skill-creator guidance.
- [x] Add discoverable Google Cloud reference and narrow creation-token exception.
- [x] Cover local prerequisites, billing/auth handoffs, aggregate free allowance,
  explicit standard disk, remote install, recovery, and temporary-test cleanup.
- [x] Add three realistic evaluation scenarios with verifiable assertions.
- [x] Validate Markdown references, JSON, gcloud command flags, and diff whitespace.
- [x] Rehearse fresh-account, reuse, and paid temporary-test scenarios; fix gaps.
- [x] Run the supervised live test after pairing readiness and cost approval.
- [x] Confirm cloud test-resource cleanup and preserve the original VM.
- [x] Correct the Add device navigation in the skill and project documentation.

## Acceptance Criteria

- [x] A GCP request routes to the specialized reference without the generic source
  installation questionnaire; at most two initial questions and one pairing
  request are used when not already answered.
- [x] Creation uses approved explicit project/zone, eligible VM and `pd-standard`,
  with auto-delete boot disk and no unrequested billable add-ons.
- [x] The full single-use official Add device command may be provided by the user;
  durable credentials and tokens do not enter reports or evaluation artifacts.
- [x] Normal completion relies on installer verified service/cloud registration,
  not routine reboot, billing audit, budget, or provider setup.
- [x] An already consumed allowance prevents another VM being called free.
- [x] Test resources are identified exactly and removed after failure or success;
  no preexisting VM, disk, or user state is changed.

## Evidence boundary

Static validation and rehearsals do not prove a live installation or zero cost.
A pending pairing handoff is reported as pending, never completed. Real test
results are added only after execution, without creation credentials.

A read-only external rehearsal covered the three prompts; this is not a live
benchmark or a baseline comparison. Review found the current Client-generated
command uses `--pairing-token` even though newer service documentation describes
stdin-only authority. The reference now acknowledges the actual command's
process-argument exposure and the user's narrow creation-command consent,
without changing Client code or promising secret-free tool history. Other
review suggestions about account-wide inspection and pre-test readiness were
already covered and remain explicit. Static checks passed for JSON, local links,
all documented VM-create flags against installed gcloud help, and whitespace.

## Supervised live evidence

On 2026-10-15, the user approved a short potentially paid second VM. An isolated
Ubuntu 22.04 x86_64 e2-micro VM with a 30 GB pd-standard auto-delete boot disk
was created in us-east1-b. Two unique tag-scoped firewall rules allowed SSH only
from the operator IPv4 and denied other ingress, without changing shared rules.
All installer prerequisites were already available; the initial SSH attempt
needed a bounded retry while the VM booted. gcloud refreshed its normal public
SSH key metadata; no private key was replaced.

The user corrected navigation to **Settings → + beside Devices in the Settings
sidebar → Add device**, then provided the complete temporary creation command.
It was streamed over SSH stdin without copying its credential into this report.
The official installer completed in about 31 seconds and reported service
Running/Enabled (systemd-user) and successful cloud registration/Agent online.
This is installer health evidence, not an additional manual UI or model test.

The test VM and its boot disk were deleted, and both test firewall rules were
removed. Exact-name resource queries found no remaining test disk/firewall and
no reserved addresses; only the original production VM remained Running.
The default VPC and original VM/disk were preserved. The test device's remote
registration may remain offline in Client until the user removes it; cloud
resource cleanup is complete. No final invoiced amount or zero-cost claim is
made. The user subsequently authorized isolated-worktree commit, PR delivery,
CI verification, merge, and worktree cleanup.

## Definition of Done

- [x] Documentation governance validator and contribution workflow simulations pass.
- [x] JSON, local reference links, gcloud create flags, and diff whitespace validate.
- [x] Real installation/registration and cloud cleanup are verified above.
- [x] Current Add device navigation is consistent across skill and public guides.
- [x] Changes contain no runtime code, durable credentials, private repository
  links, personal paths, or test-resource identifiers.
- No Dart/Flutter analyzer or runtime rerun is required for this docs-only diff;
  repository CI still runs every path-selected mandatory lane.

## Current Status

Implementation and live acceptance complete. Remaining work: PR delivery and
required CI checks, merge, and isolated-worktree cleanup. No further cloud test
or device pairing is needed for delivery.
