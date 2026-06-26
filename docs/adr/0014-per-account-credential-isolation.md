# Per-Account credential isolation for simultaneous multi-team agent runs

ADR-0009 deliberately kept agent auth **global** — one `.credentials.json` /
`auth.json` per host user — "so a user logs in once across projects." That
forecloses a real need: users with multiple team accounts (a mix of OAuth
subscription logins and API keys) who must run agents under *different*
accounts at the same time. A single shared credential file cannot hold two
OAuth tokens and is clobbered by concurrent atomic writes. We introduce an
**Account** (see [`CONTEXT.md`](../../CONTEXT.md)): one authentication identity,
orthogonal to both Agent Profile and projectName, selected per agent run.

## Decision

- **Closed Nix registry.** A Slop Env declares its Accounts in a Nix-level
  `accounts` attrset (each `type = "oauth"` or `type = "apikey"` + `keyFile`)
  plus a `defaultAccount`. The active Account is the launch-time
  `NIX_SLOP_DEV_ACCOUNT` override, else the project default. An Account not in
  the registry is **refused** — the agent never launches — matching the jail
  and Sandbox's deny-by-default posture.
- **Secrets never enter the store.** For API-key Accounts the registry holds a
  runtime `keyFile` path (e.g. `/run/agenix/…`), not a key. The launcher reads
  it at invocation and forwards `ANTHROPIC_API_KEY` scoped to the single jailed
  exec — never a global export. This composes with agenix/sops/manual files
  without coupling the lib to any one secrets framework.
- **Storage split.** Credentials are stored **per-Account**
  (`~/.local/state/claude/accounts/<acct>/.credentials.json`), reused across
  projects — a faithful "log in once per team." Session state is stored **per
  Account-and-project** (`~/.local/state/claude/projects/<proj>/<acct>/`), so
  the same project under two Accounts at once never clobbers `.claude.json` or
  sessions. The existing credential graft is reused unchanged; only its source
  path becomes Account-qualified.
- **Account joins the Agent Profile contract.** It is an agent-agnostic
  concept each profile fulfils (how it grafts per-Account credentials and
  Account-qualifies sessions), not Claude-specific logic — consistent with
  ADR-0009's rejection of a second divergent build path.

## Considered Options

- **Open / convention-only labels** — any selector value spins up a credential
  dir. Rejected: a typo silently creates an empty-login Account, and API-key
  Accounts have no way to resolve their secret. Fails the deny-by-default bar.
- **Runtime registry file or direct agenix/sops coupling** — rejected in favor
  of a Nix-declared registry + framework-agnostic `keyFile`, keeping config in
  one place and working on non-NixOS Linux and macOS too.
- **Symmetric file-based auth on macOS** — block the keychain so macOS also
  uses per-Account files. Rejected: blocking `/usr/bin/security` surfaces the
  Seatbelt denial as EPERM rather than a clean fallback, and Claude writes back
  to the keychain when reachable — fragile.

## Consequences

- **Platform asymmetry (documented, user-facing).** Per-Account isolation is
  delivered on **Linux only** this pass — full OAuth + API-key multi-Account.
  On **macOS the launcher refuses a non-empty `accounts` registry at
  evaluation** with a clear error, rather than silently giving broken
  isolation: Claude's macOS OAuth token lives in the system keychain, which has
  a single slot for its service entry, so a second OAuth Account could never
  "take". A cross-platform Slop Env must therefore gate `accounts` on
  `pkgs.stdenv.isLinux`. (An earlier draft of this ADR proposed letting macOS
  keep API-key multi-Account while OAuth stayed single-identity; the shipped
  decision is the stricter eval-time refusal above, so the asymmetry is not
  mistaken for a bug.) Lifting this — file-based per-Account auth on macOS — is
  deferred; see the rejected "symmetric file-based auth on macOS" option above
  for why blocking the keychain is fragile.
- **Scope this pass.** Claude on Linux is implemented and tested first as the
  proving ground; Pi and opencode follow the same profile contract later
  (opencode's cwd-keyed global SQLite db needs a per-Account db — deferred).
- **Entry-point scope.** Accounts work only through the template /
  `mkShell` / `mkBins` path the consumer controls. Zero-touch `apps` keep
  today's single-credential behavior, since a prebuilt app cannot receive a
  consumer registry — the same template-only scoping ADR-0009 applied to Pi.
- **Backward compatible.** Zero Accounts declared and no selector reproduces
  today's shared-credential behavior byte-for-byte, preserving the
  `tests/template-claude-code-drv.expected` baseline.
- Supersedes ADR-0009's "auth stays global so a user logs in once" consequence
  for the Account-enabled path; the no-Account path is unchanged.
