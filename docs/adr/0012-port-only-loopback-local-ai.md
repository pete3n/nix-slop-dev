# Port-only loopback for Local AI Endpoints

A Local AI Endpoint ([ADR-0011](0011-multi-endpoint-local-ai.md)) must tell the
agent *where* its model server is. The obvious shape — a free-form `baseUrl` —
would let a config point the jailed agent at an arbitrary host, quietly turning a
"local AI" provider into an exfiltration channel that the Sandbox's egress
allow-list never sees (the agent dials it directly). It would also muddy the
offline story we advertise.

## Decision

- **Endpoints are declared by `port` only; the URL is derived.** A Slop Env
  writes `{ name; port; … }`; the profile constructs `http://127.0.0.1:<port>/v1`
  itself. There is no accepted `baseUrl`/`host` field, so an endpoint can never
  resolve off the loopback interface.
- **Remote servers reach loopback via the user's own SSH tunnel.** A user with a
  remote (or another-host) Ollama maps it to a distinct local port
  (`ssh -L 11435:localhost:11434 …`). The tunnel is the user's responsibility and
  lives entirely outside the jail; the agent only ever sees `127.0.0.1:<port>`.
- **The offline guarantee is narrowed, precisely.** The claim is **"no Sandbox
  egress"**, not "no data leaves the machine." Loopback is intentionally not
  network-confined by the Sandbox, so a local launcher needs zero `--allow`
  hosts and an offline flag (`OPENCODE_DISABLE_MODELS_FETCH=1` / `PI_OFFLINE=1`).
  If the user has tunnelled a remote endpoint, prompt data does travel that
  tunnel — by their explicit `ssh -L` choice, not via agent-initiated egress.
- **A warn-only liveness probe surfaces reachability.** Because the tunnel is
  out-of-band, the devShell shellHook probes each `127.0.0.1:<port>` (bash
  `/dev/tcp`, 1s timeout) and prints per-endpoint status — never blocking entry
  (the user may start the tunnel after entering the shell).

## Considered Options

- **Free-form `baseUrl`.** Most flexible, but defeats the loopback invariant and
  the offline posture, and makes "local AI" a misnomer. Rejected.
- **`host` + `port` constrained to `127.0.0.1`/`localhost` by assertion.**
  Equivalent safety but more surface and a redundant field; deriving from `port`
  is simpler and unambiguous. Rejected as needless.
- **Bind the tunnel inside the jail.** Rejected: tunnels are user credentials and
  host network state; keeping them out-of-band keeps the jail's network policy
  honest (loopback-only) and the lib free of SSH concerns.

## Consequences

- A misconfiguration can at worst reach a *local* port; it can never silently
  egress to an arbitrary host through the agent.
- Documentation (Slice 7) must state the narrowed guarantee explicitly so users
  understand that tunnelling a remote endpoint is a deliberate data-movement
  choice, and verify model availability with `curl localhost:<port>/api/tags`.
