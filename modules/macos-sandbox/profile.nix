# Seatbelt profile generators for the macOS Sandbox boundary (per ADR-0003).
#
# Two entry points share one private helper:
#
#   mkSandboxProfile { proxyPort, jailFragment ? "" } → string
#     Validated integer port. Used directly by tests and by any pure
#     build-time consumer that knows its port up front.
#
#   mkSandboxProfileTemplate { portPlaceholder ? "__PROXYPORT__", jailFragment ? "" } → string
#     Emits the same shape with a string sentinel in the port slot. The
#     bash wrapper (sandboxed-darwin) sed-substitutes the sentinel with the
#     kernel-picked proxy port at runtime (issue 08).
#
# Order matters: SBPL evaluates later rules last (last-match wins), so
# `(allow default)` must precede `(deny network-outbound)` — otherwise the
# blanket allow shadows the explicit deny and outbound traffic escapes
# the proxy pin.
#
# jailFragment is optional and spliced verbatim after the network rules.
# It carries the Jail's filesystem profile fragment so a single sandbox-exec
# enforces both boundaries (issue 11). Empty by default — the Sandbox
# boundary stands on its own.
{ lib }:
let
  # Renders one `(allow network-outbound (remote ip "<ip>:*"))` per entry,
  # newline-terminated. Empty list → empty string (no trailing newline) so
  # the surrounding template stays byte-equal to its pre-issue-16 shape
  # when no IP literals are in play (the common case before this issue).
  # Issue 16: lets IP-literal whitelist entries get an L3 carve-out from
  # the (deny network-outbound) rule, matching Linux's IPAddressAllow
  # passthrough semantics (ICMP / raw sockets / arbitrary TCP+UDP to the
  # allowed IP). Hostnames stay on the userspace proxy — they were never
  # candidates for direct L3 access since the proxy provides the dynamic-
  # DNS + cert-inspection guarantees the threat model relies on.
  renderIpAllowsBlock = ipAllowList:
    lib.concatMapStrings
      (ip: ''(allow network-outbound (remote ip "${ip}:*"))'' + "\n")
      ipAllowList;

  buildProfile = { portToken, jailFragment, ipAllowsBlock }:
    ''
      (version 1)
      (allow default)
      (deny network-outbound)
      (allow network-outbound (remote ip "localhost:${portToken}"))
    '' + ipAllowsBlock + jailFragment;
in
{
  mkSandboxProfile =
    { proxyPort, jailFragment ? "", ipAllowList ? [ ] }:
    let
      validPort = lib.isInt proxyPort && proxyPort >= 1 && proxyPort <= 65535;
      validIpList = lib.isList ipAllowList
        && lib.all (ip: lib.isString ip && ip != "") ipAllowList;
    in
    assert lib.assertMsg validPort
      "mkSandboxProfile: proxyPort must be an integer in 1..65535, got ${builtins.toJSON proxyPort}";
    assert lib.assertMsg validIpList
      "mkSandboxProfile: ipAllowList must be a list of non-empty strings, got ${builtins.toJSON ipAllowList}";
    buildProfile {
      portToken = toString proxyPort;
      inherit jailFragment;
      ipAllowsBlock = renderIpAllowsBlock ipAllowList;
    };

  # mkSandboxProfileTemplate emits an `__IPALLOWLIST__` placeholder line in
  # the slot where mkSandboxProfile would render its IP allow lines. The
  # wrapper sed-substitutes the placeholder line at runtime: when the
  # whitelist contains IP literals, the line is replaced with the assembled
  # allow block; otherwise the line is deleted (net result byte-identical
  # to the pre-issue-16 shape). See `packages/sandboxed-darwin/render.nix`'s
  # `mkProfileSedPipeline` for the sed wiring (`r ${ip_block_file}` + `d`).
  mkSandboxProfileTemplate =
    { portPlaceholder ? "__PROXYPORT__"
    , jailFragment ? ""
    , ipAllowListPlaceholder ? "__IPALLOWLIST__"
    }:
    let
      validPlaceholder = lib.isString portPlaceholder && portPlaceholder != "";
      validIpPlaceholder = lib.isString ipAllowListPlaceholder
        && ipAllowListPlaceholder != "";
    in
    assert lib.assertMsg validPlaceholder
      "mkSandboxProfileTemplate: portPlaceholder must be a non-empty string, got ${builtins.toJSON portPlaceholder}";
    assert lib.assertMsg validIpPlaceholder
      "mkSandboxProfileTemplate: ipAllowListPlaceholder must be a non-empty string, got ${builtins.toJSON ipAllowListPlaceholder}";
    buildProfile {
      portToken = portPlaceholder;
      inherit jailFragment;
      ipAllowsBlock = ipAllowListPlaceholder + "\n";
    };
}
