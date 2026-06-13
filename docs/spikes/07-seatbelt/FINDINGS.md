# Spike 07 — Seatbelt validation findings

**Date:** 2026-06-13
**Environment:** macOS 15.6.1 (build 24G90), `aarch64-darwin`, `/usr/bin/sandbox-exec`
**Source ADR:** [`docs/adr/0001-seatbelt-only-on-macos.md`](../../adr/0001-seatbelt-only-on-macos.md)
**Issue:** `07-spike-validate-seatbelt`

## Summary

**Assumption A (remote-IP filtering) is FALSIFIED.** The macOS 15 SBPL parser
rejects IP literals in `(remote ip …)` and `(remote tcp …)` with the error
*"host must be * or localhost in network address"*. Only port-level filtering
is available at the profile-language level.

Assumptions B (DNS) and C (unified-log predicate) were not probed: both are
contingent on a working host-level allow mechanism, which does not exist in
SBPL. They will be revisited once the design pivot is settled.

## Assumption A — IP filtering

> ADR-0001 claim: *`(deny network*)` with `(allow network-outbound (remote ip "…"))`
> allowlists actually filters by remote IP on current macOS versions.*

### Syntax sweep

Each profile body was loaded via `sandbox-exec -f <profile> /usr/bin/true`.
Bodies share the prefix `(version 1) (allow default) (deny network-outbound)`.

| Variant                                       | Load result                                            |
| --------------------------------------------- | ------------------------------------------------------ |
| `(allow network-outbound (remote ip "1.1.1.1:80"))` | **REJECTED:** `host must be * or localhost`            |
| `(allow network-outbound (remote ip "1.1.1.1"))`    | REJECTED: `port missing in network address`            |
| `(allow network-outbound (remote tcp "1.1.1.1:80"))`| **REJECTED:** `host must be * or localhost`            |
| `(allow network-outbound (remote (ip "1.1.1.1")))`  | REJECTED: `illegal function`                           |
| `(allow network-outbound (remote-ip "1.1.1.1"))`    | REJECTED: `unbound variable: remote-ip`                |
| `(allow network-outbound (host "1.1.1.1"))`         | REJECTED: `unbound variable: host`                     |
| `(allow network-outbound (network-filter "1.1.1.1:80"))` | REJECTED: `unbound variable: network-filter`      |
| `(allow network-outbound (remote ip "*:80"))`       | LOADED                                                 |
| `(allow network-outbound (remote ip "localhost:80"))`| LOADED                                                |
| `(allow network-outbound (remote tcp "*:80"))`      | LOADED                                                 |
| `(allow network-outbound (remote udp "*:53"))`      | LOADED                                                 |
| `(allow network-outbound (literal "1.1.1.1"))`      | LOADED — but **no enforcement effect** (see below)     |

The structural error message — *"host must be * or localhost"* — comes from
the parser, not from runtime evaluation. There is no syntax that accepts a
remote IPv4 literal.

### Live enforcement check: port filtering does work

Profile [`profiles/01d-port-only.sbpl`](profiles/01d-port-only.sbpl):

```scheme
(version 1)
(allow default)
(deny network-outbound)
(allow network-outbound (remote ip "*:80"))
```

| Command                                    | Result                              |
| ------------------------------------------ | ----------------------------------- |
| `sandbox-exec -f 01d curl http://1.1.1.1`  | HTTP 301 — connection allowed       |
| `sandbox-exec -f 01d curl https://1.1.1.1` | curl exit 7 — connection refused    |

So `(remote ip "*:<port>")` does enforce port-level filtering.

### Live enforcement check: `(literal …)` is a no-op for network

Profile [`profiles/01e-literal-network.sbpl`](profiles/01e-literal-network.sbpl):

```scheme
(version 1)
(allow default)
(deny network-outbound)
(allow network-outbound (literal "1.1.1.1"))
```

| Command                                    | Result                              |
| ------------------------------------------ | ----------------------------------- |
| `sandbox-exec -f 01e curl http://1.1.1.1`  | curl exit 7 — connection refused    |
| `sandbox-exec -f 01e curl http://1.0.0.1`  | curl exit 7 — connection refused    |

The matching and non-matching destinations are blocked identically. `literal`
is a filesystem-path predicate; the SBPL parser accepts it inside
`network-outbound` but it has no effect on connection decisions.

### Verdict

**ADR-0001 Assumption A does not hold on macOS 15.6.1.** SBPL on this version
filters network rules by direction (`network-inbound` / `network-outbound`),
socket type (`tcp` / `udp` / `ip`), and port; it does **not** filter by remote
IPv4/IPv6 address.

## Assumption B — DNS rules

Not probed. With no host-level filtering available, "what mDNSResponder rules
are needed to allow DNS through the deny-default profile" is no longer the
question — there is no whitelist to punch holes through. Revisit after the
design pivot.

## Assumption C — Unified-log predicate

Not probed. The original intent was to capture *which destination was
blocked*; that signal will only be meaningful once the new design defines
what "blocked" means at the profile level. Revisit after the design pivot.

## Implication

ADR-0001's central mechanism — resolve Host Whitelist → IPs → emit
`(remote ip "<ip>:<port>")` allow rules — is not implementable on current
macOS. Issue 08 cannot proceed in its current form. The downstream issues
(09 violation monitoring, 11 fragment-merge, 12 cross-platform template, 13
darwin module) inherit the dependency.

Possible pivots (not yet evaluated):

1. **PF firewall + Seatbelt split.** The option ADR-0001 explicitly
   rejected. PF can filter outbound by destination IP and by socket-owning
   UID. The rejection cited TCC pain from running the agent under a
   dedicated user; that cost needs to be re-weighed against shipping no
   host filtering.
2. **Userspace proxy.** A local process enforces the Host Whitelist at the
   HTTP/SOCKS layer; Seatbelt restricts outbound to `(remote ip "localhost:<proxy>")`.
   Keeps the `-a <hostname>` CLI surface. Adds a process and only works
   for traffic that honours the proxy.
3. **DNS-only confinement + port restriction.** Run a local resolver that
   only resolves whitelisted hostnames; Seatbelt allows DNS only via the
   local resolver and restricts outbound ports (53/80/443). Bypassable by
   apps using raw IPs; partial but easy.
4. **Drop host filtering on macOS.** Provide port-only confinement and
   document that `-a <hostname>` is a no-op on darwin. Significant semantic
   divergence from Linux.

## Files

- [`profiles/01-ip-filter.sbpl`](profiles/01-ip-filter.sbpl) — original ADR-0001 syntax (rejected)
- [`profiles/01b-remote-tcp.sbpl`](profiles/01b-remote-tcp.sbpl) — `remote tcp` variant (rejected)
- [`profiles/01c-remote-tcp-host.sbpl`](profiles/01c-remote-tcp-host.sbpl) — split-form variant (rejected)
- [`profiles/01d-port-only.sbpl`](profiles/01d-port-only.sbpl) — port-only filter (works)
- [`profiles/01e-literal-network.sbpl`](profiles/01e-literal-network.sbpl) — `(literal …)` no-op demonstration
