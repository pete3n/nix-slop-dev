## What to build

A spike on real macOS hardware validating the three load-bearing Seatbelt assumptions from ADR-0001 before any darwin implementation starts:

1. `(deny network*)` with `(allow network-outbound (remote ip "..."))` allowlists actually filters by remote IP on current macOS versions
2. DNS resolution under that profile — what allow rules mDNSResponder needs
3. Sandbox violations are visible to the invoking user in the unified log, and a workable `log` predicate exists for them

Deliverable: a findings note plus minimal working `.sbpl` samples committed to the repo (e.g. under `docs/spikes/`).

## Acceptance criteria

- [ ] Each of the three questions answered with tested evidence on a current macOS version (ideally both architectures)
- [ ] A sample profile demonstrates: curl to an allowed IP succeeds, all other destinations blocked
- [ ] A documented `log` predicate reliably captures the blocked attempts
- [ ] ADR-0001 amended if any assumption does not hold

## Blocked by

None - can start immediately
