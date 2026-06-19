# Behavior tests for the macOS sandboxed-darwin wrapper composition layer
# (issue 11). The wrapper itself is a writeShellScriptBin derivation, but the
# pure helpers that decide *what* it emits — most importantly the combined
# Sandbox+Jail SBPL profile template — live in
# `packages/sandboxed-darwin/render.nix` and are pure Nix.
#
# This file iterates during TDD:
#   nix-build tests/sandboxed-darwin.nix \
#     --arg pkgs '(import <nixpkgs> {})' --arg lib '(import <nixpkgs> {}).lib'
# In CI it is consumed via flake checks.{aarch64,x86_64}-darwin.sandboxed-darwin.
#
# Live `sandbox-exec -f` profile load + actual jail enforcement remain HITL
# per spike methodology; tests here cover the pure profile-rendering layer.
{ pkgs, lib }:
let
  render = import ../packages/sandboxed-darwin/render.nix { inherit lib; };
  profile = import ../modules/macos-sandbox/profile.nix { inherit lib; };

  tests = {
    # Slice 1 tracer: no jail given → the combined template is byte-for-byte
    # identical to the existing network-only template (mkSandboxProfileTemplate
    # with default empty jailFragment). This preserves backwards compatibility
    # — the network-only `sandboxed` build keeps the exact profile shape
    # `tests/sandbox-profile.nix` already pins.
    testNoJailEqualsNetworkOnlyTemplate = {
      expr = render.combinedSbplTemplate { };
      expected = profile.mkSandboxProfileTemplate { };
    };

    # Slice 1 tracer: when a jail (derivation with .jailData) is supplied,
    # the combined template carries both boundaries — network rules from the
    # Sandbox profile (per ADR-0003) AND the jail's filesystem fragment
    # (deny default + prelude + combinator allows, per ADR-0004) — spliced
    # via mkSandboxProfileTemplate's already-tested jailFragment parameter.
    # Anti-test against a regression that silently drops one boundary.
    testWithJailContainsBothBoundaries = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = ''
              (deny default)
              (allow file-read* (literal "/x"))
            '';
            preflight = [ ];
            cleanup = [ ];
            env = { };
            envForward = [ ];
            binPaths = [ ];
            mainBin = "/nix/store/fake/bin/jail-test";
          };
        };
        result = render.combinedSbplTemplate { jail = fakeJail; };
      in {
        hasNetworkDeny = lib.hasInfix "(deny network-outbound)" result;
        hasProxyAllow = lib.hasInfix
          ''(allow network-outbound (remote ip "localhost:__PROXYPORT__"))''
          result;
        hasJailDenyDefault = lib.hasInfix "(deny default)" result;
        hasJailLiteralAllow = lib.hasInfix
          ''(allow file-read* (literal "/x"))''
          result;
      };
      expected = {
        hasNetworkDeny = true;
        hasProxyAllow = true;
        hasJailDenyDefault = true;
        hasJailLiteralAllow = true;
      };
    };

    # Slice 1: the splice order is load-bearing. The network rules MUST
    # appear before the jail fragment so the Sandbox's last-match-wins
    # `(allow network-outbound (remote ip "localhost:__PROXYPORT__"))`
    # is not preceded by anything that re-denies network-outbound. The
    # jail fragment opens with `(deny default)` which would otherwise
    # shadow the network allow if placed earlier. (Verified safe in
    # tests/sandbox-profile.nix's testJailFragmentSplicedExactShape; this
    # test pins the same ordering at the render-helper layer.)
    # Slice 2+3: when the wrapper is built with a jail, its runtime sed
    # pipeline must substitute __JAIL_CWD__ (with the live cwd via `realpath
    # -s "$PWD"`) and __JAIL_HOME__ (with the live $HOME) in addition to the
    # already-shipping __PROXYPORT__. Slices folded because the substitution
    # code is shared (per ONBOARDING.md issue-11 TDD plan).
    #
    # Sed delimiter for the jail subs is `|` not `/` because paths contain
    # `/`. cwd uses `realpath -s` so symlinks resolve to the canonical form
    # the kernel applies SBPL rules against (spike 10 F1 — /tmp -> /private/tmp).
    testJailWrapperSedSubstitutesAllPlaceholders = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [ ];
            cleanup = [ ];
            env = { };
            envForward = [ ];
            binPaths = [ ];
            mainBin = "/nix/store/fake/bin/jail-sed-test";
          };
        };
        pipeline = render.mkProfileSedPipeline { jail = fakeJail; };
      in {
        hasProxyPortSub = lib.hasInfix
          ''-e "s/__PROXYPORT__/''${_proxy_port}/g"'' pipeline;
        hasJailCwdSub = lib.hasInfix
          ''-e "s|__JAIL_CWD__|''${_jail_cwd}|g"'' pipeline;
        hasJailHomeSub = lib.hasInfix
          ''-e "s|__JAIL_HOME__|''${HOME}|g"'' pipeline;
      };
      expected = {
        hasProxyPortSub = true;
        hasJailCwdSub = true;
        hasJailHomeSub = true;
      };
    };

    # Slice 2+3: when the wrapper is built without a jail (network-only),
    # the sed pipeline must NOT include the jail substitutions — they would
    # be no-ops (the tokens are never in the template), but emitting them
    # would dilute the contract and confuse anyone reading the wrapper to
    # understand network-only mode. Pin the minimal pipeline.
    testNoJailWrapperSedPipelineIsPortOnly = {
      expr = let
        pipeline = render.mkProfileSedPipeline { };
      in {
        hasProxyPortSub = lib.hasInfix
          ''-e "s/__PROXYPORT__/''${_proxy_port}/g"'' pipeline;
        hasNoJailCwdSub = !(lib.hasInfix "__JAIL_CWD__" pipeline);
        hasNoJailHomeSub = !(lib.hasInfix "__JAIL_HOME__" pipeline);
      };
      expected = {
        hasProxyPortSub = true;
        hasNoJailCwdSub = true;
        hasNoJailHomeSub = true;
      };
    };

    # Slice-21 follow-up (Linux-parity zero-touch apps): the apps' jail
    # is built with `projectName = "__SLOP_ENV_PROJECT_NAME__"` (the
    # placeholder default in lib/slop-env/darwin.nix). That placeholder
    # ends up baked into every SBPL allow under cfgDir via
    # shared.mkJailCombinators (`/projects/__SLOP_ENV_PROJECT_NAME__/…`).
    # The wrapper sed-substitutes it at runtime with the basename of
    # $PWD (or $NIX_SLOP_DEV_PROJECT_NAME if set) — mirrors Linux's
    # placeholderPreamble in lib/slop-env/linux.nix.
    #
    # Pattern MUST be anchored on `/projects/` so write-text source
    # store names (which embed the placeholder as
    # `-projects-__SLOP_ENV_PROJECT_NAME__-`) are not mangled —
    # see [[project-jail-nix-placeholder-substitution]] for the
    # canonical regression from Linux commit 4c3b2a6.
    testJailWrapperSedSubstitutesProjectNamePlaceholder = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [ ];
            cleanup = [ ];
            env = { };
            envForward = [ ];
            binPaths = [ ];
            hostResolve = [ ];
            mainBin = "/nix/store/fake/bin/project-name-sed";
          };
        };
        pipeline = render.mkProfileSedPipeline { jail = fakeJail; };
      in {
        # The substitution is present and anchored on `/projects/` so it
        # only touches destination paths in the SBPL — write-text source
        # store names (dash-separated) are not in the match window.
        hasAnchoredProjectNameSub = lib.hasInfix
          ''-e "s|/projects/__SLOP_ENV_PROJECT_NAME__|/projects/''${_project_name}|g"''
          pipeline;
        # Existing subs survive — project-name is additive, not a
        # replacement for the static jail subs.
        hasProxyPortSub = lib.hasInfix
          ''-e "s/__PROXYPORT__/''${_proxy_port}/g"'' pipeline;
        hasJailCwdSub = lib.hasInfix
          ''-e "s|__JAIL_CWD__|''${_jail_cwd}|g"'' pipeline;
      };
      expected = {
        hasAnchoredProjectNameSub = true;
        hasProxyPortSub = true;
        hasJailCwdSub = true;
      };
    };

    # Slice-21 follow-up: in no-jail (network-only) mode the SBPL
    # template carries no projectName placeholder — there are no
    # combinator-emitted allows. The pipeline must not emit a dead
    # project-name sub. Anti-test against a regression that always
    # emits the sub regardless of mode.
    testNoJailWrapperSedPipelineHasNoProjectNameSub = {
      expr = let
        pipeline = render.mkProfileSedPipeline { };
      in !(lib.hasInfix "__SLOP_ENV_PROJECT_NAME__" pipeline);
      expected = true;
    };

    # Slice 4: preflight. When the wrapper is built with a jail, every
    # snippet in jailData.preflight runs before sandbox-exec. Each snippet
    # is one bash line; failures abort the wrapper because the surrounding
    # script runs under `set -eu` (asserted by the wrapper's own header).
    # Order is preserved — the combinator-merge order in the jail
    # constructor is the same order preflight executes.
    testPreflightBlockEmitsSnippetsInOrder = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [
              ''mkdir -p "/Users/x/scratch"''
              ''ln -sfn "/nix/store/abc/cfg" "/Users/x/.config/foo"''
            ];
            cleanup = [ ];
            env = { };
            envForward = [ ];
            binPaths = [ ];
            mainBin = "/nix/store/fake/bin/preflight-test";
          };
        };
        block = render.mkPreflightBlock { jail = fakeJail; };
      in block;
      expected = ''
        mkdir -p "/Users/x/scratch"
        ln -sfn "/nix/store/abc/cfg" "/Users/x/.config/foo"
      '';
    };

    # Slice 4: when jail is null, the preflight block is empty (no `# jail
    # preflight` heading, no stray newlines). Pins the network-only contract
    # — slice 4 must not regress the no-jail wrapper into emitting dead
    # bash that would slow startup or surprise readers of the script.
    testPreflightBlockEmptyWhenNoJail = {
      expr = render.mkPreflightBlock { };
      expected = "";
    };

    # Slice-21 follow-up (preflight surface): the apps' zero-touch jail
    # bakes __SLOP_ENV_PROJECT_NAME__ into preflight snippets via
    # shared.mkJailCombinators's cfgDir (mkdir/ln-sfn destinations).
    # The SBPL sed pipeline (slice 1) only substitutes inside the
    # SBPL profile — preflight runs on the host filesystem BEFORE
    # sandbox-exec, so without an eval-time rewrite the apps would
    # create `~/.local/state/claude/projects/__SLOP_ENV_PROJECT_NAME__/`
    # literally on the host.
    #
    # Fix: rewrite `/projects/__SLOP_ENV_PROJECT_NAME__` → `/projects/${_project_name}`
    # at Nix-eval time. Bash expands ${_project_name} at runtime
    # against the value the wrapper computes (slice 1's wiring). Same
    # `/projects/` anchor as the SBPL sed pipeline so write-text
    # source store names (dash-separated) survive untouched.
    testPreflightBlockSubstitutesProjectNamePlaceholder = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [
              ''mkdir -p "$HOME/.local/state/claude/projects/__SLOP_ENV_PROJECT_NAME__"''
              ''ln -sfn "/nix/store/abc-jail-write-text--.local-state-claude-projects-__SLOP_ENV_PROJECT_NAME__-CLAUDE.md" "$HOME/.local/state/claude/projects/__SLOP_ENV_PROJECT_NAME__/CLAUDE.md"''
            ];
            cleanup = [ ];
            env = { };
            envForward = [ ];
            binPaths = [ ];
            mainBin = "/nix/store/fake/bin/preflight-placeholder";
          };
        };
      in render.mkPreflightBlock { jail = fakeJail; };
      expected = ''
        mkdir -p "$HOME/.local/state/claude/projects/''${_project_name}"
        ln -sfn "/nix/store/abc-jail-write-text--.local-state-claude-projects-__SLOP_ENV_PROJECT_NAME__-CLAUDE.md" "$HOME/.local/state/claude/projects/''${_project_name}/CLAUDE.md"
      '';
    };

    # Slice-21 follow-up anti-test: snippets that don't carry the
    # placeholder must pass through byte-for-byte. Pins the rewrite to
    # the anchored `/projects/__SLOP_ENV_PROJECT_NAME__` form so a
    # future broader pattern can't silently rewrite unrelated bash
    # (combinator-emitted preflight lines that mention only host paths
    # like /etc/* or /usr/* should be untouched).
    testPreflightBlockLeavesNonPlaceholderSnippetsByteEqual = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [
              ''mkdir -p "/Users/x/scratch"''
              ''ln -sfn "/nix/store/abc/cfg" "/Users/x/.config/foo"''
            ];
            cleanup = [ ];
            env = { };
            envForward = [ ];
            binPaths = [ ];
            mainBin = "/nix/store/fake/bin/preflight-no-placeholder";
          };
        };
      in render.mkPreflightBlock { jail = fakeJail; };
      expected = ''
        mkdir -p "/Users/x/scratch"
        ln -sfn "/nix/store/abc/cfg" "/Users/x/.config/foo"
      '';
    };

    # Slice 4: empty preflight list (a jail with zero combinators that
    # contribute preflight, e.g., just `set-env`s) also emits empty text
    # rather than blank lines. Anti-test against a `concatStringsSep "\n"`
    # bug that would leave a trailing newline at end-of-block.
    testPreflightBlockEmptyWhenJailPreflightListIsEmpty = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [ ];
            cleanup = [ ];
            env = { };
            envForward = [ ];
            binPaths = [ ];
            mainBin = "/nix/store/fake/bin/preflight-empty";
          };
        };
      in render.mkPreflightBlock { jail = fakeJail; };
      expected = "";
    };

    # Slice 5: cleanup snippets run in REVERSE of their merge order (LIFO).
    # Each combinator that took a resource via preflight must release it
    # before earlier combinators tear down the surrounding state — the
    # canonical case is `[tmpfs "/x", write-text "/x/file" "..."]` where
    # rm-rf "/x" would silently swallow the rm-f "/x/file" if cleanup ran
    # forward. The lib/jail header documents this contract; slice 11's
    # job is to enforce it in the wrapper.
    testCleanupBlockReversesOrder = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [ ];
            cleanup = [ "first-merged" "second-merged" "third-merged" ];
            env = { };
            envForward = [ ];
            binPaths = [ ];
            mainBin = "/nix/store/fake/bin/cleanup-order";
          };
        };
      in render.mkCleanupBlock { jail = fakeJail; };
      expected = ''
        third-merged
        second-merged
        first-merged
      '';
    };

    # Slice 5 anti-test (the canonical regression from the lib/jail
    # contract): a tmpfs followed by a write-text inside that tmpfs.
    # Merge order is [rm-rf tmpfs, rm-f file]; cleanup-block reverse
    # order is [rm-f file, rm-rf tmpfs] — file released before its
    # parent directory disappears. The forward order would leave the
    # file's symlink dangling and the post-sandbox host filesystem in
    # the wrong state.
    testCleanupBlockTmpfsThenWriteTextReversesToFileBeforeDir = {
      expr = let
        jailLib = import ../lib/jail { inherit lib pkgs; };
        leafPkg = pkgs.runCommand "jail-cleanup-leaf" { } ''
          mkdir -p $out/bin; : > $out/bin/jail-cleanup-leaf
        '';
        builtJail = jailLib.jail "jail-cleanup-leaf" leafPkg [
          (jailLib.combinators.tmpfs "/Users/x/scratch")
          (jailLib.combinators.write-text
            "/Users/x/scratch/file" "content")
        ];
        block = render.mkCleanupBlock { jail = builtJail; };
        rmRfIdx = lib.strings.stringLength
          (builtins.head (lib.splitString
            ''rm -rf "/Users/x/scratch"'' block));
        rmFIdx = lib.strings.stringLength
          (builtins.head (lib.splitString
            ''rm -f "/Users/x/scratch/file"'' block));
      in rmFIdx < rmRfIdx;
      expected = true;
    };

    # Slice-21 follow-up (cleanup surface): mirrors the preflight
    # rewrite — cleanup snippets that rm-f / rm-rf the per-project
    # cfgDir carry the placeholder; eval-time rewrite to ${_project_name}
    # so bash teardown targets the same directory that preflight
    # created. Without this, the cleanup would rm-rf the literal
    # `__SLOP_ENV_PROJECT_NAME__` dir (which preflight no longer
    # creates after slice 2's preflight fix) and silently leak the
    # real per-project dir.
    #
    # Cleanup order is REVERSED relative to preflight (LIFO per the
    # lib/jail contract); the rewrite applies AFTER reversal, so the
    # expected output reflects reverse-merge order.
    testCleanupBlockSubstitutesProjectNamePlaceholder = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [ ];
            cleanup = [
              ''rm -rf "$HOME/.local/state/claude/projects/__SLOP_ENV_PROJECT_NAME__"''
              ''rm -f "$HOME/.local/state/claude/projects/__SLOP_ENV_PROJECT_NAME__/settings.json"''
            ];
            env = { };
            envForward = [ ];
            binPaths = [ ];
            mainBin = "/nix/store/fake/bin/cleanup-placeholder";
          };
        };
      in render.mkCleanupBlock { jail = fakeJail; };
      expected = ''
        rm -f "$HOME/.local/state/claude/projects/''${_project_name}/settings.json"
        rm -rf "$HOME/.local/state/claude/projects/''${_project_name}"
      '';
    };

    # Slice-21 follow-up: anti-test mirroring the preflight version.
    # Cleanup snippets that don't reference cfgDir (e.g., generic tmpfs
    # teardown under /tmp/...) must pass through byte-for-byte.
    testCleanupBlockLeavesNonPlaceholderSnippetsByteEqual = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [ ];
            cleanup = [
              ''rm -rf "/tmp/some-tmpfs"''
              ''rm -f "/Users/x/.cache/foo"''
            ];
            env = { };
            envForward = [ ];
            binPaths = [ ];
            mainBin = "/nix/store/fake/bin/cleanup-no-placeholder";
          };
        };
      in render.mkCleanupBlock { jail = fakeJail; };
      expected = ''
        rm -f "/Users/x/.cache/foo"
        rm -rf "/tmp/some-tmpfs"
      '';
    };

    # Slice 5: no jail → empty cleanup block. The network-only wrapper
    # already has _cleanup tearing down proxy + tmpdir; jail cleanup is
    # additive. Empty string keeps the script byte-identical in that mode.
    testCleanupBlockEmptyWhenNoJail = {
      expr = render.mkCleanupBlock { };
      expected = "";
    };

    # Empty cleanup list (jail with combinators that don't contribute
    # cleanup — set-env, ro-bind, time-zone) also emits empty text. Pins
    # the same no-trailing-newline contract mkPreflightBlock has.
    testCleanupBlockEmptyWhenJailCleanupListIsEmpty = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [ ];
            cleanup = [ ];
            env = { };
            envForward = [ ];
            binPaths = [ ];
            mainBin = "/nix/store/fake/bin/cleanup-empty";
          };
        };
      in render.mkCleanupBlock { jail = fakeJail; };
      expected = "";
    };

    # Slice 6: jail env block. `jailData.env` (set-env contributions) is
    # unconditional KEY=value pairs appended to `_env_args`; entries appear
    # in alphabetical attr-name order so the rendered script is diff-
    # reviewable across template edits. Match the bash-array push idiom the
    # wrapper already uses for the static HOME/USER/PATH/TERM/PROXY entries.
    testJailEnvBlockEmitsKeyValuePairsAlphabetical = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [ ];
            cleanup = [ ];
            env = { B = "2"; A = "1"; CLAUDE_CONFIG_DIR = "/Users/x/.config"; };
            envForward = [ ];
            binPaths = [ ];
            mainBin = "/nix/store/fake/bin/env-test";
          };
        };
      in render.mkJailEnvBlock { jail = fakeJail; };
      expected = ''
        _env_args+=("A=1")
        _env_args+=("B=2")
        _env_args+=("CLAUDE_CONFIG_DIR=/Users/x/.config")
      '';
    };

    # Slice 6: envForward (try-fwd-env contributions) becomes a runtime
    # "forward if set and non-empty" loop. Matches the wrapper's existing
    # `-e <var>` (`env_fwd` array) loop shape so jailed and host-provided
    # forwards have identical semantics — only non-empty values pass.
    testJailEnvBlockEmitsConditionalForwardLoop = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [ ];
            cleanup = [ ];
            env = { };
            envForward = [ "FOO" "BAR" ];
            binPaths = [ ];
            mainBin = "/nix/store/fake/bin/fwd-test";
          };
        };
      in render.mkJailEnvBlock { jail = fakeJail; };
      expected = ''
        for _jail_fwd_var in FOO BAR; do
        	_jail_fwd_val="''${!_jail_fwd_var:-}"
        	if [ -n "$_jail_fwd_val" ]; then
        		_env_args+=("''${_jail_fwd_var}=''${_jail_fwd_val}")
        	fi
        done
      '';
    };

    # Slice 6: both env AND envForward stacked — env first (unconditional
    # assignments come before the runtime forward loop so the loop can in
    # principle override an earlier env entry, matching the wrapper's
    # existing `-e` precedence: later `_env_args+=()` shadows earlier in
    # `env -i` arg order).
    testJailEnvBlockEnvBeforeForward = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [ ];
            cleanup = [ ];
            env = { K = "v"; };
            envForward = [ "FWD" ];
            binPaths = [ ];
            mainBin = "/nix/store/fake/bin/both";
          };
        };
        block = render.mkJailEnvBlock { jail = fakeJail; };
        envIdx = lib.strings.stringLength
          (builtins.head (lib.splitString ''_env_args+=("K=v")'' block));
        forIdx = lib.strings.stringLength
          (builtins.head (lib.splitString "for _jail_fwd_var" block));
      in envIdx < forIdx;
      expected = true;
    };

    testJailEnvBlockEmptyWhenNoJail = {
      expr = render.mkJailEnvBlock { };
      expected = "";
    };

    testJailEnvBlockEmptyWhenJailEnvAndForwardEmpty = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [ ];
            cleanup = [ ];
            env = { };
            envForward = [ ];
            binPaths = [ ];
            mainBin = "/nix/store/fake/bin/none";
          };
        };
      in render.mkJailEnvBlock { jail = fakeJail; };
      expected = "";
    };

    # Slice 6: binPaths is prepended to PATH so add-pkg-deps-provided
    # binaries shadow whatever the wrapper inherited. The helper returns
    # a colon-joined-and-terminated prefix the wrapper splices straight
    # into the PATH entry of `_env_args`. List order is preserved (first
    # add-pkg-deps pkg wins lookup; lib/jail slice 8 test
    # testAddPkgDepsMultiPkgPreservesBinPathOrder pins this in the lib).
    testJailPathPrefixJoinsBinPathsInOrder = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [ ];
            cleanup = [ ];
            env = { };
            envForward = [ ];
            binPaths = [ "/nix/store/a/bin" "/nix/store/b/bin" ];
            mainBin = "/nix/store/fake/bin/path-test";
          };
        };
      in render.mkJailPathPrefix { jail = fakeJail; };
      expected = "/nix/store/a/bin:/nix/store/b/bin:";
    };

    testJailPathPrefixEmptyWhenNoJail = {
      expr = render.mkJailPathPrefix { };
      expected = "";
    };

    testJailPathPrefixEmptyWhenBinPathsListEmpty = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [ ];
            cleanup = [ ];
            env = { };
            envForward = [ ];
            binPaths = [ ];
            mainBin = "/nix/store/fake/bin/no-bin";
          };
        };
      in render.mkJailPathPrefix { jail = fakeJail; };
      expected = "";
    };

    # Slice 7: in jail mode the wrapper execs `jailData.mainBin "$@"` —
    # the jail's underlying binary (e.g., the real Claude binary, not the
    # slice-9 placeholder shim) — passing the user's full args list. The
    # user never types the binary name; the per-jail wrapper IS the entry
    # point, so `"$@"` carries only arguments.
    testExecCommandUsesMainBinInJailMode = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [ ];
            cleanup = [ ];
            env = { };
            envForward = [ ];
            binPaths = [ ];
            mainBin = "/nix/store/fake/bin/jail-main";
          };
        };
      in render.mkExecCommand { jail = fakeJail; };
      expected = ''"/nix/store/fake/bin/jail-main" "$@"'';
    };

    # Network-only mode preserves the existing contract: the user provides
    # the command as the first positional argument, so the exec line is
    # just `"$@"`. Pins backwards compatibility — without this assertion a
    # future refactor might accidentally splice mainBin into the no-jail
    # path and break every `sandboxed <some-command>` invocation.
    testExecCommandIsBareDollarArgsInNetworkOnly = {
      expr = render.mkExecCommand { };
      expected = ''"$@"'';
    };

    testNetworkPrecedesJailFragment = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "(deny default)\n";
            preflight = [ ];
            cleanup = [ ];
            env = { };
            envForward = [ ];
            binPaths = [ ];
            mainBin = "/nix/store/fake/bin/order";
          };
        };
        result = render.combinedSbplTemplate { jail = fakeJail; };
        proxyIdx = lib.strings.stringLength
          (builtins.head (lib.splitString
            ''(allow network-outbound (remote ip "localhost:__PROXYPORT__"))''
            result));
        jailIdx = lib.strings.stringLength
          (builtins.head (lib.splitString "(deny default)" result));
      in proxyIdx < jailIdx;
      expected = true;
    };

    # Issue 14: when the jail carries hostResolve entries, the wrapper's
    # sed pipeline must add one `-e "s|<placeholder>|${_jail_hr_<key>}|g"`
    # per entry. The bash variable name is derived from the placeholder by
    # lowercasing (and stripping the `__JAIL_HOST_RESOLVE_` prefix and
    # trailing `__`), which mirrors the convention slice 5's resolution
    # block uses to declare those variables. Sed delimiter is `|` (paths
    # contain `/`) — matches the existing __JAIL_CWD__ / __JAIL_HOME__
    # substitutions.
    testJailWrapperSedSubstitutesHostResolvePlaceholders = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [ ];
            cleanup = [ ];
            env = { };
            envForward = [ ];
            binPaths = [ ];
            hostResolve = [
              { placeholder = "__JAIL_HOST_RESOLVE_ETC_BASHRC__"; path = "/etc/bashrc"; }
              { placeholder = "__JAIL_HOST_RESOLVE_ETC_ZSHRC__"; path = "/etc/zshrc"; }
            ];
            mainBin = "/nix/store/fake/bin/host-resolve-sed";
          };
        };
        pipeline = render.mkProfileSedPipeline { jail = fakeJail; };
      in {
        hasBashrcSub = lib.hasInfix
          ''-e "s|__JAIL_HOST_RESOLVE_ETC_BASHRC__|''${_jail_hr_etc_bashrc}|g"''
          pipeline;
        hasZshrcSub = lib.hasInfix
          ''-e "s|__JAIL_HOST_RESOLVE_ETC_ZSHRC__|''${_jail_hr_etc_zshrc}|g"''
          pipeline;
        # Existing subs must still appear — host-resolve is additive.
        hasProxyPortSub = lib.hasInfix
          ''-e "s/__PROXYPORT__/''${_proxy_port}/g"'' pipeline;
        hasJailCwdSub = lib.hasInfix
          ''-e "s|__JAIL_CWD__|''${_jail_cwd}|g"'' pipeline;
      };
      expected = {
        hasBashrcSub = true;
        hasZshrcSub = true;
        hasProxyPortSub = true;
        hasJailCwdSub = true;
      };
    };

    # Issue 14: an empty hostResolve list (jail without host-resolve
    # combinators) must NOT add any sed args — the wrapper's pipeline
    # stays at the existing proxy-port + cwd + home triple. Anti-test
    # against a fold that would emit an empty `-e` argument.
    testJailWrapperSedNoHostResolveSubsWhenListEmpty = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [ ];
            cleanup = [ ];
            env = { };
            envForward = [ ];
            binPaths = [ ];
            hostResolve = [ ];
            mainBin = "/nix/store/fake/bin/host-resolve-empty-sed";
          };
        };
        pipeline = render.mkProfileSedPipeline { jail = fakeJail; };
      in {
        hasNoHostResolveSub = !(lib.hasInfix "__JAIL_HOST_RESOLVE_" pipeline);
        hasJailHomeSub = lib.hasInfix
          ''-e "s|__JAIL_HOME__|''${HOME}|g"'' pipeline;
      };
      expected = {
        hasNoHostResolveSub = true;
        hasJailHomeSub = true;
      };
    };

    # Issue 14: the resolution block runs BEFORE the sed pipeline (it
    # populates the bash variables sed references). For each hostResolve
    # entry, one line `_jail_hr_<key>="$(<readlink-bin> -f '<path>' || echo
    # <sentinel>)"`. Sentinel `/__jail_host_resolve_no_match_<key>__`
    # cannot match any real path; emphatically NOT `""` (which would
    # render as `(subpath "")` and match the entire filesystem). The
    # `readlinkBin` parameter lets the wrapper inject
    # `${pkgs.coreutils}/bin/readlink` while the render layer stays free
    # of pkgs.
    testHostResolveResolutionBlockEmitsReadlinkAndSentinelPerEntry = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [ ];
            cleanup = [ ];
            env = { };
            envForward = [ ];
            binPaths = [ ];
            hostResolve = [
              { placeholder = "__JAIL_HOST_RESOLVE_ETC_BASHRC__"; path = "/etc/bashrc"; }
              { placeholder = "__JAIL_HOST_RESOLVE_ETC_ZSHRC__"; path = "/etc/zshrc"; }
            ];
            mainBin = "/nix/store/fake/bin/host-resolve-block";
          };
        };
      in render.mkHostResolveResolutionBlock {
        jail = fakeJail;
        readlinkBin = "/fake/readlink";
      };
      expected = ''
        _jail_hr_etc_bashrc="$(/fake/readlink -f '/etc/bashrc' 2>/dev/null || echo '/__jail_host_resolve_no_match_etc_bashrc__')"
        _jail_hr_etc_zshrc="$(/fake/readlink -f '/etc/zshrc' 2>/dev/null || echo '/__jail_host_resolve_no_match_etc_zshrc__')"
      '';
    };

    # Issue 14: no jail → empty resolution block. Pins the network-only
    # contract: the wrapper script stays byte-for-byte identical to its
    # pre-issue-14 shape in that mode (no dead bash, no stray newlines).
    testHostResolveResolutionBlockEmptyWhenNoJail = {
      expr = render.mkHostResolveResolutionBlock {
        readlinkBin = "/fake/readlink";
      };
      expected = "";
    };

    # Issue 14: jail with an empty hostResolve list (no host-resolve
    # combinators) also emits empty text — no trailing newline. Pins the
    # same no-trailing-newline contract mkPreflightBlock / mkCleanupBlock
    # have. Anti-test against a `concatStringsSep "\n"` impl that leaves a
    # blank line in the rendered wrapper.
    testHostResolveResolutionBlockEmptyWhenListEmpty = {
      expr = let
        fakeJail = {
          jailData = {
            sbpl = "";
            preflight = [ ];
            cleanup = [ ];
            env = { };
            envForward = [ ];
            binPaths = [ ];
            hostResolve = [ ];
            mainBin = "/nix/store/fake/bin/host-resolve-empty-block";
          };
        };
      in render.mkHostResolveResolutionBlock {
        jail = fakeJail;
        readlinkBin = "/fake/readlink";
      };
      expected = "";
    };

    # Slice 0 (issue 12 prerequisite): the wrapper's bin name must be
    # configurable so per-jail builds can coexist on PATH. Without this,
    # `pkgs.callPackage <…>/packages/sandboxed-darwin { jail = jailedClaude; }`
    # and a second callPackage with `jail = jailedShell` would both produce
    # `$out/bin/sandboxed`, clashing when both end up in a devShell's PATH.
    # The default preserves the existing network-only contract: `sandboxed`.
    testBinNameDefaultsToSandboxed = {
      expr = (pkgs.callPackage ../packages/sandboxed-darwin/default.nix {
        sandbox-proxy = pkgs.runCommand "fake-sandbox-proxy" { } ''
          mkdir -p $out/bin; touch $out/bin/sandbox-proxy
        '';
      }).meta.mainProgram or "MISSING";
      expected = "sandboxed";
    };

    # Slice 0: with a custom binName, the wrapper's derivation `meta.mainProgram`
    # (and the bin under $out/bin/) reflects it. Templates pass
    # `binName = "sandboxed-jailed-claude"` (and `…-jailed-shell`) so the two
    # per-jail wrappers live side-by-side on PATH.
    testBinNameAcceptsCustomValue = {
      expr = (pkgs.callPackage ../packages/sandboxed-darwin/default.nix {
        sandbox-proxy = pkgs.runCommand "fake-sandbox-proxy" { } ''
          mkdir -p $out/bin; touch $out/bin/sandbox-proxy
        '';
        binName = "sandboxed-jailed-claude";
      }).meta.mainProgram or "MISSING";
      expected = "sandboxed-jailed-claude";
    };
  };

  failures = lib.runTests tests;

  # Slice-21 follow-up behaviour test: run the actual sed pipeline
  # against a fixture SBPL that carries the placeholder in BOTH forms
  # — destination paths (`/projects/__SLOP_ENV_PROJECT_NAME__/…`) AND
  # dash-form write-text store names
  # (`-projects-__SLOP_ENV_PROJECT_NAME__-…`). The pure pipeline test
  # above pins the anchored pattern in the rendered string; this one
  # pins sed's BEHAVIOUR against the canonical regression from
  # [[project-jail-nix-placeholder-substitution]]: a broad
  # `s|PLACEHOLDER|RESOLVED|g` would mangle the store name and bwrap /
  # sandbox-exec would deny the read.
  anchorFakeJail = {
    jailData = {
      sbpl = ""; preflight = [ ]; cleanup = [ ];
      env = { }; envForward = [ ]; binPaths = [ ]; hostResolve = [ ];
      mainBin = "/nix/store/fake/bin/anchor-behaviour";
    };
  };
  anchorPipeline = render.mkProfileSedPipeline { jail = anchorFakeJail; };
in
if failures != [ ] then
  throw "sandboxed-darwin tests failed:\n${builtins.toJSON failures}"
else
  pkgs.runCommand "sandboxed-darwin-tests" { } ''
    cat > fixture.sbpl <<'SBPL_EOF'
    (allow file-read* (literal "/Users/x/.local/state/claude/projects/__SLOP_ENV_PROJECT_NAME__/CLAUDE.md"))
    (allow file-read* (subpath "/nix/store/0000000000000000000000000000000000-jail-write-text--.local-state-claude-projects-__SLOP_ENV_PROJECT_NAME__-CLAUDE.md"))
    SBPL_EOF

    # The pipeline references bash vars the real wrapper sets at
    # invocation; for this behaviour test only `_project_name` matters
    # (the fixture has no __PROXYPORT__ / __JAIL_CWD__ / __JAIL_HOME__
    # tokens, so those subs are no-ops). Set them anyway so the splice
    # never expands to an empty argument.
    _proxy_port=0
    _jail_cwd=/tmp
    HOME=/tmp
    _project_name=myproj
    ${pkgs.gnused}/bin/sed ${anchorPipeline} fixture.sbpl > out.sbpl

    # Destination form: must be substituted with the resolved name.
    if ! ${pkgs.gnugrep}/bin/grep -q '/projects/myproj/CLAUDE.md' out.sbpl; then
      echo "FAIL: anchored sed did not substitute the destination path" >&2
      cat out.sbpl >&2
      exit 1
    fi

    # Dash-form store name: MUST survive verbatim. A broad pattern
    # would rewrite this to `-projects-myproj-CLAUDE.md`, breaking the
    # SBPL allow for the (real, on-disk) write-text artifact whose
    # store path was hashed with the placeholder baked in.
    if ! ${pkgs.gnugrep}/bin/grep -q -- '-projects-__SLOP_ENV_PROJECT_NAME__-CLAUDE.md' out.sbpl; then
      echo "FAIL: anchored sed mangled the dash-form write-text store name" >&2
      cat out.sbpl >&2
      exit 1
    fi

    echo "all sandboxed-darwin tests passed (incl. anchor behaviour)"
    touch $out
  ''
