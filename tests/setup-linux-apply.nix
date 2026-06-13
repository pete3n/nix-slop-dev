# Behavior tests for the setup-linux apply-mode logic.
#
# apply-lib.sh holds the pure, deterministic pieces of apply mode: generating
# the sudoers drop-in content, detecting host tool paths against a controlled
# PATH, mapping a distro to its auditd install command, and computing the
# idempotent change plan. Host mutation (writing /etc, running the package
# manager, the confirmation prompt) lives in the setup-linux main and is
# verified HITL on real distros.
{
  pkgs,
}:
let
  applyLib = ../packages/setup-linux/apply-lib.sh;
in
pkgs.runCommand "setup-linux-apply-tests" { } ''
  set -eu
  fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

  source ${applyLib}

  # sudoers_content grants the given user passwordless sudo for exactly the
  # five privileged tools, by the detected absolute paths (ADR-0002: the
  # wrapper invokes bare names; sudo's secure_path resolves them and matches
  # these absolute Cmnd specs).
  content=$(sudoers_content alice \
    /usr/bin/systemd-run /usr/bin/systemctl /usr/bin/tail \
    /usr/sbin/auditctl /usr/sbin/ausearch)

  case "$content" in
    *"alice ALL="*"NOPASSWD:"*) ;;
    *) fail "sudoers_content: missing 'alice ... NOPASSWD' grant; got:
$content" ;;
  esac

  for tool_path in /usr/bin/systemd-run /usr/bin/systemctl /usr/bin/tail \
                   /usr/sbin/auditctl /usr/sbin/ausearch; do
    case "$content" in
      *"$tool_path"*) ;;
      *) fail "sudoers_content: missing path '$tool_path'; got:
$content" ;;
    esac
  done

  # detect_tool_path resolves a tool found on PATH...
  mkdir -p bindir sbindir
  printf '#!/bin/sh\n' > bindir/faketool;  chmod +x bindir/faketool
  printf '#!/bin/sh\n' > sbindir/fakesbin; chmod +x sbindir/fakesbin

  resolved=$( PATH="$PWD/bindir:$PATH" detect_tool_path faketool ) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "detect_tool_path faketool should succeed (rc=$status)"
  [ "$resolved" = "$PWD/bindir/faketool" ] \
    || fail "detect_tool_path faketool: expected $PWD/bindir/faketool, got $resolved"

  # ...falls back to a system sbin dir when not on PATH...
  resolved=$(detect_tool_path fakesbin "$PWD/sbindir") && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "detect_tool_path fallback should succeed (rc=$status)"
  [ "$resolved" = "$PWD/sbindir/fakesbin" ] \
    || fail "detect_tool_path fallback: expected $PWD/sbindir/fakesbin, got $resolved"

  # ...and fails when the tool is absent everywhere.
  resolved=$(detect_tool_path no-such-tool-xyz "$PWD/sbindir") && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "detect_tool_path missing tool should fail (rc=$status)"

  # auditd_install_cmd maps a distro ID to its package manager and the
  # distro-specific audit package name (Debian/Ubuntu: auditd; Fedora: audit).
  for deblike in ubuntu debian; do
    cmd=$(auditd_install_cmd "$deblike") && status=0 || status=$?
    [ "$status" -eq 0 ] || fail "auditd_install_cmd $deblike should succeed (rc=$status)"
    case "$cmd" in *apt*auditd*) ;; *) fail "auditd_install_cmd $deblike: expected apt+auditd, got: $cmd" ;; esac
  done

  cmd=$(auditd_install_cmd fedora) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "auditd_install_cmd fedora should succeed (rc=$status)"
  case "$cmd" in *dnf*audit*) ;; *) fail "auditd_install_cmd fedora: expected dnf+audit, got: $cmd" ;; esac

  cmd=$(auditd_install_cmd arch) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "auditd_install_cmd of unknown distro should fail (rc=$status)"

  # plan_actions lists one action per unmet prerequisite, given booleans
  # (1 = already satisfied, 0 = needs action) for the sudoers drop-in and
  # auditd. An already-configured host yields an empty plan (the no-op case).
  plan=$(plan_actions 1 1)
  [ -z "$plan" ] || fail "fully-configured host should yield an empty plan; got:
$plan"

  plan=$(plan_actions 0 1)
  case "$plan" in *sudoers*) ;; *) fail "missing-sudoers plan should mention sudoers; got: $plan" ;; esac
  case "$plan" in *auditd*) fail "sudoers-only plan should not mention auditd; got: $plan" ;; *) ;; esac

  plan=$(plan_actions 1 0)
  case "$plan" in *auditd*) ;; *) fail "inactive-auditd plan should mention auditd; got: $plan" ;; esac
  case "$plan" in *sudoers*) fail "auditd-only plan should not mention sudoers; got: $plan" ;; *) ;; esac

  plan=$(plan_actions 0 0)
  [ "$(printf '%s\n' "$plan" | grep -c .)" -eq 2 ] \
    || fail "fully-unconfigured host should plan two actions; got:
$plan"

  touch "$out"
''
