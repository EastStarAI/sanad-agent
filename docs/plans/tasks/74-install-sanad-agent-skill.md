# Task 74 — Install Sanad Agent Skill

## Goal Description

Create a repository-owned `install-sanad` skill that a user or developer can
share with an AI agent through a GitHub link. The skill must inspect the local
machine and any explicitly identified checkout, explain the release-user and
source-developer paths, obtain the user's choice and approval, then install or
update Sanad without exposing credentials or overwriting local work.

## Implementation

- Create `.agents/skills/install-sanad/SKILL.md` with one bounded decision flow
  for release installation, remote Agent installation, release updates, source
  setup, and source updates.
- Add UI metadata under `.agents/skills/install-sanad/agents/openai.yaml`.
- Require discovery before mutation, explicit path selection when intent is
  ambiguous, dirty-checkout preservation, official-source verification, and
  post-action health checks.
- Keep pairing credentials in the Client-generated **Add device** command and
  never ask the user to disclose a token to the AI agent.
- Link the skill from both public README quick starts and use direct-choice
  wording for standalone Agent installation.

## Definition of Done

- [x] The skill distinguishes user/release and developer/source workflows.
- [x] The skill checks for an existing installation or explicit local checkout
      before proposing changes.
- [x] The skill explains the benefits and tradeoffs of each path and asks only
      for choices not already explicit in the request.
- [x] The skill covers local Client + Agent, remote Agent-only installation,
      packaged updates, source setup, and source updates.
- [x] The skill protects dirty repositories, tokens, user state, and service
      lifecycle boundaries.
- [x] README.md and README.ar.md link to the shareable skill.
- [x] Skill validation and repository documentation checks pass.
- [x] No staging, commit, or push occurs before human review.

## Success Test Scenario

```bash
ruby scripts/community/validate_governance.rb
git diff --check
rg -n "install-sanad|Add device" README.md README.ar.md .agents/skills/install-sanad/SKILL.md
```

Manually review the skill against these prompts:

1. "Install Sanad for normal use on this Mac."
2. "Install only the Agent on my remote Linux server."
3. "Set up this existing Sanad checkout for development."
4. "Update Sanad without losing my uncommitted changes."

## Verification Evidence

- Skill Creator `quick_validate.py` — passed (`Skill is valid!`).
- Independent read-only forward test — detected the installed development
  command and official checkout, explained both paths, asked for the user's
  choice, and performed no mutation.
- `git diff --check` — passed.
- The skill is 218 lines and contains no template TODO markers.
