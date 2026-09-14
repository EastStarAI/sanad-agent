# Public Service Endpoints Contract

## Scope
This contract applies to `shared/public_service_endpoints/`.

## Ownership
- Own the canonical non-secret public Production and explicit Local service endpoints shared by the Client and developer tooling.
- Keep this package Pure Dart and independent of Client, Agent, Flutter, and developer-tool implementations.
- Hosted Development and Staging profiles use public Production services unless an owning private runtime injects explicit endpoint overrides; tracked profiles never own private environment values.
- Add a new environment mapping only with matching Client and developer-tool verification; never duplicate endpoint literals in consumers.
