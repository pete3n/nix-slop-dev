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

  # SELinux file-context check (HITL 2026-06-19, Fedora 44).
  # `sudo systemd-run --property=User=$USER` causes systemd-executor (running
  # in init_t) to execve binaries the wrapper passes as ExecStart — i.e.
  # setpriv at /nix/store/.../bin/setpriv. Fedora's targeted policy labels
  # everything under /nix/store as default_t (no policy entry); init_t →
  # default_t : file execute is denied, so the unit exits with EXIT_EXEC=203
  # before the jailed binary ever runs. setup-linux's --apply mode now adds
  # a `semanage fcontext -a -e /usr /nix` equivalence rule and restorecons,
  # giving /nix/store entries bin_t (or whatever /usr/.../bin/* resolves to)
  # which init_t can exec. Two facts: selinux_state from getenforce and
  # nix_store_label from `stat -c %C` on a known store binary.
  report=$(check_selinux_nix_label "" "") && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "selinux absent should pass (rc=$status)"
  case "$report" in "✓"*) ;; *) fail "selinux absent: expected ✓, got: $report" ;; esac

  report=$(check_selinux_nix_label Disabled "") && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "selinux Disabled should pass (rc=$status)"
  case "$report" in "✓"*) ;; *) fail "selinux Disabled: expected ✓, got: $report" ;; esac

  # Permissive logs denies but doesn't enforce — the wrapper works in this
  # state today. Pass with a note so the user understands the state. If
  # they toggle to Enforcing later, the label still needs to be right; we
  # surface that via the note rather than failing the prereq.
  report=$(check_selinux_nix_label Permissive default_t) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "selinux Permissive + default_t should pass with warning (rc=$status)"
  case "$report" in "✓"*) ;; *) fail "selinux Permissive: expected ✓, got: $report" ;; esac

  # Enforcing + non-default_t: the equivalence rule has been applied, init_t
  # can exec /nix/store entries — green.
  report=$(check_selinux_nix_label Enforcing bin_t) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "selinux Enforcing + bin_t should pass (rc=$status)"
  case "$report" in "✓"*) ;; *) fail "selinux Enforcing + bin_t: expected ✓, got: $report" ;; esac

  # Enforcing + default_t: the bug we're fixing. The check must fail with
  # remediation pointing at setup-linux --apply, and the message must name
  # the actual label so the user can correlate it with `ls -laZ` output.
  report=$(check_selinux_nix_label Enforcing default_t) && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "selinux Enforcing + default_t should fail (rc=$status)"
  case "$report" in "✗"*) ;; *) fail "selinux Enforcing + default_t: expected ✗, got: $report" ;; esac
  case "$report" in *default_t*) ;; *) fail "selinux deny message should name the label; got: $report" ;; esac
  case "$report" in *apply*) ;; *) fail "selinux deny message should point at --apply; got: $report" ;; esac

  # Enforcing + empty label (couldn't probe — no nix binary on PATH).
  # Should fail because we cannot confirm the label is good; the remediation
  # is to either install nix-on-PATH or run apply.
  report=$(check_selinux_nix_label Enforcing "") && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "selinux Enforcing + empty label should fail (rc=$status)"
  case "$report" in "✗"*) ;; *) fail "selinux unknown: expected ✗, got: $report" ;; esac

  # Enforcing + literal `?` label is the "stat couldn't read the context"
  # case. _collect_selinux_facts normalises `?` to "" before passing in,
  # so the check itself sees "" — pin the same fail-on-Enforcing-without-
  # confirmed-good-label behaviour for the bare `?` input as a belt-and-
  # braces guard against the collector dropping the normalisation. Fedora
  # 44 HITL 2026-06-19: nixpkgs coreutils stat returned `?` (no SELinux
  # support compiled), the collector formerly passed `?` through, and
  # this check formerly green-lit it as "labeled ?" — apply mode then
  # skipped the SELinux step.
  report=$(check_selinux_nix_label Enforcing "?") && status=0 || status=$?
  [ "$status" -eq 1 ] || fail "selinux Enforcing + literal '?' should fail (rc=$status)"
  case "$report" in "✗"*) ;; *) fail "selinux Enforcing + '?': expected ✗, got: $report" ;; esac

  # Aggregation: run_checks reports every prerequisite and exits zero only when
  # all pass. Args: systemd_version controllers_file auditd_state sudoers_file
  # userns_sysctl apparmor_profile_loaded task_never_active selinux_state
  # nix_store_label.
  touch agg-controllers agg-sudoers
  run_checks 249 "$PWD/agg-controllers" active "$PWD/agg-sudoers" 0 0 0 "" "" > allpass.txt \
    && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "all prerequisites met (no SELinux) should exit 0 (rc=$status)"
  [ "$(grep -c '✓' allpass.txt)" -eq 7 ] || fail "all-pass: expected 7 ✓ lines, got:
$(cat allpass.txt)"
  case "$(cat allpass.txt)" in *✗*) fail "all-pass output must contain no ✗" ;; esac

  # Same args but with SELinux Enforcing + bin_t (post-apply Fedora state).
  run_checks 249 "$PWD/agg-controllers" active "$PWD/agg-sudoers" 0 0 0 Enforcing bin_t > fed_ok.txt \
    && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "all green + Enforcing/bin_t should exit 0 (rc=$status)"
  case "$(cat fed_ok.txt)" in *✗*) fail "Enforcing/bin_t output must contain no ✗; got:
$(cat fed_ok.txt)" ;; esac

  run_checks 230 "$PWD/agg-controllers" active "$PWD/agg-sudoers" 0 0 0 "" "" > onefail.txt \
    && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "a failing prerequisite should exit nonzero"

  # task,never active alone (everything else green) should also fail the
  # aggregate, since it silently disables sandbox observability.
  run_checks 249 "$PWD/agg-controllers" active "$PWD/agg-sudoers" 0 0 1 "" "" > tnactive.txt \
    && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "task_never active alone should fail the aggregate"
  case "$(cat tnactive.txt)" in *task,never*) ;; *) fail "task_never failure should mention the rule name" ;; esac

  # SELinux Enforcing + default_t alone (everything else green) must fail the
  # aggregate — this is the Fedora 203 regression baseline.
  run_checks 249 "$PWD/agg-controllers" active "$PWD/agg-sudoers" 0 0 0 Enforcing default_t > sefail.txt \
    && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "Enforcing + default_t alone should fail the aggregate"
  case "$(cat sefail.txt)" in *default_t*) ;; *) fail "selinux failure should name the label" ;; esac

  touch "$out"
''
