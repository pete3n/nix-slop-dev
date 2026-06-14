# A userspace proxy enforces the Host Whitelist on macOS

Spike 07 (see [`docs/spikes/07-seatbelt/FINDINGS.md`](../spikes/07-seatbelt/FINDINGS.md))
established that macOS 15's SBPL parser structurally rejects remote-IP literals
in `(remote ip …)` and `(remote tcp …)` rules — only `*` or `localhost` are
accepted as the host portion. Seatbelt cannot, on its own, implement the
Sandbox boundary as defined in `CONTEXT.md` (a Host Whitelist enforced
per-invocation). ADR-0001's central claim is therefore void for the network
boundary; the filesystem (Jail) portion of ADR-0001 still stands.

We resolve this by **enforcing the Host Whitelist in a userspace proxy**, with
Seatbelt restricting each sandboxed process's outbound traffic to that
proxy's loopback port. The proxy accepts HTTP `CONNECT` and SOCKS5, matches
the destination hostname against the whitelist, and either splices the
connection or refuses it. The agent sees `HTTPS_PROXY`/`HTTP_PROXY`/`ALL_PROXY`
pointing at `127.0.0.1:<port>`; any traffic that ignores those env vars hits
the Seatbelt deny and fails closed.

We rejected the PF-firewall split (the option ADR-0001 originally cited) on
the priority order *security > complexity > CLI parity*. PF on macOS scopes
rules by socket-owning UID, which forces a dedicated agent user, sudoers
entries, TCC prompts that do not inherit from the calling user, and
root-privileged anchor lifecycle management. The userspace proxy reaches
equivalent kernel-enforced isolation through Seatbelt's loopback pin (the
proxy is the only reachable outbound path), runs entirely as the calling
user with no privilege escalation, and filters on hostnames — distinguishing
co-located destinations on shared CDNs in a way IP filtering cannot.

The proxy is a single-file Go binary, packaged via `buildGoModule` in the
flake. HTTP `CONNECT` covers the bulk of CLI tooling (`curl`, `git`, `npm`,
`pip`, `wget` all honour `HTTPS_PROXY`); SOCKS5 covers `ALL_PROXY`-aware
clients. The proxy never terminates TLS — both protocols expose the
destination hostname before any encrypted payload, so allowlist enforcement
needs no MITM and the in-flight bytes stay opaque to the proxy.

## Consequences

- The Linux whitelist file format (one host per line, hostnames / IPs / CIDRs)
  is reused as-is on macOS; on darwin only the hostname form is meaningful
  to the proxy, but IPs and CIDRs are tolerated as host-form entries (the
  proxy treats them as exact-match hostnames in the `CONNECT host:port`
  string).
- `--wl-add` reports "(next session)" on darwin — the running proxy reads its
  allowlist at startup, mirroring the same semantics `--wl-del` has on Linux.
- The Seatbelt profile is now smaller and uniform across invocations: deny
  network-outbound, allow `(remote ip "localhost:<proxyport>")`, allow
  loopback, plus whatever Mach services the agent needs (mDNSResponder is
  not required — DNS happens inside the proxy on the host side of the
  splice).
- Violation monitoring (`--log`) reports two sources: Seatbelt denials from
  the unified log (an agent attempting non-proxy outbound) and the proxy's
  own denial entries (an agent's `CONNECT` to a non-allowlisted host). Both
  carry the same `sandbox-<binary>-<timestamp>` key as Linux.
- The proxy is a new component to test and maintain. Its hostname-allowlist
  matcher is pure and table-test-driven; the connect/splice path is covered
  by `net/http/httptest` integration tests; end-to-end behaviour under
  Seatbelt remains HITL per the spike's methodology.
- ADR-0001's filesystem-boundary consequences (no `--wl-add` running-session
  update, no nested `sandbox-exec`, no bind-mounts → config materialisation,
  unified-log violation reads) stand unchanged.

## Addendum (issue 16): L3 parity with Linux's `IPAddressAllow` is not implementable

Linux's `IPAddressAllow=<cidr>` (systemd cgroup eBPF) is L3-level: ICMP,
raw sockets, and arbitrary L4 protocols to allowed IPs all pass. macOS
has no equivalent at the Seatbelt profile layer. Issue 16 attempted to
emit per-IP `(allow network-outbound (remote ip "<ip>:*"))` rules; HITL
on macOS 15.6.1 reproduced spike 07's structural rejection
(`host must be * or localhost in network address`). The implementation
was reverted (commit 7cf51d8).

What this means concretely:

- **TCP to whitelisted IP literals already works** via the existing
  proxy path. The proxy's matcher
  (`packages/sandbox-proxy/whitelist/whitelist.go`) accepts IP literals
  as exact-match keys and CIDRs via `net.ParseCIDR`. `curl
  http://192.168.1.1` against a `--wl-add 192.168.1.1`-allowed host
  goes out as `CONNECT 192.168.1.1:80` through the proxy and is
  permitted. No change needed.
- **ICMP / raw sockets to any host** are denied by the base Seatbelt
  rule and cannot be selectively re-allowed per remote IP. `ping <ip>`
  fails on macOS even when the IP is in the whitelist. There is no
  Seatbelt-only fix.
- **Non-proxied UDP** (anything not routed via SOCKS5 UDP-ASSOCIATE,
  which most CLI tooling doesn't use) is in the same boat as ICMP:
  blocked at the deny-default with no per-IP carve-out.

The implementable alternatives were considered and rejected here for
the same reasons ADR-0003 rejected them originally:

- **PF firewall split.** Would give full L3 parity but requires a
  dedicated agent UID (PF scopes by socket-owning UID), sudoers
  changes, TCC prompts that don't inherit, root-privileged anchor
  lifecycle. The userspace proxy was chosen specifically to avoid this
  cost.
- **Universal ICMP allow** (`(remote ip "*:0")` if it loads). Would
  widen the threat model — ICMP-tunnel exfiltration to any host
  becomes possible, however low bandwidth — for limited
  developer-ergonomic benefit. Punted unless a specific workflow
  surfaces the need.

Templates that need `ping` for a known IP should document the macOS
gap as a known divergence from Linux semantics, not paper over it with
a profile-layer hack that doesn't actually work. The user-facing
contract is: `--wl-add <ip>` permits *TCP* to that IP on macOS, same as
on Linux for TCP, but ICMP/raw-socket access matches Linux only when
the user picks a PF-based deployment (out of scope for this ADR).
