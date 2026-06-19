# Behavior tests for the setup-linux prerequisite check library.
#
# check-lib.sh holds the pure evaluation logic: each check_* takes its
# already-collected host fact as an argument, prints one ✓/✗ report line,
# and returns 0 (pass) or 1 (fail). Host I/O lives in the setup-linux main,
# not here, so these checks are deterministic and exercised with fixtures —
# no real Ubuntu/Fedora host required.
{
  pkgs,
}:
let
  checkLib = ../packages/setup-linux/check-lib.sh;
in
pkgs.runCommand "setup-linux-checks-tests" { } ''
  set -eu
  fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

  source ${checkLib}

  # systemd >= 235 is required for IPAddressDeny-based network filtering.
  report=$(check_systemd_version 249) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "systemd 249 should pass (rc=$status)"
  case "$report" in "✓"*) ;; *) fail "systemd 249: expected ✓ line, got: $report" ;; esac

  report=$(check_systemd_version 234) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "systemd 234 should fail (rc=$status)"
  case "$report" in "✗"*) ;; *) fail "systemd 234: expected ✗ line, got: $report" ;; esac

  # cgroup v2: the unified hierarchy exposes cgroup.controllers at its root.
  touch present-controllers
  report=$(check_cgroup_v2 "$PWD/present-controllers") && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "cgroup v2 present should pass (rc=$status)"
  case "$report" in "✓"*) ;; *) fail "cgroup v2 present: expected ✓, got: $report" ;; esac

  report=$(check_cgroup_v2 "$PWD/absent-controllers") && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "cgroup v2 absent should fail (rc=$status)"
  case "$report" in "✗"*) ;; *) fail "cgroup v2 absent: expected ✗, got: $report" ;; esac

  # auditd must be installed and running for violation logging; the fact is
  # the `systemctl is-active auditd` string.
  report=$(check_auditd active) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "auditd active should pass (rc=$status)"
  case "$report" in "✓"*) ;; *) fail "auditd active: expected ✓, got: $report" ;; esac

  report=$(check_auditd inactive) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "auditd inactive should fail (rc=$status)"
  case "$report" in "✗"*) ;; *) fail "auditd inactive: expected ✗, got: $report" ;; esac

  # The sudoers drop-in that grants passwordless access to the host's
  # privileged tools; presence is the fact (apply mode writes it).
  touch present-sudoers
  report=$(check_sudoers "$PWD/present-sudoers") && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "sudoers present should pass (rc=$status)"
  case "$report" in "✓"*) ;; *) fail "sudoers present: expected ✓, got: $report" ;; esac

  report=$(check_sudoers "$PWD/absent-sudoers") && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "sudoers absent should fail (rc=$status)"
  case "$report" in "✗"*) ;; *) fail "sudoers absent: expected ✗, got: $report" ;; esac

  # Ubuntu 24.04+ restricts unprivileged user namespaces (which bubblewrap
  # needs for the Jail) via a sysctl. Two facts: the sysctl value (or "" when
  # the knob is absent), and whether our nix-slop-dev-bwrap AppArmor profile
  # is loaded. The check passes when either the sysctl is not 1 (permitted
  # system-wide) or the profile is loaded (bwrap exempted via AppArmor).
  report=$(check_userns_restriction "" 0) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "userns absent sysctl should pass (rc=$status)"
  case "$report" in "✓"*) ;; *) fail "userns absent: expected ✓, got: $report" ;; esac

  report=$(check_userns_restriction 0 0) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "userns 0 should pass (rc=$status)"
  case "$report" in "✓"*) ;; *) fail "userns 0: expected ✓, got: $report" ;; esac

  report=$(check_userns_restriction 1 0) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "userns 1 + no profile should fail (rc=$status)"
  case "$report" in "✗"*) ;; *) fail "userns 1 + no profile: expected ✗, got: $report" ;; esac

  # The post-apply state: sysctl still 1 (apply mode never flips it), but the
  # nix-slop-dev-bwrap profile is loaded — bwrap is exempted, so the check
  # should pass. This is the regression the second-arg added.
  report=$(check_userns_restriction 1 1) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "userns 1 + profile loaded should pass (rc=$status)"
  case "$report" in "✓"*) ;; *) fail "userns 1 + profile: expected ✓, got: $report" ;; esac

  # Fedora's `-a task,never` audit rule suppresses per-task audit context and
  # kills all syscall auditing. The check fails when it's active in the
  # running kernel (apply mode removes it) and passes otherwise.
  report=$(check_task_never 0) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "task_never inactive should pass (rc=$status)"
  case "$report" in "✓"*) ;; *) fail "task_never 0: expected ✓, got: $report" ;; esac

  report=$(check_task_never 1) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "task_never active should fail (rc=$status)"
  case "$report" in "✗"*) ;; *) fail "task_never 1: expected ✗, got: $report" ;; esac

  # Aggregation: run_checks reports every prerequisite and exits zero only when
  # all pass. Args: systemd_version controllers_file auditd_state sudoers_file
  # userns_sysctl apparmor_profile_loaded task_never_active.
  touch agg-controllers agg-sudoers
  run_checks 249 "$PWD/agg-controllers" active "$PWD/agg-sudoers" 0 0 0 > allpass.txt \
    && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "all prerequisites met should exit 0 (rc=$status)"
  [ "$(grep -c '✓' allpass.txt)" -eq 6 ] || fail "all-pass: expected 6 ✓ lines, got:
$(cat allpass.txt)"
  case "$(cat allpass.txt)" in *✗*) fail "all-pass output must contain no ✗" ;; esac

  run_checks 230 "$PWD/agg-controllers" active "$PWD/agg-sudoers" 0 0 0 > onefail.txt \
    && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "a failing prerequisite should exit nonzero"

  # task,never active alone (everything else green) should also fail the
  # aggregate, since it silently disables sandbox observability.
  run_checks 249 "$PWD/agg-controllers" active "$PWD/agg-sudoers" 0 0 1 > tnactive.txt \
    && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "task_never active alone should fail the aggregate"
  case "$(cat tnactive.txt)" in *task,never*) ;; *) fail "task_never failure should mention the rule name" ;; esac

  touch "$out"
''
