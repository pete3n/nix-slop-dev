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

## Addendum (issue 16): IP-literal carve-out for L3 parity with Linux

The proxy is HTTP `CONNECT` + SOCKS5: TCP-only. Linux's
`IPAddressAllow=<cidr>` (systemd cgroup eBPF) is L3: it permits ICMP, raw
sockets, and arbitrary L4 protocols to allowed IPs. Without a parity fix
`ping 192.168.1.1` fails on macOS even when the IP is in the whitelist —
the deny-default Seatbelt rule fires on the ICMP send before the proxy
ever sees the request.

We close this gap with a **per-IP-literal Seatbelt allow rule** emitted
alongside the loopback proxy pin. For each IPv4 literal in the runtime
whitelist (persistent file + `-a` flag), the wrapper emits one
`(allow network-outbound (remote ip "<ip>:*"))` line into the profile
before `sandbox-exec` loads it. The wildcard port covers TCP, UDP, and
non-port protocols (ICMP, raw sockets). Spike 07's finding that
`remote ip` rejects IP literals does NOT apply: that finding was about
the `host` portion of `(remote ip "host:port")`; literal IPv4 octets
ARE accepted there — the parser only rejects the special non-octet
forms beyond `*` and `localhost`. (Verified empirically during issue 16
HITL.)

Hostnames remain exclusively on the proxy. They were never candidates
for direct L3 access — proxy-side hostname enforcement is what provides
the dynamic-DNS + cert/SNI inspection guarantees this ADR's threat model
relies on. `ping example.com` continues to fail on macOS by design.

CIDR (`*/*`) and IPv6 (`*:*`) whitelist entries are passed through to
the proxy for TCP only (no L3 carve-out yet). The macOS SBPL `(remote
ip)` syntax does not natively accept CIDR; expanding a CIDR into per-host
allow lines is impractical for anything larger than /28. IPv6 literal
SBPL shape (likely `(remote ip "[2001:db8::1]:*")` form) needs an
empirical spike. Both gaps are tracked as follow-up issues.

The runtime composition uses GNU sed's `r filename` + `d` block idiom to
splice an `__IPALLOWLIST__` placeholder line in the SBPL template with
the assembled IP allow block — or to delete the placeholder when no IP
literals are present, preserving byte-equality with the pre-issue-16
profile shape for hostname-only whitelists.
