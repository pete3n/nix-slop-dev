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

  touch "$out"
''
