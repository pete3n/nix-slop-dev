# Behavior tests for the macOS Jail combinator library (issue 10,
# slices 1-9 — the full library: scaffolding, all combinators, and
# the `jail` constructor that folds a list into a derivation +
# jailData ready for issue 11's wrapper composition).
#
# The library is pure Nix. Iterating during TDD:
#   nix-build tests/jail-lib.nix \
#     --arg pkgs '(import <nixpkgs> {})' --arg lib '(import <nixpkgs> {}).lib'
# In CI it is consumed via flake checks.{aarch64,x86_64}-darwin.jail-lib.
#
# Live `sandbox-exec -f` profile load remains HITL per spike methodology;
# tests here cover the pure SBPL-fragment + preflight + env emission only.
{ pkgs, lib }:
let
  jailLib = import ../lib/jail { inherit lib pkgs; };
  inherit (jailLib) emptySlice mergeSlices combinators prelude jail;
  inherit (combinators) set-env time-zone network no-new-session ro-bind rw-bind mount-cwd noescape tmpfs write-text try-readwrite try-fwd-env add-pkg-deps host-resolve;

  tests = {
    # Slice 1 tracer: set-env is the simplest combinator. No SBPL emission
    # (Seatbelt doesn't set env vars — the wrapper does), no preflight.
    # The combinator's job is purely to register a key/value the `jail`
    # constructor hands to /usr/bin/env -i at exec time.
    testSetEnvProducesEnvEntry = {
      expr = (set-env "FOO" "bar").env;
      expected = { FOO = "bar"; };
    };

    # Anti-test: set-env must not bleed into the other slice fields, or it
    # would silently emit junk SBPL when callers compose combinators.
    testSetEnvLeavesOtherSliceFieldsEmpty = {
      expr = let slice = set-env "FOO" "bar"; in {
        inherit (slice) sbpl preflight cleanup envForward binPaths;
      };
      expected = {
        sbpl = "";
        preflight = [];
        cleanup = [];
        envForward = [];
        binPaths = [];
      };
    };

    # Composition: two set-env calls merged via the library's slice-merge
    # helper produce a single slice with both env entries. This is what
    # the jail constructor will do over the user's combinator list.
    testMergeSlicesCombinesEnvEntries = {
      expr = (mergeSlices (set-env "A" "1") (set-env "B" "2")).env;
      expected = { A = "1"; B = "2"; };
    };

    # Anti-test: merging two slices that contribute only env must leave
    # the other slice fields empty. Catches a merge implementation that
    # accidentally concatenates "" + "" into something non-empty.
    testMergeSlicesPreservesEmptyShape = {
      expr = let merged = mergeSlices (set-env "A" "1") (set-env "B" "2"); in {
        inherit (merged) sbpl preflight cleanup envForward binPaths;
      };
      expected = {
        sbpl = "";
        preflight = [];
        cleanup = [];
        envForward = [];
        binPaths = [];
      };
    };

    # Slice 2: time-zone exposes the system timezone to the jailed process.
    # Linux jail-nix ro-binds /etc/localtime and its symlink target; on macOS
    # the equivalent is two SBPL allows:
    #   - the localtime symlink itself, kernel-canonicalised to /private/etc
    #   - the timezone data directory under /private/var/db
    # Both are needed because dyld / libsystem_c read the symlink to discover
    # the active zone and then read the zoneinfo file under /var/db.
    # We assert exact SBPL output; rule ordering is allow-only so order is
    # commutative for last-match-wins, but a stable serialisation keeps
    # diffs reviewable.
    testTimeZoneEmitsCanonicalSbpl = {
      expr = time-zone.sbpl;
      expected = ''
        (allow file-read* (literal "/private/etc/localtime"))
        (allow file-read* (subpath "/private/var/db/timezone"))
      '';
    };

    # Slice 2: network grants the filesystem reads a network-using process
    # needs on macOS. Outbound traffic is governed by the Sandbox boundary
    # (proxy + Seatbelt loopback pin per ADR-0003), so this combinator
    # ONLY emits filesystem allows. macOS-specific scope: just the DNS
    # files. TLS trust roots live under /System/Library (already in the
    # ADR-0004 prelude); Nix-built tools that need ca-bundle.crt get it
    # via add-pkg-deps on cacert (slice 8). Both files are emitted as
    # (literal …) — they are single regular files, not directories.
    testNetworkEmitsDnsAllows = {
      expr = network.sbpl;
      expected = ''
        (allow file-read* (literal "/private/etc/resolv.conf"))
        (allow file-read* (literal "/private/etc/hosts"))
      '';
    };

    # Slice 2: no-new-session is a no-op on Seatbelt. On Linux, jail-nix
    # uses it to disable bwrap's --new-session flag so TUI apps keep their
    # controlling TTY. macOS sandbox-exec does not start a new session at
    # all — the sandboxed process inherits the parent's TTY by default —
    # so the combinator has nothing to emit. It is kept as a named slice
    # (rather than removed) so cross-platform templates can list it bare
    # without conditional wrapping.
    #
    # The test asserts structural equivalence with emptySlice: any other
    # output (a stray newline, an env entry) would be silently spliced
    # into the Jail and surprise the caller.
    testNoNewSessionIsNoOp = {
      expr = no-new-session;
      expected = emptySlice;
    };

    # Slice 3 tracer: ro-bind with src == dst on a plain absolute path.
    # The most common case — most templates ask the jail to expose a
    # specific host path under the same path. On Linux this would be a
    # bind mount; on macOS the host path is already where the agent will
    # look for it, so the combinator's whole job is the SBPL allow.
    # Preflight stays empty: nothing to materialise.
    testRoBindSamePathEmitsReadAllowNoPreflight = {
      expr = let slice = ro-bind "/nix/store/abc/foo" "/nix/store/abc/foo"; in {
        inherit (slice) sbpl preflight;
      };
      # Issue 15: ro-bind pairs file-read* with process-exec on the same
      # canonical subpath, matching Linux bwrap's bind-mount semantics
      # (binding a dir into the jail makes its contents readable AND
      # exec'able). Without this, a ro-bound binary would dyld-load fine
      # but fail at the kernel exec call.
      expected = {
        sbpl = ''
          (allow file-read* (subpath "/nix/store/abc/foo"))
          (allow process-exec (subpath "/nix/store/abc/foo"))
        '';
        preflight = [];
      };
    };

    # Slice 3 + spike 10 F1: paths under /tmp, /var, /etc must be
    # rewritten to /private/tmp, /private/var, /private/etc before SBPL
    # emission. A rule on /tmp/foo silently matches nothing on macOS
    # because the kernel only ever sees /private/tmp/foo. We assert the
    # combinator rewrites the user-facing prefix; this is the only place
    # the canonicalization is exercised in slice 3, so a failure here
    # means every later bind-style combinator is also broken.
    testRoBindCanonicalizesTmpPrefix = {
      expr = (ro-bind "/tmp/spike/foo" "/tmp/spike/foo").sbpl;
      expected = ''
        (allow file-read* (subpath "/private/tmp/spike/foo"))
        (allow process-exec (subpath "/private/tmp/spike/foo"))
      '';
    };

    # The /var and /etc rewrites are the other two well-known macOS
    # symlinks. Cover them too — they are independent prefix tests, so
    # a fix that only handles /tmp would still fail here.
    testRoBindCanonicalizesVarPrefix = {
      expr = (ro-bind "/var/log/x" "/var/log/x").sbpl;
      expected = ''
        (allow file-read* (subpath "/private/var/log/x"))
        (allow process-exec (subpath "/private/var/log/x"))
      '';
    };

    testRoBindCanonicalizesEtcPrefix = {
      expr = (ro-bind "/etc/ssh/sshd_config" "/etc/ssh/sshd_config").sbpl;
      expected = ''
        (allow file-read* (subpath "/private/etc/ssh/sshd_config"))
        (allow process-exec (subpath "/private/etc/ssh/sshd_config"))
      '';
    };

    # Anti-test: only the /tmp, /var, /etc *prefixes* are rewritten.
    # A path that merely contains /tmp deeper in the tree (e.g.
    # /Users/x/tmp) must NOT be canonicalised, or we'd corrupt valid
    # paths. /private/* paths must also pass through untouched (already
    # canonical), or repeated canonicalization would double-prefix.
    testRoBindLeavesUnrelatedPathsAlone = {
      expr = {
        homeTmp = (ro-bind "/Users/x/tmp/foo" "/Users/x/tmp/foo").sbpl;
        alreadyCanonical = (ro-bind "/private/var/x" "/private/var/x").sbpl;
      };
      expected = {
        homeTmp = ''
          (allow file-read* (subpath "/Users/x/tmp/foo"))
          (allow process-exec (subpath "/Users/x/tmp/foo"))
        '';
        alreadyCanonical = ''
          (allow file-read* (subpath "/private/var/x"))
          (allow process-exec (subpath "/private/var/x"))
        '';
      };
    };

    # Slice 3 + spike 10 F6: SBPL string literals need " escaped as \"
    # and \ escaped as \\. An unescaped quote terminates the string
    # early and sandbox-exec fails with rc=65 ("unbound variable") —
    # fail-closed, but opaque. The combinator library is responsible
    # for eager escaping; callers must not have to escape their paths.
    # We construct paths containing each special character and assert
    # the emitted SBPL preserves them safely inside the quoted form.
    testRoBindEscapesSpecialChars = {
      expr = {
        quote = (ro-bind ''/Users/x/has"quote'' ''/Users/x/has"quote'').sbpl;
        backslash = (ro-bind ''/Users/x/has\back'' ''/Users/x/has\back'').sbpl;
      };
      expected = {
        quote = ''
          (allow file-read* (subpath "/Users/x/has\"quote"))
          (allow process-exec (subpath "/Users/x/has\"quote"))
        '';
        backslash = ''
          (allow file-read* (subpath "/Users/x/has\\back"))
          (allow process-exec (subpath "/Users/x/has\\back"))
        '';
      };
    };

    # Slice 3, src≠dst: when caller asks for src to appear at a
    # different jail path, the wrapper must materialise a symlink at
    # dst pointing to src before sandbox-exec runs. Per spike 10 F1
    # the SBPL allow still names src's canonical form (kernel resolves
    # symlinks at access time, then matches the resolved path against
    # the profile). The preflight script is `mkdir -p $(dirname dst);
    # ln -sfn src dst` — `-f` so we can overwrite a stale symlink from
    # a prior invocation, `-n` so we don't follow an existing symlink-
    # to-a-directory at dst and create the new link inside it. We use
    # parameter-expanded shell quoting (`"$path"`) so paths with spaces
    # survive; SBPL escaping is independent (already exercised above).
    testRoBindDifferentPathEmitsSymlinkPreflight = {
      expr = let slice = ro-bind "/nix/store/abc/env" "/usr/local/bin/env"; in {
        inherit (slice) sbpl preflight;
      };
      expected = {
        sbpl = ''
          (allow file-read* (subpath "/nix/store/abc/env"))
          (allow process-exec (subpath "/nix/store/abc/env"))
        '';
        preflight = [
          ''mkdir -p "/usr/local/bin" && ln -sfn "/nix/store/abc/env" "/usr/local/bin/env"''
        ];
      };
    };

    # Slice 3: rw-bind mirrors ro-bind but also grants file-write*.
    # Two SBPL rules (read + write) so that both opcodes are explicitly
    # allowed against the same subpath. Per spike 10 F5 the write rule
    # is symmetric with read — transitive over subdirectories, last-
    # match-wins for narrowing. Same-path case emits no preflight.
    testRwBindSamePathEmitsReadAndWriteAllow = {
      expr = let slice = rw-bind "/Users/x/work" "/Users/x/work"; in {
        inherit (slice) sbpl preflight;
      };
      # Issue 15: rw-bind tacks process-exec onto the read+write pair on
      # the same canonical subpath. Matches Linux bwrap's bind-mount
      # semantics — a writable bind is also exec'able (the typical case
      # is a build directory where the agent compiles + runs binaries).
      expected = {
        sbpl = ''
          (allow file-read* (subpath "/Users/x/work"))
          (allow file-write* (subpath "/Users/x/work"))
          (allow process-exec (subpath "/Users/x/work"))
        '';
        preflight = [];
      };
    };

    # rw-bind src≠dst: same preflight shape as ro-bind (symlink dst →
    # src), but the SBPL grants both read and write on the canonical
    # source. The symlink mechanism is independent of read-vs-write —
    # kernel still resolves dst at access time. Anti-test for a
    # plausible bug: forgetting to share the preflight branch with
    # ro-bind would emit no symlink here and the jailed process would
    # fail to open dst at all.
    testRwBindDifferentPathEmitsBothAllowsAndPreflight = {
      expr = let slice = rw-bind "/nix/store/abc/share" "/Users/x/share"; in {
        inherit (slice) sbpl preflight;
      };
      expected = {
        sbpl = ''
          (allow file-read* (subpath "/nix/store/abc/share"))
          (allow file-write* (subpath "/nix/store/abc/share"))
          (allow process-exec (subpath "/nix/store/abc/share"))
        '';
        preflight = [
          ''mkdir -p "/Users/x" && ln -sfn "/nix/store/abc/share" "/Users/x/share"''
        ];
      };
    };

    # Slice 4: mount-cwd grants read+write on the wrapper's current
    # working directory — the project root the jailed agent operates in.
    # The cwd isn't known at Nix-eval time, so the combinator emits the
    # `__JAIL_CWD__` placeholder token (matching the `__PROXYPORT__`
    # convention from mkSandboxProfileTemplate). The darwin wrapper
    # resolves the live cwd at runtime via `realpath -s "$PWD"` (this
    # also handles /tmp -> /private/tmp canonicalization for free) and
    # sed-substitutes the token before sandbox-exec loads the profile.
    # Wiring lives in slice 11; slice 4's contract is just the token
    # emission and the read/write pair.
    testMountCwdEmitsCwdPlaceholderReadAndWrite = {
      expr = mount-cwd.sbpl;
      # Issue 15: mount-cwd's process-exec lands on the same __JAIL_CWD__
      # placeholder. Real-world payoff: an agent running `./build.sh` or
      # `npm test` (which forks into ./node_modules/.bin scripts) at the
      # wrapper's cwd. The darwin wrapper sed-substitutes the placeholder
      # in BOTH the file-read*/file-write* and process-exec rules at the
      # same time, so they all land on the resolved cwd path.
      expected = ''
        (allow file-read* (subpath "__JAIL_CWD__"))
        (allow file-write* (subpath "__JAIL_CWD__"))
        (allow process-exec (subpath "__JAIL_CWD__"))
      '';
    };

    # Anti-test: mount-cwd must not bleed into preflight, cleanup, or
    # env. A naive impl that ran `pwd` at Nix-eval (impure), added a
    # mkdir-preflight (unnecessary — cwd already exists on the host
    # by definition), or attempted to clean up the cwd post-exec
    # (would delete the user's project directory) would silently
    # widen the slice surface. Catch the regression here.
    testMountCwdLeavesOtherSliceFieldsEmpty = {
      expr = {
        inherit (mount-cwd) preflight cleanup env envForward binPaths;
      };
      expected = {
        preflight = [];
        cleanup = [];
        env = {};
        envForward = [];
        binPaths = [];
      };
    };

    # Slice 5: noescape wraps a path string so combinators know it
    # carries runtime expansions (leading ~ that the wrapper must
    # expand to $HOME). The wire format mirrors upstream jail-nix's
    # helpers.nix exactly — `{ _noescape = <str>; }` — so templates
    # that pass `(ro-bind src (noescape "${cfgDir}/..."))` on Linux
    # work identically on macOS without API changes.
    testNoEscapeReturnsTaggedRecord = {
      expr = noescape "~/.cache";
      expected = { _noescape = "~/.cache"; };
    };

    # Slice 5: when a bind combinator receives a noescape-wrapped path
    # with a leading ~, the SBPL output substitutes __JAIL_HOME__ for
    # the ~. The wrapper resolves the placeholder via `$HOME` at runtime
    # (slice 11). canonicalizePath is skipped — ~/x always resolves to
    # /Users/<user>/x, which is already kernel-canonical (none of /tmp,
    # /var, /etc prefixes match). Same-noescape-value src/dst means no
    # preflight (bindPreflight compares the underlying strings).
    testRoBindNoEscapeSamePathEmitsHomePlaceholder = {
      expr = let slice = ro-bind (noescape "~/.cache") (noescape "~/.cache"); in {
        inherit (slice) sbpl preflight;
      };
      expected = {
        sbpl = ''
          (allow file-read* (subpath "__JAIL_HOME__/.cache"))
          (allow process-exec (subpath "__JAIL_HOME__/.cache"))
        '';
        preflight = [];
      };
    };

    # Slice 5: mixed noescape. The most common template pattern —
    # `(ro-bind "${nix-store-path}" (noescape "~/.config/foo"))` —
    # exposes a static nix-store source under a ~-rooted dst. The
    # SBPL allow names the plain (kernel-canonical) src; the
    # preflight materialises a symlink at the runtime-resolved dst.
    # Critically, the preflight uses `$HOME` (not `__JAIL_HOME__`)
    # because bash, not sandbox-exec, runs the snippet; `$HOME`
    # expands inside the surrounding "..." quotes.
    testRoBindMixedSrcPlainDstNoEscapeEmitsHomeShellExpansion = {
      expr = let slice = ro-bind "/nix/store/abc/cfg" (noescape "~/.config/foo"); in {
        inherit (slice) sbpl preflight;
      };
      expected = {
        sbpl = ''
          (allow file-read* (subpath "/nix/store/abc/cfg"))
          (allow process-exec (subpath "/nix/store/abc/cfg"))
        '';
        preflight = [
          ''mkdir -p "$HOME/.config" && ln -sfn "/nix/store/abc/cfg" "$HOME/.config/foo"''
        ];
      };
    };

    # Slice 5: rw-bind with both noescape and src≠dst. Templates use
    # this for shared writable state — a credentials file the agent
    # writes to. Anti-test for two plausible bugs:
    #   (1) using __JAIL_HOME__ (instead of $HOME) in the preflight,
    #       which sandbox-exec would never see and bash would treat
    #       as a literal directory name.
    #   (2) skipping the write allow because the src already has a
    #       read allow.
    testRwBindNoEscapeBothEmitsReadWriteAllowsAndShellPreflight = {
      expr = let slice = rw-bind (noescape "~/.shared/creds") (noescape "~/.jail/creds"); in {
        inherit (slice) sbpl preflight;
      };
      expected = {
        sbpl = ''
          (allow file-read* (subpath "__JAIL_HOME__/.shared/creds"))
          (allow file-write* (subpath "__JAIL_HOME__/.shared/creds"))
          (allow process-exec (subpath "__JAIL_HOME__/.shared/creds"))
        '';
        preflight = [
          ''mkdir -p "$HOME/.jail" && ln -sfn "$HOME/.shared/creds" "$HOME/.jail/creds"''
        ];
      };
    };

    # Anti-test: a plain string containing `~` is NOT a noescape —
    # the combinator treats it as a literal directory name (because
    # that's what the upstream API specifies). Catches a future
    # change that "helpfully" auto-detects `~` and expands it,
    # which would surprise template authors who depend on noescape
    # being explicit.
    testRoBindPlainTildeIsLiteral = {
      expr = (ro-bind "~/dont-expand" "~/dont-expand").sbpl;
      expected = ''
        (allow file-read* (subpath "~/dont-expand"))
        (allow process-exec (subpath "~/dont-expand"))
      '';
    };

    # Slice 6 tracer: tmpfs creates an ephemeral directory at `dst`
    # that subsequent combinators (ro-bind, write-text, try-readwrite)
    # populate. On Linux jail-nix this is a real tmpfs mount; on
    # Seatbelt we can't mount, so the wrapper mkdir's the dir
    # pre-exec and rm-rf's it post-exec to preserve the empty-at-start
    # semantic. The cleanup snippet lands in a new slice field
    # (`cleanup : [String]`) that the wrapper runs in reverse order
    # on EXIT/INT/TERM after sandbox-exec returns.
    #
    # SBPL: two allow rules — file-read* and file-write* on the
    # canonical subpath. Matches the rw-bind pattern from slice 3.
    # Preflight + cleanup use renderShellPath so /tmp -> /private/tmp
    # canonicalization happens for free; SBPL uses renderSbplPath.
    testTmpfsEmitsMkdirPreflightRmCleanupAndReadWriteSbpl = {
      expr = let slice = tmpfs "/Users/x/scratch"; in {
        inherit (slice) sbpl preflight cleanup;
      };
      # Issue 15: tmpfs adds process-exec on the same canonical subpath
      # as its read/write pair. The ephemeral directory holds whatever
      # the agent or its tools materialise — including binaries built or
      # downloaded mid-session — and Linux bwrap's tmpfs mount is exec'able
      # by default; matching that behaviour here keeps the cross-platform
      # contract honest.
      expected = {
        sbpl = ''
          (allow file-read* (subpath "/Users/x/scratch"))
          (allow file-write* (subpath "/Users/x/scratch"))
          (allow process-exec (subpath "/Users/x/scratch"))
        '';
        preflight = [ ''mkdir -p "/Users/x/scratch"'' ];
        cleanup = [ ''rm -rf "/Users/x/scratch"'' ];
      };
    };

    # The actual template pattern: `tmpfs (noescape "${cfgDir}")` where
    # cfgDir starts with `~/`. Verifies the two-renderer split wires
    # through preflight AND cleanup symmetrically — bash sees `$HOME`
    # in both, sandbox-exec sees `__JAIL_HOME__` in the SBPL. Anti-
    # test against a bug where cleanup re-uses the SBPL renderer and
    # we'd `rm -rf "__JAIL_HOME__/..."` (which bash treats as a
    # literal directory name — silent no-op cleanup, files persist).
    testTmpfsNoEscapeUsesHomeInShellAndPlaceholderInSbpl = {
      expr = let slice = tmpfs (noescape "~/.config/claude-code-jailed"); in {
        inherit (slice) sbpl preflight cleanup;
      };
      expected = {
        sbpl = ''
          (allow file-read* (subpath "__JAIL_HOME__/.config/claude-code-jailed"))
          (allow file-write* (subpath "__JAIL_HOME__/.config/claude-code-jailed"))
          (allow process-exec (subpath "__JAIL_HOME__/.config/claude-code-jailed"))
        '';
        preflight = [ ''mkdir -p "$HOME/.config/claude-code-jailed"'' ];
        cleanup = [ ''rm -rf "$HOME/.config/claude-code-jailed"'' ];
      };
    };

    # Slice 6 cross-cuts the schema. Sanity-check that emptySlice and
    # mergeSlices carry the new `cleanup` field correctly by merging
    # a tmpfs slice with a set-env (which contributes nothing to
    # cleanup). The merge result must have set-env's env entry AND
    # tmpfs's full preflight+cleanup pair. Catches a regression where
    # mergeSlices forgets to concat one of the new fields.
    testMergeSlicesConcatenatesCleanup = {
      expr = let merged = mergeSlices (tmpfs "/x") (set-env "K" "v"); in {
        inherit (merged) preflight cleanup env;
      };
      expected = {
        preflight = [ ''mkdir -p "/x"'' ];
        cleanup = [ ''rm -rf "/x"'' ];
        env = { K = "v"; };
      };
    };

    # Slice 7 tracer: write-text materialises `content` to a content-
    # addressed /nix/store path via builtins.toFile, then symlinks the
    # caller's `path` to it during preflight. SBPL allows the resolved
    # store path via `(literal …)` because spike 10 F4 confirms literal
    # is exact-file-only (matches the single-file write-text contract,
    # narrower than a subpath allow). Cleanup removes the symlink only
    # — the store entry stays for Nix to GC alongside the rest of the
    # build closure.
    #
    # Both sides of the test compute builtins.toFile independently with
    # the same name + content; content addressing guarantees they
    # produce the same store path. A future maintainer who renames the
    # toFile name argument in the impl will break this test, which is
    # by design — the name is part of the wire contract for hash
    # stability across rebuilds.
    testWriteTextEmitsSymlinkPreflightAndStoreLiteralAllow = {
      expr = let
        slice = write-text "/Users/x/cfg.json" ''{"key":"value"}'';
      in {
        inherit (slice) sbpl preflight cleanup;
      };
      # Issue 15: write-text pairs its file-read* (literal storePath)
      # allow with a process-exec (literal storePath) allow on the same
      # store path. Used for in-jail executable scripts (e.g. wrapper
      # shims) materialised at Nix-eval time — without the exec allow
      # the kernel rejects exec'ing the resolved store target. literal,
      # not subpath, because spike 10 F4: literal is exact-file (matches
      # the single-file write-text contract, narrower than subpath).
      expected = let
        storePath = builtins.toFile "jail-write-text" ''{"key":"value"}'';
      in {
        sbpl = ''
          (allow file-read* (literal "${storePath}"))
          (allow process-exec (literal "${storePath}"))
        '';
        preflight = [ ''mkdir -p "/Users/x" && ln -sfn "${storePath}" "/Users/x/cfg.json"'' ];
        cleanup = [ ''rm -f "/Users/x/cfg.json"'' ];
      };
    };

    # The actual template pattern:
    #   (write-text (noescape "${cfgDir}/settings.json") claudeSettings)
    # cfgDir starts with `~/`, so renderShellPath turns the dst into a
    # `$HOME`-prefixed string for both preflight (mkdir + ln) AND
    # cleanup (rm -f). SBPL is unaffected by the noescape because the
    # allow lands on the store path, not on the user-visible dst.
    # Anti-test against a bug where cleanup uses `__JAIL_HOME__`
    # (literal directory name in bash) — silent no-op rm, symlink
    # persists, tmpfs ephemerality breaks.
    testWriteTextNoEscapeUsesHomeInShellPreflightAndCleanup = {
      expr = let
        slice = write-text (noescape "~/.config/claude-code-jailed/settings.json") ''{"theme":"dark"}'';
      in {
        inherit (slice) sbpl preflight cleanup;
      };
      expected = let
        storePath = builtins.toFile "jail-write-text" ''{"theme":"dark"}'';
      in {
        sbpl = ''
          (allow file-read* (literal "${storePath}"))
          (allow process-exec (literal "${storePath}"))
        '';
        preflight = [
          ''mkdir -p "$HOME/.config/claude-code-jailed" && ln -sfn "${storePath}" "$HOME/.config/claude-code-jailed/settings.json"''
        ];
        cleanup = [ ''rm -f "$HOME/.config/claude-code-jailed/settings.json"'' ];
      };
    };

    # Anti-test: two write-text calls with the same content produce
    # IDENTICAL store paths, even at different destinations. This
    # confirms write-text relies on builtins.toFile's content
    # addressing — a future "optimization" that prepends the path
    # to the toFile name (e.g., to make the store name reflect the
    # destination) would break dedup and burn store space.
    testWriteTextSameContentSharesStorePath = {
      expr = let
        sliceA = write-text "/Users/a/x" "shared content";
        sliceB = write-text "/Users/b/y" "shared content";
        extractStorePath = sbpl:
          lib.elemAt (lib.match ''.*"(/nix/store/[^"]+)".*'' sbpl) 0;
      in extractStorePath sliceA.sbpl == extractStorePath sliceB.sbpl;
      expected = true;
    };

    # Slice 8: try-readwrite is the single-arg form of rw-bind for the
    # common "expose this host path read-write if it exists" pattern.
    # On Linux jail-nix it uses bwrap's --bind-try which silently no-ops
    # for missing sources; on Seatbelt the SBPL allow is unconditional
    # (a rule on a non-existent path is itself a no-op — the kernel
    # has no path to match against). No preflight or cleanup needed:
    # the path either exists (allow applies) or doesn't (allow is moot).
    testTryReadwriteEmitsReadAndWriteAllowsNoPreflightOrCleanup = {
      expr = let slice = try-readwrite "/Users/x/cache"; in {
        inherit (slice) sbpl preflight cleanup;
      };
      # Issue 15: try-readwrite mirrors rw-bind's process-exec pairing.
      # The unconditional allow (rule applies if path exists, no-ops
      # otherwise) shape is unchanged — the new process-exec line is
      # equally harmless when the host path is absent.
      expected = {
        sbpl = ''
          (allow file-read* (subpath "/Users/x/cache"))
          (allow file-write* (subpath "/Users/x/cache"))
          (allow process-exec (subpath "/Users/x/cache"))
        '';
        preflight = [];
        cleanup = [];
      };
    };

    # The actual template pattern: `try-readwrite (noescape "~/.cache")`.
    # Renders through the slice-5 path helpers — SBPL gets __JAIL_HOME__
    # placeholder; no preflight/cleanup means renderShellPath is not
    # exercised by this combinator. Anti-test against an over-eager
    # impl that grafts ro-bind's preflight onto try-readwrite (would
    # create a symlink at ~/.cache pointing to itself — bash error).
    testTryReadwriteNoEscapeUsesHomePlaceholderInSbpl = {
      expr = (try-readwrite (noescape "~/.cache")).sbpl;
      expected = ''
        (allow file-read* (subpath "__JAIL_HOME__/.cache"))
        (allow file-write* (subpath "__JAIL_HOME__/.cache"))
        (allow process-exec (subpath "__JAIL_HOME__/.cache"))
      '';
    };

    # Slice 8: try-fwd-env registers a host env var name for the
    # wrapper to conditionally forward (if set in the host env) to
    # the jailed process. The combinator's contribution is purely the
    # `envForward` field; the wrapper (slice 11) handles the runtime
    # check (`[ "${name+x}" = x ] && env_args+=(--setenv $name "$$name")`).
    testTryFwdEnvAppendsToEnvForward = {
      expr = (try-fwd-env "CLAUDE_CONFIG_DIR").envForward;
      expected = [ "CLAUDE_CONFIG_DIR" ];
    };

    # Anti-test: try-fwd-env must not leak into env (which is set-env's
    # field for unconditional values), preflight, sbpl, etc. Catches
    # a typo bug where the combinator accidentally writes to the
    # wrong slice field — would result in either a missing var at
    # runtime (env vs envForward swap) or stray SBPL emission.
    testTryFwdEnvLeavesOtherFieldsEmpty = {
      expr = let slice = try-fwd-env "FOO"; in {
        inherit (slice) sbpl preflight cleanup env binPaths;
      };
      expected = {
        sbpl = "";
        preflight = [];
        cleanup = [];
        env = {};
        binPaths = [];
      };
    };

    # Slice 8: add-pkg-deps takes a list of derivations and emits one
    # SBPL `(allow file-read* (subpath "<storepath>"))` per closure
    # member (narrow allow per the user's slice-8 choice — see commit
    # message), plus prepends `${pkg}/bin` to PATH via the binPaths
    # field. closure enumeration via pkgs.closureInfo +
    # builtins.readFile happens at Nix-eval time, so the SBPL string
    # is fully concrete by the time the wrapper runs.
    #
    # Test strategy: use a runCommand-built fake pkg with no runtime
    # deps. Its closure is just itself, which keeps the expected SBPL
    # shape deterministic across nixpkgs versions. A real pkg like
    # pkgs.hello would drag in libSystem etc., making the expected
    # closure non-portable.
    testAddPkgDepsEmitsClosureAllowAndBinPath = {
      expr = let
        fakePkg = pkgs.runCommand "jail-test-leaf-pkg" { } ''
          mkdir -p $out/bin
          : > $out/bin/leaf
        '';
        slice = add-pkg-deps [ fakePkg ];
      in {
        inherit (slice) sbpl binPaths preflight cleanup;
      };
      # Issue 15: every closure member gets a paired file-read* + process-exec
      # allow. The exec allow is on the same canonical subpath as the read,
      # mirroring Linux bwrap's bind-mount semantics (where binding the
      # closure dir makes its binaries both readable AND exec'able).
      expected = let
        fakePkg = pkgs.runCommand "jail-test-leaf-pkg" { } ''
          mkdir -p $out/bin
          : > $out/bin/leaf
        '';
      in {
        sbpl = ''
          (allow file-read* (subpath "${fakePkg}"))
          (allow process-exec (subpath "${fakePkg}"))
        '';
        binPaths = [ "${fakePkg}/bin" ];
        preflight = [];
        cleanup = [];
      };
    };

    # Empty list: closureInfo over an empty rootPaths returns an empty
    # store-paths file; concatMapStringsSep over an empty list is the
    # empty string; binPaths is empty. Anti-test against an impl that
    # short-circuits with a "default" allow on /nix/store or similar.
    testAddPkgDepsEmptyListIsNoOp = {
      expr = let slice = add-pkg-deps []; in {
        inherit (slice) sbpl binPaths preflight cleanup;
      };
      expected = {
        sbpl = "";
        binPaths = [];
        preflight = [];
        cleanup = [];
      };
    };

    # Multi-pkg: binPaths must preserve list order (PATH precedence
    # is order-sensitive; first-in-list wins lookup). The closure
    # SBPL allows can be in any order — last-match-wins on SBPL is
    # safe for allow-only rules — so we only assert binPaths order.
    testAddPkgDepsMultiPkgPreservesBinPathOrder = {
      expr = let
        pkgA = pkgs.runCommand "jail-test-pkg-a" { } ''mkdir -p $out/bin; : > $out/bin/a'';
        pkgB = pkgs.runCommand "jail-test-pkg-b" { } ''mkdir -p $out/bin; : > $out/bin/b'';
        slice = add-pkg-deps [ pkgA pkgB ];
      in slice.binPaths;
      expected = let
        pkgA = pkgs.runCommand "jail-test-pkg-a" { } ''mkdir -p $out/bin; : > $out/bin/a'';
        pkgB = pkgs.runCommand "jail-test-pkg-b" { } ''mkdir -p $out/bin; : > $out/bin/b'';
      in [ "${pkgA}/bin" "${pkgB}/bin" ];
    };

    # Slice 9 tracer: the jail constructor folds a combinator list and
    # prepends the ADR-0004 baseline. With an empty combinator list,
    # the SBPL fragment is exactly `(deny default)\n` followed by the
    # exported prelude — no combinator additions, just the baseline.
    # This is the most minimal jail anyone can construct; pins both
    # the deny-default-first rule (per ADR-0004) and the prelude
    # contents (which are themselves load-bearing: any change to the
    # prelude is a security-relevant decision).
    testJailEmptyListIsDenyDefaultPlusPrelude = {
      expr = let
        fakePkg = pkgs.runCommand "jail-test-empty-pkg" { } ''mkdir -p $out/bin; : > $out/bin/jail-test-empty'';
      in (jail "jail-test-empty" fakePkg []).jailData.sbpl;
      # The jail constructor implicitly adds pkg's closure to the SBPL
      # so mainBin (lib.getExe pkg) is readable — without it sandbox-exec
      # would refuse to launch the jailed binary at all ("Operation not
      # permitted" at exec time, issue 12 HITL surface). The pkg-closure
      # allows sit between prelude and the caller's combinators, so the
      # caller's allows can still override (last-match-wins).
      expected = let
        fakePkg = pkgs.runCommand "jail-test-empty-pkg" { } ''mkdir -p $out/bin; : > $out/bin/jail-test-empty'';
      in "(deny default)\n" + prelude + (add-pkg-deps [ fakePkg ]).sbpl;
    };

    # Slice 9: combinator-list fold. The SBPL is deny-default + prelude
    # + each combinator's SBPL in list order (last-match-wins makes
    # order within a single allow-only operation family commutative,
    # but stable ordering keeps diffs and HITL traces reviewable).
    # Order check: time-zone's first allow line appears AFTER the
    # prelude's last line; network's first allow appears AFTER
    # time-zone's last allow.
    testJailFoldsCombinatorSbplInListOrder = {
      expr = let
        fakePkg = pkgs.runCommand "jail-test-order-pkg" { } ''mkdir -p $out/bin; : > $out/bin/jail-test-order'';
      in (jail "jail-test-order" fakePkg [ time-zone network ]).jailData.sbpl;
      expected = let
        fakePkg = pkgs.runCommand "jail-test-order-pkg" { } ''mkdir -p $out/bin; : > $out/bin/jail-test-order'';
      in "(deny default)\n" + prelude
        + (add-pkg-deps [ fakePkg ]).sbpl
        + time-zone.sbpl
        + network.sbpl;
    };

    # Slice 9: every non-SBPL slice field (preflight, cleanup, env,
    # envForward, binPaths) propagates from the merged slice into
    # jailData. Mixing combinators that each touch a different field
    # so a failure isolates which propagation path is broken.
    testJailPropagatesAllMergedSliceFields = {
      expr = let
        leafPkg = pkgs.runCommand "jail-test-leaf-bin" { } ''mkdir -p $out/bin; : > $out/bin/leaf'';
        binDepPkg = pkgs.runCommand "jail-test-bin-dep" { } ''mkdir -p $out/bin; : > $out/bin/dep'';
        result = jail "jail-test-fields" leafPkg [
          (tmpfs "/tmp/jail-test-x")
          (set-env "JAIL_KEY" "jail-val")
          (try-fwd-env "JAIL_FWD")
          (add-pkg-deps [ binDepPkg ])
        ];
      in {
        preflight = result.jailData.preflight;
        cleanup = result.jailData.cleanup;
        env = result.jailData.env;
        envForward = result.jailData.envForward;
        binPaths = result.jailData.binPaths;
      };
      expected = let
        binDepPkg = pkgs.runCommand "jail-test-bin-dep" { } ''mkdir -p $out/bin; : > $out/bin/dep'';
      in {
        preflight = [ ''mkdir -p "/private/tmp/jail-test-x"'' ];
        cleanup = [ ''rm -rf "/private/tmp/jail-test-x"'' ];
        env = { JAIL_KEY = "jail-val"; };
        envForward = [ "JAIL_FWD" ];
        binPaths = [ "${binDepPkg}/bin" ];
      };
    };

    # Slice 9: the constructor returns a derivation (via
    # pkgs.writeShellScriptBin) so it can sit in a template's
    # buildInputs / packages.${system}.<name> exactly like upstream
    # jail-nix. lib.isDerivation pins the contract — issue 11 will
    # later assert on the same attr to detect "this is a jailed
    # pkg, splice its jailData".
    #
    # mainBin uses `lib.getExe pkg` — the nixpkgs convention. Templates
    # pass real packages (pkgs.bashInteractive, llm-agents.claude-code,
    # …) where the wrapper drv's name ("jailed-shell", "jailed-claude")
    # differs from the binary inside the pkg ("bash", "claude"). HITL on
    # issue 12 surfaced the original `${pkg}/bin/${name}` shape as a
    # contract bug: it forced callers to hand-build wrapper drvs whose
    # bin/<name> matched the jail's wrapper name, which is exactly the
    # boilerplate getExe exists to avoid. meta.mainProgram (or pname
    # fallback) is what real pkgs already expose.
    testJailMainBinUsesGetExe = {
      expr = let
        leafPkg = pkgs.runCommand "jail-test-drv-pkg"
          { meta.mainProgram = "leaf-binary"; }
          ''mkdir -p $out/bin; : > $out/bin/leaf-binary'';
        result = jail "jail-test-drv" leafPkg [];
      in {
        isDerivation = lib.isDerivation result;
        mainBin = result.jailData.mainBin;
      };
      expected = let
        leafPkg = pkgs.runCommand "jail-test-drv-pkg"
          { meta.mainProgram = "leaf-binary"; }
          ''mkdir -p $out/bin; : > $out/bin/leaf-binary'';
      in {
        isDerivation = true;
        mainBin = "${leafPkg}/bin/leaf-binary";
      };
    };

    # Issue 14 tracer: emptySlice carries a `hostResolve` field — the
    # combinator-side propagation slot for host-resolve entries. Each entry
    # is `{ placeholder; path; }`: SBPL holds the placeholder verbatim and
    # the darwin wrapper resolves `path` via `readlink -f` at preflight,
    # sed-substituting the placeholder before sandbox-exec loads the
    # profile. The slot is `[]` by default so combinators that don't touch
    # host-resolve contribute nothing. (Mirrors the empty-list defaults of
    # preflight/cleanup/envForward/binPaths.)
    testEmptySliceHasHostResolveField = {
      expr = emptySlice.hostResolve;
      expected = [ ];
    };

    # Issue 14: mergeSlices concatenates hostResolve entries from both
    # sides in left-then-right order. The merge fold inside the `jail`
    # constructor depends on this — two host-resolve combinators in the
    # caller's list must produce two distinct entries in the merged slice.
    # Anti-test for a `//` impl that would silently overwrite left's list
    # with right's.
    testMergeSlicesConcatenatesHostResolve = {
      expr = (mergeSlices
        (emptySlice // { hostResolve = [ { placeholder = "A"; path = "/a"; } ]; })
        (emptySlice // { hostResolve = [ { placeholder = "B"; path = "/b"; } ]; })
      ).hostResolve;
      expected = [
        { placeholder = "A"; path = "/a"; }
        { placeholder = "B"; path = "/b"; }
      ];
    };

    # Issue 14 tracer: host-resolve takes a host path whose canonical
    # target is only knowable at wrapper runtime (typical case: a symlink
    # under /etc managed by nix-darwin that points into /nix/store). The
    # SBPL allow names a placeholder `__JAIL_HOST_RESOLVE_<KEY>__` that
    # the darwin wrapper sed-substitutes with `readlink -f <path>` at
    # preflight time; the hostResolve entry carries both the placeholder
    # and the original path so the wrapper can do the resolution. Key is
    # derived from the path by uppercasing and replacing non-alnum chars
    # with `_`, with any leading `_` stripped — predictable and reviewable
    # in the rendered profile (vs. a hash).
    testHostResolveEmitsPlaceholderAndEntry = {
      expr = let slice = host-resolve "/etc/bashrc"; in {
        sbpl = slice.sbpl;
        hostResolve = slice.hostResolve;
      };
      expected = {
        sbpl = ''
          (allow file-read* (subpath "__JAIL_HOST_RESOLVE_ETC_BASHRC__"))
        '';
        hostResolve = [ {
          placeholder = "__JAIL_HOST_RESOLVE_ETC_BASHRC__";
          path = "/etc/bashrc";
        } ];
      };
    };

    # Issue 14: anti-test against bleeding into other slice fields. The
    # combinator must touch ONLY sbpl + hostResolve — no preflight (the
    # readlink happens in the wrapper's pre-sed phase, not the lib/jail
    # preflight list), no cleanup (read-only allow), no env/binPaths.
    # A naive impl that grafted a `readlink -f` onto preflight would
    # silently fire on Linux templates too (lib/jail emits the slice
    # unconditionally; the issue's cross-platform constraint demands the
    # only consumer be the darwin wrapper).
    testHostResolveLeavesOtherSliceFieldsEmpty = {
      expr = let slice = host-resolve "/etc/bashrc"; in {
        inherit (slice) preflight cleanup env envForward binPaths;
      };
      expected = {
        preflight = [ ];
        cleanup = [ ];
        env = { };
        envForward = [ ];
        binPaths = [ ];
      };
    };

    # Issue 14: deeper paths and non-alnum chars normalise to underscores.
    # Anti-test for a regex that only handles `/` or that drops `.` and
    # `-` silently, producing colliding placeholders for distinct paths.
    # Issue 14: the jail constructor must propagate the merged hostResolve
    # list into jailData so the darwin wrapper (slice 11) can iterate it
    # to emit per-entry sed substitutions. Multiple host-resolve calls in
    # the combinator list must appear in list order — the wrapper builds
    # its sed pipeline by iterating this list, and stable order keeps
    # rendered scripts diff-reviewable.
    testJailPropagatesHostResolveThroughJailData = {
      expr = let
        leafPkg = pkgs.runCommand "jail-test-host-resolve-pkg" { } ''
          mkdir -p $out/bin; : > $out/bin/jail-test-host-resolve
        '';
        result = jail "jail-test-host-resolve" leafPkg [
          (host-resolve "/etc/bashrc")
          (host-resolve "/etc/zshrc")
        ];
      in result.jailData.hostResolve;
      expected = [
        { placeholder = "__JAIL_HOST_RESOLVE_ETC_BASHRC__"; path = "/etc/bashrc"; }
        { placeholder = "__JAIL_HOST_RESOLVE_ETC_ZSHRC__"; path = "/etc/zshrc"; }
      ];
    };

    testHostResolveKeyDerivationHandlesNonAlnumChars = {
      expr = {
        deep = (host-resolve "/etc/zsh/zshrc").hostResolve;
        dotted = (host-resolve "/etc/foo.conf").hostResolve;
        dashed = (host-resolve "/etc/foo-bar").hostResolve;
      };
      expected = {
        deep = [ {
          placeholder = "__JAIL_HOST_RESOLVE_ETC_ZSH_ZSHRC__";
          path = "/etc/zsh/zshrc";
        } ];
        dotted = [ {
          placeholder = "__JAIL_HOST_RESOLVE_ETC_FOO_CONF__";
          path = "/etc/foo.conf";
        } ];
        dashed = [ {
          placeholder = "__JAIL_HOST_RESOLVE_ETC_FOO_BAR__";
          path = "/etc/foo-bar";
        } ];
      };
    };

    # Issue 15 tracer: the prelude must NOT carry the blanket
    # `(allow process*)` rule. That rule covers process-exec without a
    # path predicate, which on a non-deny-default macOS userland lets the
    # jail exec any /usr/bin binary that links libSystem (python3,
    # osascript, nscurl, defaults, launchctl, etc.) — far wider than the
    # Linux bwrap implementation, where /usr/bin/curl literally doesn't
    # exist inside the jail unless explicitly bound. The new prelude
    # replaces the blanket allow with the narrow non-exec subset plus a
    # single exec-allow on /usr/bin/env (the wrapper's first exec call
    # via `sandbox-exec -f profile /usr/bin/env -i …` — without this, no
    # jail launches at all). Per-combinator process-exec allows pick up
    # from there.
    testPreludeDropsBlanketProcessAllow = {
      expr = lib.hasInfix "(allow process*)" prelude;
      expected = false;
    };

    # Issue 15: the narrowed prelude carries process-fork (so any
    # sub-process plumbing works), process-info* (so /proc-style
    # introspection within the jail works), and a single exec-allow on
    # /usr/bin/env (the wrapper's entry point). Pinned via hasInfix so a
    # silent removal of any one of these surfaces as a test failure but
    # additions stay reviewable.
    testPreludeCarriesNarrowProcessAllows = {
      expr = {
        processFork = lib.hasInfix "(allow process-fork)" prelude;
        processInfo = lib.hasInfix "(allow process-info*)" prelude;
        execEnv = lib.hasInfix ''(allow process-exec (literal "/usr/bin/env"))'' prelude;
      };
      expected = {
        processFork = true;
        processInfo = true;
        execEnv = true;
      };
    };

    # Issue 15 anti-test: the prelude carries no other process-exec
    # allows beyond the /usr/bin/env entry point. Combinators that
    # expose paths (ro-bind, rw-bind, tmpfs, write-text, mount-cwd,
    # add-pkg-deps, try-readwrite) emit their own process-exec rules
    # alongside their file-read* rules — the prelude must not pre-allow
    # any host-binary exec the way the old `(allow process*)` did.
    testPreludeCarriesNoOtherProcessExecAllows = {
      expr = let
        execAllowCount = lib.length (lib.filter
          (line: lib.hasInfix "process-exec" line)
          (lib.splitString "\n" prelude));
      in execAllowCount;
      expected = 1;
    };

    # Issue 15 end-to-end: a fully-composed jail emits exactly one
    # process-exec rule for /usr/bin/env (from the prelude) and one per
    # closure subpath (from the implicit + explicit add-pkg-deps). No
    # process-exec rule should land on /usr/bin/curl, /usr/bin/python3,
    # /usr/sbin/sshd, or any other host-binary path the old `(allow
    # process*)` would have silently covered. This pins the security
    # property end-to-end across the constructor's fold + prelude
    # composition, catching any future regression that re-introduces a
    # blanket exec allow somewhere in the assembly pipeline.
    testJailEndToEndProcessExecOnlyEnvAndClosures = {
      expr = let
        leafPkg = pkgs.runCommand "jail-test-end-to-end-pkg" { } ''
          mkdir -p $out/bin; : > $out/bin/jail-test-end-to-end
        '';
        result = jail "jail-test-end-to-end" leafPkg [
          time-zone
          network
          mount-cwd
          (set-env "FOO" "bar")
        ];
        sbpl = result.jailData.sbpl;
      in {
        envExecPresent = lib.hasInfix
          ''(allow process-exec (literal "/usr/bin/env"))'' sbpl;
        cwdExecPresent = lib.hasInfix
          ''(allow process-exec (subpath "__JAIL_CWD__"))'' sbpl;
        curlExecAbsent = !(lib.hasInfix "/usr/bin/curl" sbpl);
        python3ExecAbsent = !(lib.hasInfix "/usr/bin/python3" sbpl);
        sshdExecAbsent = !(lib.hasInfix "/usr/sbin/sshd" sbpl);
        blanketProcessAllowAbsent = !(lib.hasInfix "(allow process*)" sbpl);
      };
      expected = {
        envExecPresent = true;
        cwdExecPresent = true;
        curlExecAbsent = true;
        python3ExecAbsent = true;
        sshdExecAbsent = true;
        blanketProcessAllowAbsent = true;
      };
    };

    # Issue 15 end-to-end: non-exec-emitting combinators (time-zone,
    # network, host-resolve, set-env, try-fwd-env, no-new-session,
    # noescape) contribute no process-exec rules. Pins the negative side
    # of the per-combinator contract from the issue's "Combinators that
    # do NOT emit process-exec" section. host-resolve is the trickiest
    # one: its read-only design rules out exec by intent (use case is
    # /etc/bashrc-style config files, not binaries). A future change
    # that "helpfully" pairs every file-read* with process-exec would
    # silently widen the exec surface; this test catches that.
    testNonExecCombinatorsEmitNoProcessExec = {
      expr = {
        timeZone = lib.hasInfix "process-exec" time-zone.sbpl;
        network = lib.hasInfix "process-exec" network.sbpl;
        setEnv = lib.hasInfix "process-exec" (set-env "K" "v").sbpl;
        tryFwdEnv = lib.hasInfix "process-exec" (try-fwd-env "FOO").sbpl;
        noNewSession = lib.hasInfix "process-exec" no-new-session.sbpl;
        hostResolve = lib.hasInfix "process-exec" (host-resolve "/etc/bashrc").sbpl;
      };
      expected = {
        timeZone = false;
        network = false;
        setEnv = false;
        tryFwdEnv = false;
        noNewSession = false;
        hostResolve = false;
      };
    };

    # Regression net for the HITL findings on feature/macos-nix-darwin
    # (issue 12 follow-up). Each of these allows was surfaced by an actual
    # `Operation not permitted` from `jail-shell` against a live macOS
    # 15.6.1 host: bash interactive startup, `/usr/bin/curl` (LibreSSL),
    # locale-aware libc, and the TTY ioctl bash needs to set the
    # foreground process group. Pinning them as individual hasInfix
    # assertions (vs. byte-pinning the whole prelude) keeps later
    # additions reviewable but blocks a silent removal of any one rule.
    testPreludeCarriesHitlSurfacedAllows = {
      expr = {
        ttyIoctl = lib.hasInfix ''(allow file-ioctl (subpath "/dev"))'' prelude;
        devNullWrite = lib.hasInfix ''(allow file-write-data (literal "/dev/null"))'' prelude;
        devTtyWrite = lib.hasInfix ''(allow file-write-data (literal "/dev/tty"))'' prelude;
        usrShareLocale = lib.hasInfix ''(allow file-read* (subpath "/usr/share/locale"))'' prelude;
        etcBashBashrc = lib.hasInfix ''(allow file-read* (literal "/private/etc/bash.bashrc"))'' prelude;
        etcBashrc = lib.hasInfix ''(allow file-read* (literal "/private/etc/bashrc"))'' prelude;
        etcPaths = lib.hasInfix ''(allow file-read* (literal "/private/etc/paths"))'' prelude;
        etcPathsD = lib.hasInfix ''(allow file-read* (subpath "/private/etc/paths.d"))'' prelude;
        etcProfile = lib.hasInfix ''(allow file-read* (literal "/private/etc/profile"))'' prelude;
        etcSsl = lib.hasInfix ''(allow file-read* (subpath "/private/etc/ssl"))'' prelude;
      };
      expected = {
        ttyIoctl = true;
        devNullWrite = true;
        devTtyWrite = true;
        usrShareLocale = true;
        etcBashBashrc = true;
        etcBashrc = true;
        etcPaths = true;
        etcPathsD = true;
        etcProfile = true;
        etcSsl = true;
      };
    };
  };

  failures = lib.runTests tests;
in
if failures == [ ] then
  pkgs.runCommand "jail-lib-tests" { } ''
    echo "all jail-lib tests passed"
    touch $out
  ''
else
  throw "jail-lib tests failed:\n${builtins.toJSON failures}"
