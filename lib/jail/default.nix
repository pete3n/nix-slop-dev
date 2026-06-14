# Jail combinator library for macOS (Seatbelt). Pure Nix.
#
# Each combinator returns a *slice*:
#
#   { sbpl       : String     # SBPL fragment appended to the Jail profile
#   ; preflight  : [String]   # shell snippets the wrapper runs before sandbox-exec
#   ; cleanup    : [String]   # shell snippets the wrapper runs AFTER sandbox-exec
#                             #   exits, in reverse-of-merge order (LIFO).
#                             #   Used by tmpfs and other combinators that need to
#                             #   tear down resources they materialised in preflight.
#   ; env        : AttrSet    # KEY = "value" pairs to set via /usr/bin/env -i
#   ; envForward : [String]   # env var names to forward from the host
#   ; binPaths   : [String]   # /bin paths to prepend to PATH (add-pkg-deps)
#   }
#
# The `jail` constructor (slice 9) folds a user-supplied combinator list into
# a single slice, then renders the profile + preflight + exec line.
#
# Combinators landed so far:
#   - `set-env` (slice 1 tracer)
#   - `time-zone` / `network` / `no-new-session` (slice 2, pure SBPL)
#   - `ro-bind` / `rw-bind` (slice 3, SBPL + symlink preflight; first
#     slice that exercises `canonicalizePath` and `sbplEscape`)
#   - `mount-cwd` (slice 4, first runtime-substitution placeholder
#     emission — see __JAIL_* convention below)
#   - `noescape` + leading-~ expansion (slice 5, second runtime
#     placeholder — __JAIL_HOME__ — and the helpers ro-bind/rw-bind
#     use to render paths for SBPL vs preflight contexts)
#   - `tmpfs` (slice 6, first combinator with a non-symlink preflight
#     and the first to use the new `cleanup` slice field)
#   - `write-text` (slice 7, first combinator that materialises
#     content via builtins.toFile + symlink — SBPL allow lands on
#     the resolved /nix/store path via `(literal …)`)
#   - `try-readwrite` / `try-fwd-env` / `add-pkg-deps` (slice 8;
#     add-pkg-deps is the first combinator that needs pkgs at lib
#     instantiation — uses pkgs.closureInfo + builtins.readFile to
#     enumerate the closure at Nix-eval time)
#
# Plus the `jail` constructor (slice 9) which folds a combinator
# list, prepends `(deny default)` + the ADR-0004 prelude, and
# returns a derivation with a `.jailData` attr that issue 11's
# sandboxed-darwin wrapper consumes.
#
# Runtime-substitution placeholder convention: tokens of the form
# `__JAIL_*__` (all-caps, double-underscore-flanked, JAIL_-namespaced)
# appear verbatim in the SBPL output of combinators that depend on
# wrapper-runtime data. The darwin wrapper sed-substitutes them
# before sandbox-exec loads the profile. Mirrors the `__PROXYPORT__`
# scheme in `modules/macos-sandbox/profile.nix` and uses the JAIL_
# prefix so Jail-side tokens cannot collide with Sandbox-side ones.
# Substitution lives in slice 11 (Jail+Sandbox wrapper composition).
{ lib, pkgs }:
let
  emptySlice = {
    sbpl = "";
    preflight = [ ];
    cleanup = [ ];
    env = { };
    envForward = [ ];
    binPaths = [ ];
    hostResolve = [ ];
  };

  mergeSlices = left: right: {
    sbpl = left.sbpl + right.sbpl;
    preflight = left.preflight ++ right.preflight;
    cleanup = left.cleanup ++ right.cleanup;
    env = left.env // right.env;
    envForward = left.envForward ++ right.envForward;
    binPaths = left.binPaths ++ right.binPaths;
    hostResolve = left.hostResolve ++ right.hostResolve;
  };

  # Rewrites a path to its macOS kernel-canonical form by replacing the
  # well-known top-level symlinks (/tmp, /var, /etc) with their resolved
  # targets under /private. SBPL matches the canonical form (spike 10
  # F1) — a rule on /tmp/foo silently matches nothing because the
  # kernel only sees /private/tmp/foo. Paths that don't start with one
  # of the rewritten prefixes (including paths that merely *contain*
  # /tmp deeper in the tree, and paths already under /private) pass
  # through unchanged.
  canonicalizePath = path:
    if lib.hasPrefix "/tmp/" path || path == "/tmp"
    then "/private" + path
    else if lib.hasPrefix "/var/" path || path == "/var"
    then "/private" + path
    else if lib.hasPrefix "/etc/" path || path == "/etc"
    then "/private" + path
    else path;

  # Escapes a string for use inside an SBPL string literal.
  # Per spike 10 F6: " must become \" (otherwise the string terminates
  # early and sandbox-exec fails with the opaque rc=65 "unbound
  # variable" error); \ must become \\ (TinyScheme-lineage parser).
  # Spaces and parens inside a quoted literal are fine unescaped.
  # Order matters: backslash MUST be replaced first so the \ inserted
  # for the quote-escape isn't itself escaped on a second pass.
  sbplEscape = str:
    let backslashSafe = lib.replaceStrings [ "\\" ] [ "\\\\" ] str;
    in lib.replaceStrings [ ''"'' ] [ ''\"'' ] backslashSafe;

  # True when `value` was wrapped by `combinators.noescape`. The wrapper
  # is the only structural shape combinators distinguish from a plain
  # string for path arguments.
  isNoEscape = value:
    builtins.typeOf value == "set" && value ? _noescape;

  # Returns the underlying path string for either a plain string or a
  # noescape-wrapped value. Used for src/dst equality comparison in
  # `bindPreflight` so `(noescape "~/x") == (noescape "~/x")` evaluates
  # to "same path" via string identity rather than Nix set equality.
  resolvePath = path:
    if isNoEscape path then path._noescape else path;

  # Replaces a leading `~/` (or bare `~`) with `repl`. Mid-string `~`
  # is left alone — filenames legitimately containing `~` (e.g. emacs
  # backup files like `foo~`) must not be rewritten. Behaviour for `~`
  # at position 0 mirrors POSIX shell tilde expansion.
  expandLeadingTilde = repl: str:
    if lib.hasPrefix "~/" str
    then repl + lib.removePrefix "~" str
    else if str == "~"
    then repl
    else str;

  # Renders a path for emission inside an SBPL string literal.
  # - Plain string: canonicalize the macOS symlinks (/tmp, /var, /etc)
  #   then SBPL-escape (per spike 10 F1 + F6).
  # - noescape value: replace leading ~ with the __JAIL_HOME__
  #   placeholder (wrapper sed-substitutes it), then SBPL-escape.
  #   Canonicalization is skipped because ~/... always resolves under
  #   /Users/<user>, which has no /tmp /var /etc prefix overlap.
  renderSbplPath = path:
    if isNoEscape path
    then sbplEscape (expandLeadingTilde "__JAIL_HOME__" path._noescape)
    else sbplEscape (canonicalizePath path);

  # Renders a path for emission inside a double-quoted shell argument
  # in a preflight snippet.
  # - Plain string: canonicalize (so the bash `mkdir -p` lands on the
  #   real path the kernel will resolve to).
  # - noescape value: replace leading ~ with literal `$HOME`. Bash
  #   expands `$HOME` even inside "..." quoting, so the resulting
  #   `"$HOME/x"` string interpolates correctly at preflight time.
  renderShellPath = path:
    if isNoEscape path
    then expandLeadingTilde "$HOME" path._noescape
    else canonicalizePath path;

  # The ADR-0004 curated prelude: the minimum SBPL allows that make a
  # `(deny default)` jail usable for any process at all. Discovered in
  # spike 10 probe 01h. Allows process plumbing (process-fork,
  # process-info*, sysctl-read, mach-lookup, ipc-posix-shm*, signal),
  # root metadata reads (so the kernel can resolve any path), and the
  # load-time read paths libsystem / dyld need (/usr/lib, /System/Library,
  # /usr/share/icu, dyld cache, timezone). The prelude grows organically
  # as new agents added to the templates surface dyld or Mach-service
  # failures during HITL smoke. Exposed so templates can introspect.
  #
  # Issue 15 narrows the historical `(allow process*)` (which silently
  # covered process-exec without a path predicate, granting the jail
  # exec authority over the entire macOS userland) to:
  #   - process-fork: any sub-process plumbing.
  #   - process-info*: /proc-style introspection within the jail.
  #   - process-exec (literal "/usr/bin/env"): the wrapper's entry
  #     point — `sandbox-exec -f profile /usr/bin/env -i …` is the
  #     first exec call the kernel sees inside the jail. Without it
  #     no jail launches at all. All other exec authority is opted into
  #     per-path by each bind-style combinator (matching Linux bwrap,
  #     where /usr/bin/curl only exists inside the jail if explicitly
  #     bound).
  #
  # Issue-12 HITL follow-up additions (jail-shell + /usr/bin/curl):
  #   - file-ioctl /dev: bash TIOCSPGRP for interactive job control.
  #   - file-write-data /dev/null + /dev/tty: `>/dev/null 2>&1` everywhere,
  #     and tools that prompt via the controlling terminal.
  #   - /usr/share/locale: locale-aware libc (LC_CTYPE under UTF-8).
  #   - /private/etc/profile, /private/etc/bash.bashrc, /private/etc/bashrc:
  #     bash login startup chain. On nix-darwin /etc/bashrc symlinks into
  #     /nix/store so the literal rule misses it, but /etc/profile's
  #     `[ -r /etc/bashrc ] && . /etc/bashrc` test fails closed (no read
  #     permission → -r is false) so the deny silently skips rather than
  #     producing a visible error.
  #   - /private/etc/paths + /private/etc/paths.d: path_helper invocation
  #     from /etc/profile.
  #   - /private/etc/ssl: /usr/bin/curl ships against system LibreSSL
  #     which reads openssl.cnf + cert.pem at startup.
  prelude = ''
    (allow process-fork)
    (allow process-info*)
    (allow process-exec (literal "/usr/bin/env"))
    (allow sysctl-read)
    (allow mach-lookup)
    (allow ipc-posix-shm*)
    (allow signal)
    (allow file-ioctl (subpath "/dev"))
    (allow file-write-data (literal "/dev/null"))
    (allow file-write-data (literal "/dev/tty"))
    (allow file-read-metadata (subpath "/"))
    (allow file-read* (literal "/"))
    (allow file-read* (subpath "/usr/lib"))
    (allow file-read* (subpath "/usr/share/icu"))
    (allow file-read* (subpath "/usr/share/locale"))
    (allow file-read* (subpath "/System/Library"))
    (allow file-read* (literal "/private/etc/bash.bashrc"))
    (allow file-read* (literal "/private/etc/bashrc"))
    (allow file-read* (literal "/private/etc/paths"))
    (allow file-read* (subpath "/private/etc/paths.d"))
    (allow file-read* (literal "/private/etc/profile"))
    (allow file-read* (subpath "/private/etc/ssl"))
    (allow file-read* (subpath "/private/var/db/dyld"))
    (allow file-read* (subpath "/private/var/db/timezone"))
  '';

  # Materialises a symlink at `dst` pointing to `src`, so the jailed
  # process can open dst and have the kernel resolve it back to src.
  # When src and dst resolve to the same underlying string, the host
  # filesystem already has src in the right place and no preflight is
  # needed. -f overwrites a stale link from a prior invocation; -n
  # stops `ln` from descending into an existing symlinked-directory at
  # dst and creating the new link inside it. Used by every bind-style
  # combinator (ro-bind, rw-bind, later write-text / try-* variants).
  bindPreflight = src: dst:
    lib.optional (resolvePath src != resolvePath dst)
      (let
        srcShell = renderShellPath src;
        dstShell = renderShellPath dst;
      in ''mkdir -p "${dirOf dstShell}" && ln -sfn "${srcShell}" "${dstShell}"'');

  combinators = {
    set-env = key: value:
      emptySlice // { env = { ${key} = value; }; };

    # Exposes the system timezone to the jailed process. On macOS the kernel-
    # canonical paths are /private/etc/localtime (a symlink to the active
    # zone under /private/var/db/timezone) and /private/var/db/timezone
    # itself (the zoneinfo data). Both must be readable, since libsystem_c
    # reads the symlink to learn the zone and then reads the data file.
    # See ADR-0004 (Jail-on-Seatbelt read confinement) F1: SBPL matches
    # kernel-canonical paths, not the user-facing /etc / /var aliases.
    time-zone = emptySlice // {
      sbpl = ''
        (allow file-read* (literal "/private/etc/localtime"))
        (allow file-read* (subpath "/private/var/db/timezone"))
      '';
    };

    # Grants the filesystem reads a network-using process needs on macOS.
    # The Sandbox boundary (ADR-0003: proxy + Seatbelt loopback pin) governs
    # outbound traffic on its own; this combinator does not emit any
    # network-outbound rules. macOS DNS lookup reads /etc/resolv.conf and
    # /etc/hosts (canonical: /private/etc); both are regular files, hence
    # (literal …). TLS trust roots are at /System/Library/Keychains (already
    # in the ADR-0004 prelude); Nix-built tools that bundle their own cacert
    # get /nix/store reads via add-pkg-deps (slice 8).
    network = emptySlice // {
      sbpl = ''
        (allow file-read* (literal "/private/etc/resolv.conf"))
        (allow file-read* (literal "/private/etc/hosts"))
      '';
    };

    # No-op on Seatbelt. On Linux jail-nix this disables bwrap's
    # --new-session flag so TUIs retain a controlling TTY; sandbox-exec
    # never creates a new session, so the inheritance is automatic and
    # there is nothing to emit. Kept as a named slice so cross-platform
    # templates can list it bare under `with jail.combinators;` without
    # conditional wrapping.
    no-new-session = emptySlice;

    # Grants the jailed process read access to `src` under the host
    # filesystem, addressable at `dst`. On Linux jail-nix this is a
    # bubblewrap bind mount; Seatbelt cannot bind-mount (ADR-0001), so
    # when `dst` differs from `src` the wrapper materialises a symlink
    # at `dst` pointing to `src` before sandbox-exec runs. The SBPL
    # rule allows the kernel-canonical form of `src` — the kernel
    # resolves any symlink at `dst` before applying the rule, so the
    # allow lands on the resolved path (spike 10 F1).
    ro-bind = src: dst:
      let rendered = renderSbplPath src;
      in emptySlice // {
        sbpl = ''
          (allow file-read* (subpath "${rendered}"))
          (allow process-exec (subpath "${rendered}"))
        '';
        preflight = bindPreflight src dst;
      };

    # Grants the jailed process read AND write access to `src` under
    # the host filesystem, addressable at `dst`. Mirrors ro-bind in
    # every respect — same canonicalization, same escape, same
    # symlink-preflight when src≠dst, same noescape support — and
    # emits an additional file-write* allow on the same subpath. Per
    # spike 10 F5 write rules are symmetric with read rules.
    rw-bind = src: dst:
      let rendered = renderSbplPath src;
      in emptySlice // {
        sbpl = ''
          (allow file-read* (subpath "${rendered}"))
          (allow file-write* (subpath "${rendered}"))
          (allow process-exec (subpath "${rendered}"))
        '';
        preflight = bindPreflight src dst;
      };

    # Grants read+write on the wrapper's working directory — the project
    # root the jailed agent operates in. cwd is wrapper-runtime data
    # (not known at Nix-eval time), so the SBPL output carries the
    # `__JAIL_CWD__` placeholder token. The darwin wrapper resolves
    # the live cwd via `realpath -s "$PWD"` (this also yields the
    # /private-prefixed canonical form for free, in case the user
    # invoked from under /tmp or /var) and sed-substitutes the token
    # before sandbox-exec loads the profile. Wiring lives in slice 11.
    #
    # The `__JAIL_*` placeholder namespace is reserved for the Jail's
    # runtime-substitution scheme, parallel to `__PROXYPORT__` in
    # mkSandboxProfileTemplate. Future combinators (noescape's
    # ~-expansion, in particular) mint sibling tokens here.
    mount-cwd = emptySlice // {
      sbpl = ''
        (allow file-read* (subpath "__JAIL_CWD__"))
        (allow file-write* (subpath "__JAIL_CWD__"))
        (allow process-exec (subpath "__JAIL_CWD__"))
      '';
    };

    # Tags a path string as carrying runtime expansions that combinators
    # must NOT eagerly resolve. On macOS the only supported expansion in
    # slice 5 is a leading `~`, which the SBPL renderer rewrites to the
    # `__JAIL_HOME__` placeholder (sed-substituted by the wrapper) and
    # the preflight renderer rewrites to literal `$HOME` (bash-expanded
    # inside the wrapper's shell, even within double quotes).
    #
    # Wire format mirrors upstream jail-nix exactly so templates can
    # move across without API changes:
    #
    #   (ro-bind "${pkgs.coreutils}/bin/env" (noescape "~/bin/env"))
    #
    # Other shell-style expansions ($VAR, $(...)) pass through verbatim:
    # OK in preflight, but if they reach SBPL the rule silently no-ops
    # (sandbox-exec does not expand env vars). Future slices may add a
    # named-env placeholder scheme.
    noescape = str: { _noescape = str; };

    # Creates an ephemeral directory at `path`. On Linux jail-nix this
    # is a tmpfs mount visible only inside the jail; Seatbelt cannot
    # mount, so the wrapper materialises the directory pre-exec and
    # tears it down post-exec to preserve the empty-at-start semantic.
    # Subsequent combinators (ro-bind, write-text, try-readwrite,
    # etc.) populate the tmpfs by emitting their own preflight inside
    # the same `path` subtree.
    #
    # SBPL: two allows on the canonical subpath, mirroring rw-bind's
    # split-rule pattern. Preflight: `mkdir -p`. Cleanup: `rm -rf` on
    # the same path — the user opts into this destruction by naming
    # the directory tmpfs; the wrapper (slice 11) runs cleanup
    # snippets in reverse-of-merge order on EXIT/INT/TERM via trap.
    tmpfs = path:
      let
        sbplPath = renderSbplPath path;
        shellPath = renderShellPath path;
      in emptySlice // {
        sbpl = ''
          (allow file-read* (subpath "${sbplPath}"))
          (allow file-write* (subpath "${sbplPath}"))
          (allow process-exec (subpath "${sbplPath}"))
        '';
        preflight = [ ''mkdir -p "${shellPath}"'' ];
        cleanup = [ ''rm -rf "${shellPath}"'' ];
      };

    # Materialises `content` to a content-addressed file in the Nix
    # store via builtins.toFile, then symlinks the caller's `path` to
    # it at preflight time. The jailed process opens `path`; the
    # kernel resolves the symlink and applies SBPL against the store
    # path; the SBPL `(literal …)` allow lets that read through.
    # Spike 10 F4: `literal` matches exactly one file — narrower than
    # `subpath`, which is the right granularity for write-text's
    # single-file contract.
    #
    # The toFile name argument is part of the wire contract — content
    # addressing pairs `(name, content)` to a stable hash, so renaming
    # without coordinating a flake-wide rebuild would invalidate every
    # downstream jail.
    #
    # Cleanup removes the symlink only. The store entry is owned by
    # Nix's GC; the symlink is on the host filesystem and must be
    # torn down to preserve the Linux jail-nix tmpfs ephemerality
    # when write-text is used inside a tmpfs.
    write-text = path: content:
      let
        storePath = builtins.toFile "jail-write-text" content;
        shellPath = renderShellPath path;
      in emptySlice // {
        sbpl = ''
          (allow file-read* (literal "${storePath}"))
          (allow process-exec (literal "${storePath}"))
        '';
        preflight = [
          ''mkdir -p "${dirOf shellPath}" && ln -sfn "${storePath}" "${shellPath}"''
        ];
        cleanup = [ ''rm -f "${shellPath}"'' ];
      };

    # Single-arg form of rw-bind: grants read+write on `path` if it
    # exists on the host. The SBPL allow rule is unconditional — a
    # rule on a non-existent path matches nothing, which is equivalent
    # to bwrap's `--bind-try` no-op semantics. No preflight (we don't
    # want to create the file/dir; only expose it if it already
    # exists), no cleanup (we don't own the path's lifecycle).
    try-readwrite = path:
      let rendered = renderSbplPath path;
      in emptySlice // {
        sbpl = ''
          (allow file-read* (subpath "${rendered}"))
          (allow file-write* (subpath "${rendered}"))
          (allow process-exec (subpath "${rendered}"))
        '';
      };

    # Registers a host env var name for the wrapper to conditionally
    # forward to the jailed process (only if set in the host env).
    # Different from set-env (slice 1) which adds an UNCONDITIONAL
    # value: try-fwd-env says "pass through whatever the host has,
    # if anything". The wrapper (slice 11) iterates envForward at
    # exec time and emits `--setenv` args only for set vars.
    try-fwd-env = name:
      emptySlice // { envForward = [ name ]; };

    # Grants read access to a host path whose canonical target is only
    # knowable at wrapper runtime — the canonical case is an /etc symlink
    # managed by nix-darwin that points into /nix/store. Spike 10 F1
    # dictates that SBPL rules match the kernel-canonical (fully-resolved)
    # path, so a static `(literal "/private/etc/bashrc")` allow misses the
    # store target and bash prints `Operation not permitted` on every
    # interactive launch. host-resolve emits a placeholder allow at
    # Nix-eval time and propagates the original path through `hostResolve`
    # so the darwin wrapper can `readlink -f` it at preflight and sed-
    # substitute the placeholder before sandbox-exec loads the profile.
    #
    # Key derivation is deterministic: uppercase the path, replace every
    # non-alnum char with `_`, strip the leading `_` from the inevitable
    # leading-slash. `/etc/bashrc` → `ETC_BASHRC`, `/etc/foo.conf` →
    # `ETC_FOO_CONF`. Chosen over a hash so the rendered SBPL stays
    # human-reviewable — the placeholder telegraphs which host path it
    # belongs to.
    #
    # On non-nix-darwin macOS the named paths are already regular files
    # covered by the prelude; the wrapper's `readlink -f` returns the
    # path unchanged and the rule is a redundant (but harmless) allow.
    # When the host path doesn't exist at all, the wrapper substitutes
    # `/__jail_host_resolve_no_match_<key>__` (a sentinel that cannot
    # match any real path) — emphatically NOT the empty string, which
    # would render as `(subpath "")` and match the entire filesystem.
    #
    # Linux templates may list this combinator unconditionally: lib/jail
    # emits the slice on every platform, but only the darwin wrapper
    # consumes `hostResolve`. The bare allow on the unsubstituted
    # placeholder string on Linux is a no-op (bwrap doesn't apply SBPL).
    host-resolve = path:
      let
        upper = lib.toUpper path;
        sanitisedRaw = builtins.replaceStrings
          [ "/" "." "-" " " ":" ]
          [ "_" "_" "_" "_" "_" ]
          upper;
        key = lib.removePrefix "_" sanitisedRaw;
        placeholder = "__JAIL_HOST_RESOLVE_${key}__";
      in emptySlice // {
        sbpl = ''
          (allow file-read* (subpath "${placeholder}"))
        '';
        hostResolve = [ { inherit placeholder path; } ];
      };

    # Adds the closure of `pkgList` to the jail's read-allow set and
    # prepends each pkg's bin/ directory to PATH. The closure (vs the
    # top-level pkgs only) is required because dyld must be able to
    # read every store path the agent's binary references at load
    # time — libSystem, OpenSSL, etc. — otherwise the agent SIGABRTs
    # on launch.
    #
    # Closure enumeration happens at Nix-eval time via
    # pkgs.closureInfo (a small derivation built on demand by `nix
    # flake check`) + builtins.readFile. The SBPL string is fully
    # concrete by the time the wrapper runs — no runtime nix-store
    # query needed.
    #
    # This is the narrower-scope option per the slice-8 design
    # discussion: each closure member gets its own allow rule, so
    # paths under /nix/store that aren't part of the agent's closure
    # remain invisible. The trade-off is that nix flake check pays
    # for one closureInfo build per template.
    add-pkg-deps = pkgList:
      let
        closureInfo = pkgs.closureInfo { rootPaths = pkgList; };
        rawPaths = builtins.readFile "${closureInfo}/store-paths";
        closurePaths = lib.filter (s: s != "") (lib.splitString "\n" rawPaths);
        # Issue 15: pair every file-read* allow with a process-exec allow on
        # the same canonical subpath. The closure includes mainBin's libdyld
        # deps + any user-supplied pkgs (e.g. pkgs.curl). Pairing both
        # opcodes per path mirrors Linux bwrap's bind-mount semantics — a
        # bound dir is both readable AND exec'able — instead of leaning on
        # a blanket `(allow process*)` in the prelude.
        sbplLines = lib.concatMapStringsSep "" (path: ''
          (allow file-read* (subpath "${path}"))
          (allow process-exec (subpath "${path}"))
        '') closurePaths;
      in emptySlice // {
        sbpl = sbplLines;
        binPaths = map (pkg: "${pkg}/bin") pkgList;
      };
  };

  # The `jail` constructor: folds a user-supplied combinator list into
  # a single slice, prepends `(deny default)` + the ADR-0004 prelude,
  # and produces a derivation whose `.jailData` attr carries the
  # structured profile + preflight + cleanup + env data for the
  # darwin sandboxed wrapper (issue 11) to splice into its own
  # sandbox-exec invocation.
  #
  # Standalone invocation (running `jail-name` directly, outside
  # `sandboxed`) prints an error and exits non-zero. ADR-0001 line
  # 17-23 forbids nested sandbox-exec, and there is no clean runtime
  # mechanism in slice 9 to detect "already wrapped by sandboxed";
  # the honest answer is to require `sandboxed -- jail-name`.
  #
  # SBPL composition: `(deny default)\n` then prelude then merged
  # combinator SBPL. When spliced via `mkSandboxProfile { jailFragment
  # = …; }` the network-outbound rules from the Sandbox profile are
  # specific operations and survive the deny-default — see
  # `modules/macos-sandbox/profile.nix` and ADR-0003.
  # `name` is the wrapper drv's output name (also the placeholder script's
  # "Usage:" hint). `mainBin` resolves the real binary via lib.getExe, so
  # templates can pass real pkgs (pkgs.bashInteractive, claude-pkg) and let
  # meta.mainProgram (with pname fallback) name the binary inside. Pre-HITL
  # this was `${pkg}/bin/${name}`, which silently produced non-existent
  # paths whenever the wrapper's logical name diverged from the pkg's
  # binary name.
  #
  # The constructor also implicitly grants file-read on pkg's entire
  # closure. mainBin and its runtime deps must be readable, otherwise
  # sandbox-exec fails on launch with "Operation not permitted" — a
  # silent footgun where callers had to remember to feed pkg back
  # through add-pkg-deps. The implicit allows sit BETWEEN the prelude
  # and the caller's combinators, so a caller-supplied combinator can
  # still override (last-match-wins). binPaths is NOT extended; PATH
  # ordering remains the caller's business via explicit add-pkg-deps.
  jail = name: pkg: combinatorList:
    let
      mainBinAllows = (combinators.add-pkg-deps [ pkg ]).sbpl;
      merged = lib.foldl' mergeSlices emptySlice combinatorList;
      sbplFragment = "(deny default)\n" + prelude + mainBinAllows + merged.sbpl;
      placeholderScript = ''
        printf '%s\n' "Error: ${name} must be run via sandboxed for jail enforcement." >&2
        printf '%s\n' "Usage: sandboxed -- ${name} [args]" >&2
        exit 1
      '';
      drv = pkgs.writeShellScriptBin name placeholderScript;
    in
      drv // {
        jailData = {
          sbpl = sbplFragment;
          inherit (merged) preflight cleanup env envForward binPaths hostResolve;
          mainBin = lib.getExe pkg;
        };
      };
in
{
  inherit emptySlice mergeSlices combinators prelude jail;
}
