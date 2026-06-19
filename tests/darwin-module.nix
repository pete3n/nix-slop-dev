# Eval-level tests for the sandboxed nix-darwin module (issue 13).
#
# The nix-darwin module is a thin parallel of the NixOS module: it
# installs the sandboxed-darwin package system-wide with the configured
# stateDir. Seatbelt needs no root, so the darwin module deliberately
# OMITS the users/sudoers/auditd machinery the NixOS module carries.
#
# Eval strategy: `lib.evalModules` with a local stub schema for the
# nix-darwin options this module touches (`environment.systemPackages`,
# `security.sudo.extraRules`, `security.audit.enable`,
# `security.auditd.enable`). This keeps the test free of a nix-darwin
# flake input — the module's surface is small enough that a real
# nix-darwin eval is overkill, and HITL coverage is the source of truth
# for live nix-darwin integration anyway.
{ pkgs, lib }:
let
  # Marker package — the tracer just needs to confirm the configured
  # package surfaces in `environment.systemPackages`. Using a marker
  # avoids dragging the real sandboxed-darwin closure into eval.
  markerPkg = pkgs.runCommand "marker-sandboxed-darwin" { } ''
    mkdir -p $out/bin
    touch $out/bin/sandboxed
  '';

  # The module follows the same `import <module> flake` pattern as
  # nixosModules. Tests that override `package` directly pass an empty
  # fake flake; tests that exercise the `package` default pass a fake
  # flake whose `.override` records what it was called with.
  importModule = flakeArg:
    import ../modules/sandboxed-darwin/default.nix flakeArg;

  # Capture flake: the default-built `package` calls
  # `flake.packages.${system}.sandboxed.override { stateDir = cfg.stateDir; }`.
  # We return a real derivation (so `lib.types.package` accepts it) whose
  # `passthru.capturedStateDir` records the argument the module passed.
  captureFlake = {
    packages.${pkgs.stdenv.hostPlatform.system}.sandboxed = {
      override = args: pkgs.runCommand "sandboxed-capture" {
        passthru.capturedStateDir = args.stateDir;
      } "touch $out";
    };
  };

  # Minimal stub of the nix-darwin schema this module touches. The
  # default values let B3 (anti-test) probe whether the module has
  # silently re-introduced Linux-only machinery — a non-default
  # assignment from our module would flow through here.
  stubSchema = { lib, ... }: {
    options.environment.systemPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
    };
    options.security.sudo.extraRules = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [ ];
    };
    options.security.audit.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
    options.security.auditd.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
    };
  };

  evalWith = { flake ? { }, cfg ? { } }: (lib.evalModules {
    modules = [
      (importModule flake)
      stubSchema
      ({ ... }: {
        _module.args.pkgs = pkgs;
      })
      { security.sandboxed = cfg; }
    ];
  }).config;

  enabledConfig = evalWith {
    cfg = {
      enable = true;
      package = markerPkg;
    };
  };

  stateDirConfig = evalWith {
    flake = captureFlake;
    cfg = {
      enable = true;
      stateDir = "custom/state/dir";
    };
  };

  tests = {
    # Tracer (B1): when `enable = true`, the configured package surfaces
    # in `environment.systemPackages`. This is the module's whole job on
    # nix-darwin — no daemon, no sudoers, just system-wide install.
    testEnableInstallsPackage = {
      expr = builtins.elem markerPkg enabledConfig.environment.systemPackages;
      expected = true;
    };

    # B2: `stateDir` flows through the `package` default by calling
    # `.override { stateDir = cfg.stateDir; }` on the flake-supplied
    # base package. Anti-test against a regression where the darwin
    # module silently drops the override and installs a default-state
    # wrapper.
    testStateDirFlowsIntoDefaultPackageOverride = {
      expr = stateDirConfig.security.sandboxed.package.capturedStateDir;
      expected = "custom/state/dir";
    };

    # B3 (anti-test): the darwin module must NOT touch sudoers, audit,
    # or auditd. Seatbelt is daemonless and unprivileged — copy-pasting
    # the Linux module's sudo/audit machinery into the darwin path
    # would be dead config at best and a security-surface footgun at
    # worst (granting passwordless sudo to commands that have no
    # macOS equivalent). The stub schema's defaults must survive the
    # enabled config.
    testNoSudoRules = {
      expr = enabledConfig.security.sudo.extraRules;
      expected = [ ];
    };
    testNoAudit = {
      expr = enabledConfig.security.audit.enable;
      expected = false;
    };
    testNoAuditd = {
      expr = enabledConfig.security.auditd.enable;
      expected = false;
    };

    # B3 (anti-test): the darwin module must NOT declare the `users`
    # option. Asserting the absence of the option (not just an empty
    # default) catches a regression where someone copies the NixOS
    # module verbatim — even an empty `users = [ ]` invites future
    # callers to set it and expect sudoers to follow.
    testNoUsersOption = {
      expr = enabledConfig.security.sandboxed ? users;
      expected = false;
    };
  };

  failures = lib.runTests tests;
in
if failures == [ ]
then pkgs.runCommand "sandboxed-darwin-module-tests" { } ''
  echo "sandboxed-darwin module tests passed" > $out
''
else
  throw "sandboxed-darwin module tests failed:\n${builtins.toJSON failures}"
