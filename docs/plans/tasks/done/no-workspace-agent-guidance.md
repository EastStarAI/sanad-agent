# No-workspace agent guidance

## Goal

Give the model one concise runtime-context sentence when a conversation has no attached workspace, so workspace-dependent requests direct the user to the workspace control instead of receiving no workspace context.

## Definition of Done

- Fresh turns and suspended resumes without a valid workspace receive the same concise guidance.
- Workspace-backed context remains unchanged.
- Focused tests and Dart analysis pass.
- Capability runtime documentation reflects the behavior.
