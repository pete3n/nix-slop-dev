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
  buildProfile =
    { portToken, jailFragment }:
    ''
      (version 1)
      (allow default)
      (deny network-outbound)
      (allow network-outbound (remote ip "localhost:${portToken}"))
    ''
    + jailFragment;
in
{
  mkSandboxProfile =
    {
      proxyPort,
      jailFragment ? "",
    }:
    let
      validPort = lib.isInt proxyPort && proxyPort >= 1 && proxyPort <= 65535;
    in
    assert lib.assertMsg validPort
      "mkSandboxProfile: proxyPort must be an integer in 1..65535, got ${builtins.toJSON proxyPort}";
    buildProfile {
      portToken = toString proxyPort;
      inherit jailFragment;
    };

  mkSandboxProfileTemplate =
    {
      portPlaceholder ? "__PROXYPORT__",
      jailFragment ? "",
    }:
    let
      validPlaceholder = lib.isString portPlaceholder && portPlaceholder != "";
    in
    assert lib.assertMsg validPlaceholder
      "mkSandboxProfileTemplate: portPlaceholder must be a non-empty string, got ${builtins.toJSON portPlaceholder}";
    buildProfile {
      portToken = portPlaceholder;
      inherit jailFragment;
    };
}
