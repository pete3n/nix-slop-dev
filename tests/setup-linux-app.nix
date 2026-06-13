# Integration smoke test for the runnable setup-linux app.
#
# The pure check logic is unit-tested in setup-linux-checks.nix; this test
# guards the thin collection-layer main that wires host facts into it. We can't
# assert pass/fail (host facts are nondeterministic in the build sandbox), but
# we can assert the app runs to completion, reports every prerequisite, and
# exits with a clean check-mode status (0 or 1) rather than crashing.
{
  pkgs,
  setupLinux,
}:
pkgs.runCommand "setup-linux-app-tests" { } ''
  set -eu
  fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

  report="$(${setupLinux}/bin/setup-linux 2>&1)" && status=0 || status=$?

  [ "$status" -eq 0 ] || [ "$status" -eq 1 ] \
    || fail "check mode must exit 0 or 1, got $status; output:
$report"

  for label in "systemd" "cgroup v2" "auditd" "sudoers" "user namespaces"; do
    case "$report" in
      *"$label"*) ;;
      *) fail "report missing '$label' line; output:
$report" ;;
    esac
  done

  # --help describes both modes and exits 0.
  help_out="$(${setupLinux}/bin/setup-linux --help 2>&1)" && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "--help should exit 0, got $status"
  case "$help_out" in *--apply*) ;; *) fail "--help should mention --apply; got:
$help_out" ;; esac

  # An unknown argument is rejected.
  ${setupLinux}/bin/setup-linux --bogus >/dev/null 2>&1 && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "unknown argument should exit nonzero"

  # apply mode is fail-safe: declining the confirmation makes no changes and
  # exits 0. (The build sandbox is unconfigured, so the plan is non-empty and
  # the prompt is reached; feeding 'n' must abort cleanly.)
  apply_out="$(printf 'n\n' | ${setupLinux}/bin/setup-linux --apply 2>&1)" \
    && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "declining --apply should exit 0, got $status; output:
$apply_out"
  case "$apply_out" in
    *[Aa]borted*) ;;
    *) fail "declining --apply should report it aborted; got:
$apply_out" ;;
  esac
  [ ! -e /etc/sudoers.d/sandboxed ] || fail "declining --apply must not create the sudoers drop-in"

  touch "$out"
''
