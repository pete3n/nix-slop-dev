# Multi-endpoint local AI with a coordinator→workers topology

The Slop Env shipped a single, hardcoded local-AI provider — one Ollama at
`http://localhost:11434/v1`, gated by the `enableLocalAi` bool — surfaced
identically to both the pi and opencode Agent Profiles. That forecloses two real
needs: (1) users running **more than one** local model server (e.g. one per GPU,
forwarded to distinct loopback ports), and (2) a **fully-local
coordinator→workers** orchestration (the "B2" topology in
[`CONTEXT.md`](../../CONTEXT.md)) where a capable model delegates scoped subtasks
to smaller local models. We introduce the **Local AI Endpoint** as a first-class,
list-valued config concept.

## Decision

- **A single `localAi` module option replaces the flat toggle.** Following the
  NixOS-module idiom, the public option is `localAi = { enable; settings = {
  endpoints = [...]; }; }`. `enable` (default false) is the master switch: when
  false, `settings` is ignored entirely — so a template can ship a complete
  example config that stays inert until enabled. Each `settings.endpoints` entry
  is `{ name; port; models = [{ id; name?; reasoning? }]; role?; coordinator?;
  default? }` and becomes exactly one provider keyed `ollama-<name>` in the
  profile's config (opencode `opencode.json`; pi `models.json`). Endpoints are
  **port-only** — the loopback base URL is derived, never supplied (see
  [ADR-0012](0012-port-only-loopback-local-ai.md)). With `enable = true` and an
  empty `endpoints` list, the legacy single `localhost:11434` provider is used.
- **Threaded through the public API, consumed per profile.** `localAi` flows
  through `mkShell`/`mkBins` and both per-OS engines into the pi and opencode
  profiles. Claude takes no local-AI path. A disabled or omitted `localAi`
  reproduces today's no-local-AI config **byte-for-byte**.
- **Coordinator→workers (B2) is opt-in via two endpoint flags.** Exactly one
  endpoint may be marked `coordinator = true`: it becomes the launch/default
  model **and is excluded from the worker pool** (so no loopback port hosts both
  coordinator and worker — avoids `OLLAMA_MAX_LOADED_MODELS=1` eviction). Every
  non-coordinator endpoint becomes one worker (opencode `mode = "subagent"`; pi a
  generated `~/.pi/agent/agents/<name>.md`), with `model = ollama-<name>/<id>`
  and `description = role`. Launch-model precedence is **coordinator → a single
  `default = true` endpoint → the built-in anthropic model**; more than one
  coordinator or default is a hard eval error. A `default` endpoint sets only the
  launch model (no workers).
- **opencode's path is stable; pi's is experimental.** opencode has native
  subagent support; pi reaches B2 via a vendored extension
  ([ADR-0013](0013-vendor-pi-subagent-extension.md)).
- **Byte-equality is load-bearing.** All new emission is gated on
  `localAi.enable` (and, for the worker topology, a declared coordinator), so the
  default templates — which ship example endpoints with `enable = false` — keep
  their pinned `template-*-drv` hashes unchanged.

## Considered Options

- **Keep a single provider, document manual `models.json` edits.** Rejected: it
  pushes per-GPU fan-out and the worker topology onto every user by hand, with no
  back-compat guard and no liveness feedback.
- **Free-form provider descriptors (arbitrary `baseUrl`).** Rejected on security
  grounds — see [ADR-0012](0012-port-only-loopback-local-ai.md).
- **A bespoke pi subagent implementation.** Rejected: re-implementing delegation
  inside the profile duplicates upstream work that already exists as an example
  extension; vendoring tracks upstream (ADR-0013).

## Consequences

- Multi-GPU and local-first orchestration work offline through the existing jail
  with no new trust surface beyond the loopback ports the user tunnels.
- The feature's behaviour is pinned by the pure-eval check `tests/local-ai-config.nix`
  (one provider per endpoint, coordinator/worker derivation, precedence, the
  liveness probe, and back-compat), independent of any network or real server.
- pi's experimental path adds a vendored dependency to keep current (ADR-0013).
