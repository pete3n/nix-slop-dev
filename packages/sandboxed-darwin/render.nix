# Pure Nix helpers for the macOS sandboxed-darwin wrapper (issue 11).
#
# The wrapper itself is a writeShellScriptBin derivation in default.nix that
# wires up proxy spawn, signal traps, runtime watchers, and the sandbox-exec
# call. The bits that decide *what* the wrapper emits — most importantly the
# combined Sandbox+Jail SBPL profile template — live here so they can be
# unit-tested in isolation (tests/sandboxed-darwin.nix).
#
# `combinedSbplTemplate` returns the same template shape as
# `mkSandboxProfileTemplate` in modules/macos-sandbox/profile.nix — the runtime
# `__PROXYPORT__` sentinel is preserved for the wrapper's sed-substitution
# path (issue 08). When `jail` is non-null and carries `.jailData`, its `.sbpl`
# is spliced into the template via the already-tested `jailFragment` parameter
# (see `tests/sandbox-profile.nix`'s testJailFragmentSplicedExactShape).
{ lib }:
let
  profile = import ../../modules/macos-sandbox/profile.nix { inherit lib; };

  # Derives the bash variable name (and matching sentinel suffix) for a
  # hostResolve entry from its placeholder. Strips the
  # `__JAIL_HOST_RESOLVE_` prefix and trailing `__`, then lowercases —
  # `__JAIL_HOST_RESOLVE_ETC_BASHRC__` → `etc_bashrc`. Used by both the
  # sed-pipeline emission and the resolution block so the variable
  # names line up across the two render sites.
  hostResolveKey = entry:
    let
      mid = lib.removeSuffix "__"
        (lib.removePrefix "__JAIL_HOST_RESOLVE_" entry.placeholder);
    in lib.toLower mid;
in
{
  combinedSbplTemplate = { jail ? null }:
    profile.mkSandboxProfileTemplate {
      jailFragment =
        if jail != null && jail ? jailData
        then jail.jailData.sbpl
        else "";
    };

  # Emits the `-e <expr>` arguments the wrapper passes to sed for runtime
  # placeholder substitution on the SBPL template. Each substitution is one
  # `-e` so the bash interpolations (`''${_proxy_port}`, `''${_jail_cwd}`,
  # `''${HOME}`) survive verbatim through this Nix string into the wrapper
  # body — the wrapper builds `_proxy_port` and `_jail_cwd` before invoking
  # sed.
  #
  # Sed delimiter for the JAIL_* subs is `|` because the substituted values
  # are paths containing `/`. The PROXYPORT sub keeps `/` since the port is
  # numeric.
  #
  # When `jail` is null the wrapper has no jail tokens to substitute, so
  # the pipeline collapses to the proxy port sub alone. (The JAIL_* subs
  # would technically be no-ops on a token-free template, but emitting them
  # would dilute the network-only contract.)
  # Concatenates `jailData.preflight` snippets into a newline-separated
  # bash block the wrapper interpolates. Combinators that materialise host
  # filesystem state before sandbox-exec (ro-bind/rw-bind with src ≠ dst,
  # tmpfs, write-text) emit their `mkdir -p …` / `ln -sfn …` lines into
  # this list; the wrapper runs them under `set -eu` so any failure aborts
  # the launch with the (already-installed) _cleanup trap firing to tear
  # down the proxy + tmpdir.
  #
  # When jail is null (network-only wrapper) or its preflight list is
  # empty the block is the empty string — no trailing newline, no header
  # comment — so the wrapper script stays byte-for-byte identical to the
  # pre-issue-11 shape in that mode.
  mkPreflightBlock = { jail ? null }:
    if jail != null && jail ? jailData && jail.jailData.preflight != [ ]
    then lib.concatMapStrings (line: line + "\n") jail.jailData.preflight
    else "";

  # Concatenates `jailData.cleanup` snippets in REVERSE order (LIFO via
  # trap, per the lib/jail contract — each combinator that materialised a
  # resource in preflight must tear it down before earlier combinators rip
  # out the surrounding state). The canonical case: a `write-text` inside
  # a `tmpfs` — merge order is `[ rm -rf tmpfs, rm -f file ]`; reversed
  # cleanup runs `rm -f file` first so the file's symlink isn't already
  # gone when the outer tmpfs is wiped.
  #
  # The wrapper interpolates this block into its `_cleanup` trap body
  # (after the sandbox-exec child is killed, before the proxy + tmpdir
  # are torn down). Same empty-string contract as mkPreflightBlock.
  mkCleanupBlock = { jail ? null }:
    if jail != null && jail ? jailData && jail.jailData.cleanup != [ ]
    then lib.concatMapStrings (line: line + "\n")
      (lib.reverseList jail.jailData.cleanup)
    else "";

  # Renders the bash block that extends `_env_args` with the jail's env
  # contributions: `jailData.env` becomes unconditional `_env_args+=("K=v")`
  # appends (alphabetical attr-name order so rendered scripts diff cleanly
  # across template edits), and `jailData.envForward` becomes a runtime
  # forward-if-non-empty loop matching the existing `-e` flag's semantics.
  # Env entries are emitted BEFORE the forward loop so a later forwarded
  # variable can shadow an earlier static assignment via `env -i` argv
  # precedence (last assignment wins).
  #
  # Empty in network-only mode and when the jail's env + envForward are
  # both empty (jails of just SBPL combinators like time-zone / ro-bind).
  mkJailEnvBlock = { jail ? null }:
    let
      hasJail = jail != null && jail ? jailData;
      envLines = lib.optionals hasJail
        (lib.mapAttrsToList
          (key: value: ''_env_args+=("${key}=${value}")'')
          jail.jailData.env);
      fwdNames = if hasJail then jail.jailData.envForward else [ ];
      fwdLoop = lib.optionalString (fwdNames != [ ]) ''
        for _jail_fwd_var in ${lib.concatStringsSep " " fwdNames}; do
        	_jail_fwd_val="''${!_jail_fwd_var:-}"
        	if [ -n "$_jail_fwd_val" ]; then
        		_env_args+=("''${_jail_fwd_var}=''${_jail_fwd_val}")
        	fi
        done
      '';
      envBlock = lib.concatMapStrings (line: line + "\n") envLines;
    in envBlock + fwdLoop;

  # Returns the colon-joined+terminated prefix the wrapper splices into
  # the PATH entry of `_env_args`. Each `add-pkg-deps` invocation in the
  # combinator list contributes `${pkg}/bin` paths in order; prepending
  # them (vs appending) means jail-provided binaries shadow whatever the
  # wrapper inherited from $PATH, which is what add-pkg-deps users expect
  # (lib/jail slice 8 documents this contract).
  mkJailPathPrefix = { jail ? null }:
    if jail != null && jail ? jailData && jail.jailData.binPaths != [ ]
    then (lib.concatStringsSep ":" jail.jailData.binPaths) + ":"
    else "";

  # The command portion of the final `sandbox-exec ... env -i ... <cmd>`
  # invocation. In jail mode this is `<mainBin> "$@"` — the wrapper is
  # per-jail at Nix-eval time, so the binary path is baked in and `"$@"`
  # carries only the user's runtime arguments. In network-only mode the
  # user supplies the command as the first positional, so the helper
  # returns the bare `"$@"` (preserving the pre-issue-11 contract).
  mkExecCommand = { jail ? null }:
    if jail != null && jail ? jailData
    then ''"${jail.jailData.mainBin}" "$@"''
    else ''"$@"'';

  # Emits the bash block that resolves each hostResolve entry's path
  # before the SBPL sed pipeline runs. One line per entry of the form:
  #
  #   _jail_hr_<key>="$(<readlinkBin> -f '<path>' 2>/dev/null
  #                     || echo '/__jail_host_resolve_no_match_<key>__')"
  #
  # The bash variable name (`_jail_hr_<key>`) matches the one
  # `mkProfileSedPipeline` references in its `-e "s|<placeholder>|${var}|g"`
  # arg, so the sed substitution reads exactly the value this block
  # computed. `readlinkBin` is injected by default.nix as
  # `${pkgs.coreutils}/bin/readlink` — render.nix stays pkgs-free.
  #
  # The sentinel `/__jail_host_resolve_no_match_<key>__` is what gets
  # substituted into SBPL when the host path doesn't exist. It cannot
  # match any real file because no path on the host has that exact
  # name, so the rule degenerates to a no-op (the user's intent: "allow
  # this if it exists, otherwise nothing"). Emphatically NOT the empty
  # string — `(subpath "")` matches the entire filesystem.
  #
  # `readlink -f` (vs `realpath`) is the issue's explicit choice: the
  # ADR-0004 prelude is already calibrated against the resolved targets
  # of /etc/* symlinks on nix-darwin, and `readlink -f` is what nix-darwin
  # itself documents for that resolution. On stock macOS (no symlink) it
  # returns the path unchanged — the allow becomes redundant with the
  # prelude literal but is harmless.
  mkHostResolveResolutionBlock = { jail ? null, readlinkBin }:
    let
      hasEntries = jail != null
        && jail ? jailData
        && (jail.jailData.hostResolve or [ ]) != [ ];
      mkLine = entry:
        let key = hostResolveKey entry;
        in ''_jail_hr_${key}="$(${readlinkBin} -f '${entry.path}' 2>/dev/null || echo '/__jail_host_resolve_no_match_${key}__')"'';
    in
      if hasEntries
      then lib.concatMapStrings (e: mkLine e + "\n") jail.jailData.hostResolve
      else "";

  mkProfileSedPipeline = { jail ? null }:
    let
      proxyPortSub = ''-e "s/__PROXYPORT__/''${_proxy_port}/g"'';
      hasJail = jail != null && jail ? jailData;
      staticJailSubs = lib.optionals hasJail [
        ''-e "s|__JAIL_CWD__|''${_jail_cwd}|g"''
        ''-e "s|__JAIL_HOME__|''${HOME}|g"''
      ];
      hostResolveSubs = lib.optionals hasJail
        (map (entry:
          let key = hostResolveKey entry;
          in ''-e "s|${entry.placeholder}|''${_jail_hr_${key}}|g"'')
          (jail.jailData.hostResolve or [ ]));
    in lib.concatStringsSep " "
      ([ proxyPortSub ] ++ staticJailSubs ++ hostResolveSubs);
}
