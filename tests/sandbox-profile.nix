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
      expr = lib.hasInfix ''(allow network-outbound (remote ip "localhost:__PROXYPORT__"))'' (
        mkSandboxProfileTemplate { }
      );
      expected = true;
    };

    testTemplateCustomPlaceholder = {
      expr = {
        substituted =
          lib.hasInfix ''(allow network-outbound (remote ip "localhost:@@PORT@@"))''
            (mkSandboxProfileTemplate {
              portPlaceholder = "@@PORT@@";
            });
        defaultAbsent =
          !(lib.hasInfix "__PROXYPORT__" (mkSandboxProfileTemplate {
            portPlaceholder = "@@PORT@@";
          }));
      };
      expected = {
        substituted = true;
        defaultAbsent = true;
      };
    };

    testTemplateRejectsEmptyPlaceholder = {
      expr =
        (builtins.tryEval (mkSandboxProfileTemplate {
          portPlaceholder = "";
        })).success;
      expected = false;
    };

    testTemplateRejectsNonStringPlaceholder = {
      expr =
        (builtins.tryEval (mkSandboxProfileTemplate {
          portPlaceholder = 8080;
        })).success;
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
      expected = ''
        (version 1)
        (allow default)
        (deny network-outbound)
        (allow network-outbound (remote ip "localhost:__PROXYPORT__"))
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
      '';
    };

    testVersionHeader = {
      expr = lib.hasPrefix "(version 1)" (mkSandboxProfile {
        proxyPort = 8080;
      });
      expected = true;
    };

    testDenyNetworkOutbound = {
      expr = lib.hasInfix "(deny network-outbound)" (mkSandboxProfile {
        proxyPort = 8080;
      });
      expected = true;
    };

    # SBPL is order-sensitive: later rules win. (allow default) must precede
    # (deny network-outbound), or the explicit deny is shadowed by the
    # blanket allow and the proxy pin becomes ineffective.
    testAllowDefaultBeforeNetworkDeny =
      let
        profile = mkSandboxProfile { proxyPort = 8080; };
        allowIdx = lib.strings.stringLength (builtins.head (lib.splitString "(allow default)" profile));
        denyIdx = lib.strings.stringLength (
          builtins.head (lib.splitString "(deny network-outbound)" profile)
        );
      in
      {
        expr = allowIdx < denyIdx;
        expected = true;
      };

    testProxyPortSubstitution = {
      expr = {
        low = lib.hasInfix ''(allow network-outbound (remote ip "localhost:8080"))'' (mkSandboxProfile {
          proxyPort = 8080;
        });
        high = lib.hasInfix ''(allow network-outbound (remote ip "localhost:49152"))'' (mkSandboxProfile {
          proxyPort = 49152;
        });
        notHardcoded =
          !(lib.hasInfix "8080" (mkSandboxProfile {
            proxyPort = 49152;
          }));
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
      expr =
        (builtins.tryEval (mkSandboxProfile {
          proxyPort = 0;
        })).success;
      expected = false;
    };

    testRejectsOverflowPort = {
      expr =
        (builtins.tryEval (mkSandboxProfile {
          proxyPort = 65536;
        })).success;
      expected = false;
    };

    testRejectsNegativePort = {
      expr =
        (builtins.tryEval (mkSandboxProfile {
          proxyPort = -1;
        })).success;
      expected = false;
    };

    testRejectsNonIntPort = {
      expr =
        (builtins.tryEval (mkSandboxProfile {
          proxyPort = "8080";
        })).success;
      expected = false;
    };

    testAcceptsBoundaryPorts = {
      expr = {
        lo =
          (builtins.tryEval (mkSandboxProfile {
            proxyPort = 1;
          })).success;
        hi =
          (builtins.tryEval (mkSandboxProfile {
            proxyPort = 65535;
          })).success;
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
