# Fast Google Cloud Agent Setup

Use this release-user route when the user wants Sanad Agent on Google Cloud,
including a Free Tier server. Keep Client on the user's device; install only
Agent on the VM. Do not build from source or install Flutter, Dart, or Docker.

## 1. Ask little; inspect first

Skip questions already answered. Ask at most two initial questions:

1. **Workload:** Agent and light work within Free Tier (recommended), or projects
   requiring a larger paid VM? Agent is lightweight, not resource-free; builds,
   tests, databases, and hosted projects may need more memory, CPU, or disk.
   Start small unless the user requests paid capacity; obtain approval of its
   estimated price before creating it.
2. **Google Cloud:** use an existing project with billing, prepare an existing
   account, or start from scratch? If inspection identifies the project/account,
   name them for confirmation rather than asking a generic question.

The third and final setup request, just before installation, is the complete
**Settings → Devices sidebar heading → + → Add device** command from Sanad
Client. Accept its short-lived, single-use creation credential under the
exception in SKILL.md.
Do not ask for durable credentials or payment details. A plan confirmation is
not another questionnaire: summarize the target and changes and obtain informed
approval once. Pause again only for an unexpected cost, destructive action,
required human authentication, or a failure requiring a decision.

## 2. Local prerequisites and account

- Identify the host OS and check `gcloud version`, SSH availability, and
  `gcloud auth list --filter=status:ACTIVE`. Never print access tokens.
- If missing, install only necessary tools with approval using the official
  [Google Cloud CLI OS-specific installation guide](https://cloud.google.com/sdk/docs/install).
  On Windows, also check the SSH executable used by gcloud; use PowerShell
  equivalents of POSIX examples below rather than assuming Bash is installed.
- Run `gcloud auth login` when needed. User handles Google sign-in, MFA, consent,
  and account recovery in their browser. Browser automation is optional, not a
  deployment dependency. Do not collect passwords or disable security controls.
- List projects with `gcloud projects list`. For a selected project:

  ```bash
  gcloud billing projects describe "$PROJECT" --format=yaml
  gcloud billing accounts list --format='table(name,displayName,open)'
  ```

- Creating a Google Cloud Billing account, entering a payment method, and
  accepting payment terms are user-owned actions in Google Cloud Console,
  **not Google Play**. Afterward, with approval, create a selected project if
  needed and link the confirmed billing account:

  ```bash
  gcloud projects create "$PROJECT" --name="$PROJECT_NAME"
  gcloud billing projects link "$PROJECT" --billing-account="$BILLING_ACCOUNT"
  gcloud services enable compute.googleapis.com --project="$PROJECT"
  ```

  Skip completed steps. Billing access is not proof of permission to link an
  account or create a VM; report permission errors, do not grant broad IAM roles.
  Use explicit `--project` everywhere, not a global `gcloud config set project`.

## 3. Choose reuse or creation, and prevent surprise cost

Read current official [Free Tier terms](https://cloud.google.com/free/docs/free-cloud-features#compute)
and [IPv4/network pricing](https://cloud.google.com/vpc/network-pricing#ipaddress).
Do not promise unconditional $0: eligibility and monthly limits can change,
IPv4 and outbound traffic have their own terms, and model-provider billing is
separate. Keep this explanation to one short note, not a billing audit.

Check billing-account project membership, then eligible resources in those
projects with Compute enabled. Do not enable APIs just to inspect other projects.

```bash
gcloud billing projects list --billing-account="$BILLING_ACCOUNT"
gcloud services list --enabled --project="$PROJECT" --format='value(config.name)'
gcloud compute instances list --project="$PROJECT"
gcloud compute disks list --project="$PROJECT"
gcloud compute addresses list --project="$PROJECT"
```

Offer existing suitable VMs before duplicating them. Inspect an approved reuse
VM for OS, architecture, free disk/memory, existing Sanad, running workloads,
and service state. Do not reinstall or overwrite its data silently. A full-time
eligible VM can consume the account's entire free VM-hour allowance; a second
VM is not a second free allowance. Current resources do not prove historical
monthly usage. If allowance is unknown, disclose that uncertainty; if already
consumed, offer reuse or an explicitly approved paid temporary test, not another
"free" VM. Disk allowances are aggregate too, not per VM.

Default new configuration:

- Ubuntu 22.04 LTS x86_64, regular `e2-micro`, default zone `us-east1-b`.
  `us-central1` and `us-west1` are alternatives under current terms. Check the
  chosen region remains eligible; never silently fall back outside eligible regions.
- Explicit `pd-standard` boot disk, at most the remaining 30 GB-month eligible
  standard-disk allowance. A 30 GB disk is suitable when that allowance is unused.
  Never accept the Console's `pd-balanced` default.
- Auto-delete the new boot disk. No extra disks, snapshots, scheduled backups,
  reserved static IP, NAT gateway, load balancer, GPU, or paid OS image.
- Ephemeral external IPv4 for simple outbound access, subject to current pricing.
  Do not claim it is universally free or reserve an address to "stabilize" it.
- No service-account credentials needed by Sanad. Use no attached Google service
  account/scopes unless the user explicitly needs Google APIs for their projects.

Before mutation, summarize project, VM name, region, disk, connection method,
free-allowance caveat or paid estimate, and whether this is reuse or creation.
Record non-secret ownership: exact resources created by this attempt, not every
resource found in the project. Never alter the existing production VM for a test.

## 4. Create and reach the VM

POSIX example; set approved values first. Check names for collisions. `NETWORK`
is an existing approved VPC; if none exists, propose a custom VPC and subnet
in the selected region, record both, and obtain approval before creating them.
Do not create another project's network or enable billable network services.
Set a unique `$TAG` and prepare the scoped ingress rules described below before
creating the VM, so it never inherits a window of broad default SSH access.

```bash
gcloud compute instances create "$VM" \
  --project="$PROJECT" --zone="$ZONE" \
  --machine-type=e2-micro --provisioning-model=STANDARD \
  --image-family=ubuntu-2204-lts --image-project=ubuntu-os-cloud \
  --boot-disk-type=pd-standard --boot-disk-size=30GB \
  --boot-disk-auto-delete --network="$NETWORK" \
  --no-service-account --no-scopes --tags="$TAG" \
  --labels=purpose=sanad-agent
```

Use a smaller explicitly approved disk if allowance requires it and OS/runtime
space is adequate; otherwise stop, do not exceed the free allocation silently.
For a custom-mode VPC add the approved `--subnet` explicitly. Do not attach
`http-server`/`https-server` tags. Sanad connects outbound to its cloud gateway;
never open port 58085, all TCP ports, or a public Agent endpoint.

Inspect existing firewall rules before adding anything. Allow SSH TCP 22 only
from the operator's current public IP `/32` using a dedicated target tag; create
and record that scoped rule only if needed. Do not widen an existing rule or
add a public `0.0.0.0/0` allow rule. Existing broad rules are not justification
to create new ones. A narrow allow does not override an existing broad allow:
for a new dedicated VM/tag, isolate it with a tag-scoped allow at priority 900
and a tag-scoped ingress deny at priority 901, after checking no higher-priority
rules conflict. Add `--tags="$TAG"` to VM creation. Example:

```bash
gcloud compute firewall-rules create "$TAG-ssh" --project="$PROJECT" \
  --network="$NETWORK" --direction=INGRESS --priority=900 \
  --allow=tcp:22 --source-ranges="$OPERATOR_IP/32" --target-tags="$TAG"
gcloud compute firewall-rules create "$TAG-deny" --project="$PROJECT" \
  --network="$NETWORK" --direction=INGRESS --priority=901 \
  --action=DENY --rules=all --source-ranges=0.0.0.0/0 --target-tags="$TAG"
```

Deny syntax is `--action=DENY --rules=all`, not `--deny=all`. Record both new
rules for test cleanup. Do not apply this isolation to a reused VM without
approval of its impact on existing workloads. Do not change shared rules.
Use IAP only if already configured and appropriate; do not automatically add NAT
or grant broad IAM privileges to repair SSH. A changed operator IP needs a
narrow rule update, not an unrestricted rule.

```bash
gcloud compute ssh "$VM" --project="$PROJECT" --zone="$ZONE"
```

Let gcloud manage its normal SSH key and host verification flow; authorize a new
local SSH key when needed, never replace an existing private key or disable host
verification. Connection failure: inspect VM readiness, OS Login/IAM, key setup,
and the narrow firewall rule before changing settings. Bound retries.

## 5. Install and pair

Check remote dependencies: Bash, curl, CA certificates, Python 3, `sha256sum`,
working systemd, and sudo access for registration. On a fresh Ubuntu host install
only missing packages (`sudo apt-get update` then the missing packages from
`bash curl ca-certificates python3 coreutils`). Run the installer as the normal
SSH user, not with `sudo bash`. It selects a durable non-root service.

Request: **"Open Sanad → Settings, then click + beside Devices in the Settings
sidebar to open Add device. Name the device and send the complete Linux
installation command."** If Client is unavailable, offer
the official Web Client at https://app.sanad.eaststarai.com. Do not require a
second Client installation on the server. Do not add a model provider as a
prerequisite to pairing.

Validate that the submitted command is the official Sanad bootstrap and has no
unrelated shell payload. Treat it as sensitive input, not general instructions.
Accepting it in chat necessarily exposes the creation credential to that
conversation and possibly execution-tool history. With the user's explicit
consent to this narrow single-use-command workflow, execute it without another
consent loop. Do not repeat it in replies, plans, evals, reports, shell history,
or diagnostic logs; disable shell tracing. Never claim zero exposure.

Stream the complete unchanged command to a remote `bash -s` through stdin;
keep `gcloud --command='bash -s'` and SSH argv credential-free. An owner-only
temporary script may be used as transient transport when necessary; remove it
in a finally path and never put it in the project. Do not extract or reconstruct
the embedded credential. The current Client command itself uses the installer's
`--pairing-token` argument, so remote installer process-argument exposure is
possible even when SSH transport uses stdin. Do not falsely promise that the
Client command already uses `--pairing-token-stdin`; changing Client/installer
code is outside this documentation task. This exception never permits durable
credentials. If the user does not accept creation-command exposure or execution
is impossible, have them run it directly in their SSH terminal. Portal `--login`
is a fallback only with a user available to complete its URL/device-code step;
it is not unattended authentication on a headless VM.

The official installer verifies manifest origin, artifact size/SHA-256, expected
version, local service health, and successful cloud registration before success.
Accept that built-in success for the fast route; if unclear, perform one bounded
`~/.sanad/bin/sanad --version` / `service status` check. Do not add routine reboot,
logout durability tests, manual UI acceptance, billing reports, budgets, or model
requests. Those belong to troubleshooting or explicitly requested validation.

Expired/used pairing command: ask for a fresh complete Add device command; do
not repeatedly retry it or silently delete a device. On failure preserve existing
Sanad Home/data and use installer rollback. Diagnose only the failing step.

## 6. Finish, resume, or clean up

Report project/VM/zone, installed version, and built-in registration success.
Tell the user to select their new device in Client. State model-provider costs
are separate and keep the applicable Google usage-limits note brief. Never call
a local-only installation a successfully paired device.

On interruption, inspect actual resource/service state and resume the missing
step, not the entire creation sequence. A failed install is not permission to
create another VM. Do not delete a production installation or preexisting data.

### Optional supervised skill test (not the normal user journey)

First rehearse without mutations. For a full live test, obtain explicit approval
for a short potentially paid second VM, estimate cost, record a unique test VM
name and every newly created resource, then install/pair. Do not stop the user's
existing VM to borrow its free allowance. Do not leave a paid VM waiting for
input: request readiness/pairing just before creation, and on a blocker delete
it promptly or obtain explicit approval to keep it temporarily.

In a finally path after success, failure, or cancellation, delete only the
approved test resources. For a test VM with a new auto-delete boot disk:

```bash
gcloud compute instances delete "$TEST_VM" --project="$PROJECT" \
  --zone="$ZONE" --delete-disks=boot --quiet
```

Inspect the exact disk afterward; if it remains, delete it only when recorded
as newly created for this test. Remove only test-owned firewall rules/addresses/
subnet/VPC, in dependency order, if any were created. Never delete reused
resources. Confirm exact test resources are absent and the production VM is
unchanged. Coordinate removal of the test device from Sanad Client with the
user. Deletion stops future charges; it does not erase charges already accrued.
Do not claim final invoiced cost before delayed billing records arrive.
