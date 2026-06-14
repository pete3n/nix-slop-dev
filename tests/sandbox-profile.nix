# Behavior tests for the macOS Sandbox Seatbelt profile generator
# (per ADR-0003 — ONBOARDING.md's "What to do next" step 1).
#
# The profile generator is a pure Nix function. Iterating during TDD:
#   nix-build tests/sandbox-profile.nix \
#     --arg pkgs '(import <nixpkgs> {})' --arg lib '(import <nixpkgs> {}).lib'
# In CI it is consumed via flake checks.{aarch64,x86_64}-darwin.
#
# Live `sandbox-exec -f` profile load is HITL per the spike's methodology
# and is not covered here.
{ pkgs, lib }:
let
  profile = import ../modules/macos-sandbox/profile.nix { inherit lib; };
  inherit (profile) mkSandboxProfile mkSandboxProfileTemplate;

  tests = {
    # mkSandboxProfileTemplate emits the same shape with a runtime sentinel
    # in place of the port. Consumed by the bash wrapper (sandboxed-darwin)
    # which sed-substitutes the sentinel with the kernel-picked proxy port
    # at runtime (issue 08).
    testTemplateDefaultPlaceholder = {
      expr = lib.hasInfix ''(allow network-outbound (remote ip "localhost:__PROXYPORT__"))''
        (mkSandboxProfileTemplate { });
      expected = true;
    };

    testTemplateCustomPlaceholder = {
      expr = {
        substituted = lib.hasInfix ''(allow network-outbound (remote ip "localhost:@@PORT@@"))''
          (mkSandboxProfileTemplate { portPlaceholder = "@@PORT@@"; });
        defaultAbsent = !(lib.hasInfix "__PROXYPORT__"
          (mkSandboxProfileTemplate { portPlaceholder = "@@PORT@@"; }));
      };
      expected = {
        substituted = true;
        defaultAbsent = true;
      };
    };

    testTemplateRejectsEmptyPlaceholder = {
      expr = (builtins.tryEval
        (mkSandboxProfileTemplate { portPlaceholder = ""; })).success;
      expected = false;
    };

    testTemplateRejectsNonStringPlaceholder = {
      expr = (builtins.tryEval
        (mkSandboxProfileTemplate { portPlaceholder = 8080; })).success;
      expected = false;
    };

    # Template + jailFragment composes identically to mkSandboxProfile +
    # jailFragment, just with the sentinel in the port slot. Sets up the
    # bash wrapper's eventual Jail+Sandbox combined-profile path (issue 11).
    testTemplateWithJailFragmentExactShape = {
      expr = mkSandboxProfileTemplate {
        jailFragment = ''
          (deny file-write*)
        '';
      };
      # Issue 16: template emits an `__IPALLOWLIST__` placeholder line
      # between the loopback allow and the jailFragment. The wrapper's sed
      # pipeline swaps the line at runtime for the assembled IP allow
      # block (or removes the line via `d` when no IP literals are in the
      # whitelist — net result byte-identical to the pre-issue-16 shape).
      expected = ''
        (version 1)
        (allow default)
        (deny network-outbound)
        (allow network-outbound (remote ip "localhost:__PROXYPORT__"))
        __IPALLOWLIST__
        (deny file-write*)
      '';
    };

    testTemplateEmptyFragmentExactShape = {
      expr = mkSandboxProfileTemplate { };
      expected = ''
        (version 1)
        (allow default)
        (deny network-outbound)
        (allow network-outbound (remote ip "localhost:__PROXYPORT__"))
        __IPALLOWLIST__
      '';
    };

    # Issue 16: custom placeholder for ipAllowListPlaceholder. Mirrors the
    # portPlaceholder customisation contract — lets future templates use a
    # different sentinel without code changes.
    testTemplateCustomIpAllowListPlaceholder = {
      expr = let
        rendered = mkSandboxProfileTemplate {
          ipAllowListPlaceholder = "@@IPS@@";
        };
      in {
        substituted = lib.hasInfix "@@IPS@@" rendered;
        defaultAbsent = !(lib.hasInfix "__IPALLOWLIST__" rendered);
      };
      expected = {
        substituted = true;
        defaultAbsent = true;
      };
    };

    testTemplateRejectsEmptyIpAllowListPlaceholder = {
      expr = (builtins.tryEval
        (mkSandboxProfileTemplate { ipAllowListPlaceholder = ""; })).success;
      expected = false;
    };

    testVersionHeader = {
      expr = lib.hasPrefix "(version 1)" (mkSandboxProfile { proxyPort = 8080; });
      expected = true;
    };

    testDenyNetworkOutbound = {
      expr = lib.hasInfix "(deny network-outbound)"
        (mkSandboxProfile { proxyPort = 8080; });
      expected = true;
    };

    # SBPL is order-sensitive: later rules win. (allow default) must precede
    # (deny network-outbound), or the explicit deny is shadowed by the
    # blanket allow and the proxy pin becomes ineffective.
    testAllowDefaultBeforeNetworkDeny =
      let
        profile = mkSandboxProfile { proxyPort = 8080; };
        allowIdx = lib.strings.stringLength
          (builtins.head (lib.splitString "(allow default)" profile));
        denyIdx = lib.strings.stringLength
          (builtins.head (lib.splitString "(deny network-outbound)" profile));
      in
      {
        expr = allowIdx < denyIdx;
        expected = true;
      };

    testProxyPortSubstitution = {
      expr = {
        low = lib.hasInfix ''(allow network-outbound (remote ip "localhost:8080"))''
          (mkSandboxProfile { proxyPort = 8080; });
        high = lib.hasInfix ''(allow network-outbound (remote ip "localhost:49152"))''
          (mkSandboxProfile { proxyPort = 49152; });
        notHardcoded = !(lib.hasInfix "8080"
          (mkSandboxProfile { proxyPort = 49152; }));
      };
      expected = {
        low = true;
        high = true;
        notHardcoded = true;
      };
    };

    # Default jailFragment ("" / omitted) yields the network-only shape
    # exactly — no trailing fragment cruft. Exact-match catches stray
    # newlines or accidental Nix-string indentation artifacts.
    testEmptyFragmentExactShape = {
      expr = mkSandboxProfile { proxyPort = 8080; };
      expected = ''
        (version 1)
        (allow default)
        (deny network-outbound)
        (allow network-outbound (remote ip "localhost:8080"))
      '';
    };

    # Issue 16 tracer: `mkSandboxProfile` accepts an optional `ipAllowList`
    # arg. When empty (default), the rendered profile is byte-for-byte
    # identical to the pre-issue-16 shape — no stray blank line, no
    # placeholder. This pins the backwards-compat contract so existing
    # callers that don't set ipAllowList stay unaffected. Empty list is
    # the common case for hostname-only whitelists.
    testEmptyIpAllowListIsBaselineByteForByte = {
      expr = mkSandboxProfile { proxyPort = 8080; ipAllowList = [ ]; };
      expected = ''
        (version 1)
        (allow default)
        (deny network-outbound)
        (allow network-outbound (remote ip "localhost:8080"))
      '';
    };

    # Issue 16: one IP-literal whitelist entry emits one
    # `(allow network-outbound (remote ip "<ip>:*"))` line, slotted between
    # the loopback-to-proxy allow and the jail fragment. `:*` is the SBPL
    # port wildcard — matches any L4 port AND non-TCP/UDP traffic (ICMP,
    # raw sockets), giving NixOS IPAddressAllow-style L3 passthrough. The
    # line lands AFTER the deny (so last-match-wins permits) and AFTER the
    # loopback allow (so the rendered diff stays stable across single vs
    # multi-IP cases).
    testSingleIpAllowListRendersAllowLine = {
      expr = mkSandboxProfile {
        proxyPort = 8080;
        ipAllowList = [ "192.168.1.1" ];
      };
      expected = ''
        (version 1)
        (allow default)
        (deny network-outbound)
        (allow network-outbound (remote ip "localhost:8080"))
        (allow network-outbound (remote ip "192.168.1.1:*"))
      '';
    };

    # Issue 16: IP allows precede jailFragment. Pins the splice point so a
    # future refactor of the buildProfile composition can't accidentally
    # let the jail's `(deny default)` or any future jail-fragment-emitted
    # `(deny network*)` shadow the IP allows (jail fragments are pure
    # filesystem today but the contract is structural — IP allows live
    # in the network rule block).
    testIpAllowListPrecedesJailFragment = {
      expr = mkSandboxProfile {
        proxyPort = 8080;
        ipAllowList = [ "192.168.1.1" ];
        jailFragment = ''
          (deny file-write*)
        '';
      };
      expected = ''
        (version 1)
        (allow default)
        (deny network-outbound)
        (allow network-outbound (remote ip "localhost:8080"))
        (allow network-outbound (remote ip "192.168.1.1:*"))
        (deny file-write*)
      '';
    };

    # Issue 16: multiple IPs render in list order. List-order is the diff-
    # stability contract — the wrapper builds the runtime IP block from
    # wl_runtime, which preserves insert order (--wl-add appends; -a is
    # appended after the file). Order-sensitive tests catch a bug where
    # impl uses `lib.attrNames` (sorts) or similar non-stable iteration.
    testMultipleIpAllowListPreservesOrder = {
      expr = mkSandboxProfile {
        proxyPort = 8080;
        ipAllowList = [ "192.168.1.1" "10.0.0.5" "172.16.0.1" ];
      };
      expected = ''
        (version 1)
        (allow default)
        (deny network-outbound)
        (allow network-outbound (remote ip "localhost:8080"))
        (allow network-outbound (remote ip "192.168.1.1:*"))
        (allow network-outbound (remote ip "10.0.0.5:*"))
        (allow network-outbound (remote ip "172.16.0.1:*"))
      '';
    };

    # Issue 16: an empty string in ipAllowList would render as
    # `(remote ip ":*")` — Seatbelt would either reject the profile at
    # load time (opaque rc=65) or treat the empty host as a wildcard.
    # Either way it's a footgun; fail fast at eval time with a clear
    # message. Same for non-string entries (e.g. integers from a typo).
    testRejectsEmptyStringInIpAllowList = {
      expr = (builtins.tryEval (mkSandboxProfile {
        proxyPort = 8080;
        ipAllowList = [ "192.168.1.1" "" ];
      })).success;
      expected = false;
    };

    testRejectsNonStringInIpAllowList = {
      expr = (builtins.tryEval (mkSandboxProfile {
        proxyPort = 8080;
        ipAllowList = [ "192.168.1.1" 42 ];
      })).success;
      expected = false;
    };

    testRejectsNonListIpAllowList = {
      expr = (builtins.tryEval (mkSandboxProfile {
        proxyPort = 8080;
        ipAllowList = "192.168.1.1";
      })).success;
      expected = false;
    };

    # jailFragment is the Jail's filesystem profile fragment (issue 11):
    # spliced verbatim after the network rules so a single sandbox-exec
    # enforces both boundaries. Byte-for-byte to keep the contract simple.
    testJailFragmentSplicedExactShape = {
      expr = mkSandboxProfile {
        proxyPort = 8080;
        jailFragment = ''
          (deny file-write*)
          (allow file-write* (subpath "/tmp"))
        '';
      };
      expected = ''
        (version 1)
        (allow default)
        (deny network-outbound)
        (allow network-outbound (remote ip "localhost:8080"))
        (deny file-write*)
        (allow file-write* (subpath "/tmp"))
      '';
    };

    # Misconfigured proxyPort would silently produce a profile that
    # loads but allows nothing. Fail-closed at eval time so misconfigs
    # surface at `nix build`, not at runtime under sandbox-exec.
    testRejectsZeroPort = {
      expr = (builtins.tryEval (mkSandboxProfile { proxyPort = 0; })).success;
      expected = false;
    };

    testRejectsOverflowPort = {
      expr = (builtins.tryEval (mkSandboxProfile { proxyPort = 65536; })).success;
      expected = false;
    };

    testRejectsNegativePort = {
      expr = (builtins.tryEval (mkSandboxProfile { proxyPort = -1; })).success;
      expected = false;
    };

    testRejectsNonIntPort = {
      expr = (builtins.tryEval (mkSandboxProfile { proxyPort = "8080"; })).success;
      expected = false;
    };

    testAcceptsBoundaryPorts = {
      expr = {
        lo = (builtins.tryEval (mkSandboxProfile { proxyPort = 1; })).success;
        hi = (builtins.tryEval (mkSandboxProfile { proxyPort = 65535; })).success;
      };
      expected = {
        lo = true;
        hi = true;
      };
    };
  };

  failures = lib.runTests tests;
in
if failures == [ ] then
  pkgs.runCommand "sandbox-profile-tests" { } ''
    echo "all sandbox-profile tests passed"
    touch $out
  ''
else
  throw "sandbox-profile tests failed:\n${builtins.toJSON failures}"
