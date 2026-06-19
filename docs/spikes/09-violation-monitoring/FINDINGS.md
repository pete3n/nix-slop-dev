# Spike 09 — Seatbelt violation reporting via the unified log

**Date:** 2026-06-13
**Environment:** macOS 15.6.1 (build 24G90), `aarch64-darwin`, `/usr/bin/log`
**Source ADR:** [`docs/adr/0003-macos-sandbox-via-userspace-proxy.md`](../../adr/0003-macos-sandbox-via-userspace-proxy.md)
**Issue:** `09-darwin-violation-monitoring`
**Predecessor:** Spike 07 falsified ADR-0001's host-IP filtering claim; ADR-0003
adopted a userspace proxy. This spike scopes what the OTHER violation
source — Seatbelt denials in the unified log — gives the wrapper's
`sandboxed --log` and live watcher.

## Summary

- **Working predicate** (both `log show` and `log stream`):
  `process == "kernel" AND eventMessage CONTAINS "Sandbox"`. The narrower
  `subsystem == "com.apple.sandbox.reporting"` and `category == "violation"`
  also match. All three return identical entries.
- **Message format** is fixed:
  `kernel: (Sandbox) [com.apple.sandbox.reporting:violation] Sandbox:
  <comm>(<pid>) deny(<count>) <operation> <details>`. For
  `network-outbound` denies the `<details>` field is `remote:*:<port>`
  — **the destination host/IP is not captured by Seatbelt**. The proxy's
  in-band JSON denial entries are the only source of `host` information.
- **`log show --start` expects local time, not UTC.** Passing a `date -u`
  timestamp silently returns zero rows even when the events exist (the
  predicate matches but the time window misses them). The wrapper must
  call `date '+%Y-%m-%d %H:%M:%S'` (no `-u`) when constructing `--since`
  arguments.
- **`log stream` requires `--type log` to surface kernel sandbox entries.**
  Default stream output omits them entirely; with `--type log` they
  appear with normal sub-second latency. `--info` (and optionally
  `--debug`) is also required — without it the kernel-side Error rows
  are filtered out.
- **Adjacent identical denials are deduped by the kernel.** Repeat
  bypass attempts to the same `remote:*:<port>` from the same `comm`
  collapse into a single `N duplicate reports for ...` row. This is a
  **constraint on the live watcher**: it must not assume one alert per
  attempt; the proxy's JSON denial entries are the per-attempt source.

## Decision

Issue 09's two-source design (per ADR-0003) stands, with the asymmetry
made explicit:

| Source             | Per-attempt | Has host | Has port | Has comm/pid | Latency       |
| ------------------ | ----------- | -------- | -------- | ------------ | ------------- |
| Proxy JSON denials | yes         | yes      | yes      | no           | sub-ms        |
| Seatbelt unified   | deduped     | **no**   | yes      | yes          | ~100 ms       |

The wrapper's `--log` subcommand merges both, tagging
`src="proxy"` vs `src="seatbelt"`. A Seatbelt denial without a paired
proxy denial is a **bypass attempt** (agent ignored `HTTPS_PROXY`/
`ALL_PROXY`); a proxy denial without a paired Seatbelt entry is the
normal allowlist refusal.

## Working commands (reference)

Historical search since a given local time:

```sh
log show \
  --start "$(date '+%Y-%m-%d %H:%M:%S' --date='1 hour ago' 2>/dev/null \
             || date -v-1H '+%Y-%m-%d %H:%M:%S')" \
  --predicate 'subsystem == "com.apple.sandbox.reporting"' \
  --info
```

Real-time stream filtered to network-outbound denials:

```sh
log stream \
  --type log \
  --predicate 'process == "kernel" AND eventMessage CONTAINS "deny(1) network-outbound"' \
  --info --debug
```

## Predicates that do NOT work (negative results)

Each of these returns zero rows even when the events demonstrably exist
(verified by the working predicate above on the same time window):

| Predicate                                                | Result               |
| -------------------------------------------------------- | -------------------- |
| `subsystem == "com.apple.sandbox"` (singular, no `.reporting`) | empty           |
| `senderImagePath CONTAINS "Sandbox.kext"`               | empty                |
| `senderImagePath CONTAINS "Sandbox"`                    | empty                |
| `eventMessage CONTAINS "deny network"` (lowercase, no parens) | empty           |
| `process == "curl"` (target process, not kernel)        | empty (kernel logs the event, not curl) |

## What this leaves to the implementation

- The wrapper must construct `--start` arguments in **local time**
  (BSD `date -v-1H ...` on darwin; GNU `date --date=...` is unavailable
  in nix-darwin's default coreutils path — confirm during slice 5).
- The live watcher must consume `log stream` output line-by-line; sub-second
  latency is achievable. Dedup means the watcher will sometimes miss
  per-attempt detail — the proxy stream covers the gap.
- Field extraction: the message body's `<comm>(<pid>)` and `<operation>`
  parse via plain `sed`/`awk`. The destination port is the suffix of
  `remote:*:<port>`. No JSON parsing is needed for the unified-log half.
- The `(with telemetry)` SBPL qualifier is unnecessary for the deny we
  care about: `(deny network-outbound)` already produces unified-log
  entries when the kernel actually refuses a connect syscall. The
  qualifier is for Apple's internal `(allow ... (with telemetry))`
  diagnostic builds.
