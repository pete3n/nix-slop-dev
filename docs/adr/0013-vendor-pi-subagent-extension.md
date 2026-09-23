# Vendor the pi subagent extension for local coordinator→workers

opencode reaches the B2 coordinator→workers topology
([ADR-0011](0011-multi-endpoint-local-ai.md)) natively: its config has a
first-class `mode = "subagent"` agent type the coordinator delegates to. pi has
no built-in subagent mechanism — delegation lives in an **example extension**
(`packages/coding-agent/examples/extensions/subagent`) that ships in the pi repo
but not in the published binary. To give pi the same local orchestration we must
get that extension into the jailed pi's user-scope extensions dir, and a child
`pi` it spawns must run inside the same jail.

## Decision

- **Vendor the extension at a pinned commit.** Copy `subagent/{index.ts,agents.ts}`
  (only those two — the runtime needs nothing else) plus the upstream MIT
  `LICENSE` into `lib/slop-env/profiles/pi-subagent-ext/`, pinned to pi commit
  `0d145e89`, with provenance in `VENDORED.md`. This tracks a known-good upstream
  rather than re-implementing delegation in the profile.
- **Ro-bind into the jail, gated on a coordinator topology.** The vendored
  `subagent/` is read-only bound at `~/.pi/agent/extensions/subagent` only when
  `localAiEndpoints` declares a coordinator. pi auto-loads user-scope extensions
  (enabled by default, no trust prompt), so the coordinator gains the `subagent`
  tool with no settings entry.
- **Child-pi runs in the jail (Slice 5 resolution).** The extension spawns a
  child `pi --mode json -p --no-session --model ollama-<name>/<id>` per worker.
  For that child to resolve and run confined, **`pi` is added to the jail PATH**
  (`add-pkg-deps [ pi-pkg ]`) whenever `localAiEndpoints` is set. The packaged pi
  re-execs `node …/.pi-wrapped`, so a PATH entry suffices; the child is a
  descendant of the already-confined coordinator and inherits the jail+Sandbox
  with no nesting. No symlink/argv hacks were needed.
- **Workers are declarative `.md` files.** One `~/.pi/agent/agents/<name>.md`
  per non-coordinator endpoint, frontmatter `name`/`description = role`/`model =
  ollama-<name>/<id>`. Because pi parses frontmatter with the eemeli `yaml`
  library **unguarded** (a malformed scalar crashes agent discovery), every value
  is emitted as a double-quoted scalar with `\` and `"` escaped (`yamlQuote`).
- **Mark pi's path experimental.** opencode's native subagent path is stable;
  pi's vendored path carries upstream-coupling and runtime risks (see below) and
  is documented as experimental.

## Considered Options

- **Re-implement delegation in `pi.nix`.** Rejected: duplicates upstream, drifts,
  and owns a moving target (pi's tool/extension API).
- **Depend on pi's example dir at runtime / fetch it.** Rejected: not in the
  published binary, and the offline jail cannot fetch; vendoring is reproducible
  and offline.
- **Vendor the whole example dir.** Rejected: only `index.ts` + `agents.ts` are
  loaded; a minimal bind keeps the ro source surface exactly those two files.

## Consequences

- The vendored copy must be re-synced when upstream changes (tracked in
  `VENDORED.md`); the pin makes drift explicit.
- Two runtime properties cannot be verified in the offline jail and are HITL/CI:
  jiti's `fsCache` writing under a read-only extension dir (mitigation:
  `JITI_FS_CACHE=false`), and packaged-pi ESM `import.meta.resolve`. The HITL
  procedure lives in `$CLAUDE_EXCHANGE_DIR/test-local-ai-orchestration.md`.
- Adding a coordinator config to the pi-agent template moves its
  `template-pi-agent-drv.expected` hash (the extension bind + generated agents
  change the devShell derivation); that snapshot is regenerated in CI/HITL.
