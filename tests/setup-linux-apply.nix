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

  # detect_tool_paths returns EVERY candidate path where the tool exists,
  # one per line, deduplicated. This is what the sudoers writer needs
  # because on merged-usr distros (Fedora) sudo's secure_path may resolve
  # a tool to a path that differs from `command -v` even when both
  # ultimately point at the same inode — and sudoers Cmnd matching is
  # string-based.
  mkdir -p multi-usr-bin multi-usr-sbin multi-bin multi-sbin
  for d in multi-usr-bin multi-usr-sbin multi-bin multi-sbin; do
    printf '#!/bin/sh\n' > "$d/multitool";  chmod +x "$d/multitool"
  done

  # All four candidate dirs have the tool; expect four distinct lines.
  paths=$( PATH="$PWD/multi-usr-bin:$PATH" detect_tool_paths multitool \
    "$PWD/multi-usr-sbin" "$PWD/multi-bin" "$PWD/multi-sbin" )
  count=$(printf '%s\n' "$paths" | grep -c .)
  [ "$count" -eq 4 ] \
    || fail "detect_tool_paths should list all four locations, got $count:
$paths"
  case "$paths" in
    *multi-usr-bin/multitool*) ;;
    *) fail "detect_tool_paths missing the PATH-resolved entry; got:
$paths" ;;
  esac
  case "$paths" in
    *multi-sbin/multitool*) ;;
    *) fail "detect_tool_paths missing a fallback-dir entry; got:
$paths" ;;
  esac

  # When the same path would be emitted twice (e.g. PATH and fallback both
  # resolve to the same string), deduplicate so the sudoers list doesn't
  # carry duplicates.
  paths=$( PATH="$PWD/multi-usr-bin:$PATH" detect_tool_paths multitool \
    "$PWD/multi-usr-bin" "$PWD/multi-usr-sbin" )
  count=$(printf '%s\n' "$paths" | grep -c .)
  [ "$count" -eq 2 ] \
    || fail "detect_tool_paths should dedupe; expected 2 lines, got $count:
$paths"

  # No matches anywhere → returns 1, prints nothing.
  paths=$(detect_tool_paths no-such-tool-xyz "$PWD/nowhere") && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "detect_tool_paths missing tool should fail (rc=$status)"
  [ -z "$paths" ] || fail "detect_tool_paths missing tool should print nothing; got:
$paths"

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

  # apparmor_profile_content renders a profile that attaches to the bubblewrap
  # store-path glob (the glob is what survives flake updates) and grants the
  # userns permission so the Jail works under the Ubuntu 24.04 restriction.
  profile=$(apparmor_profile_content nix-slop-dev-bwrap '/nix/store/*/bin/bwrap')
  case "$profile" in
    *'/nix/store/*/bin/bwrap'*) ;;
    *) fail "apparmor profile missing the bwrap store-path glob; got:
$profile" ;;
  esac
  case "$profile" in *userns*) ;; *) fail "apparmor profile missing 'userns' rule; got:
$profile" ;; esac
  case "$profile" in *nix-slop-dev-bwrap*) ;; *) fail "apparmor profile missing profile name; got:
$profile" ;; esac

  # plan_actions takes an optional third userns-satisfied boolean (default 1).
  # When the restriction is active (0), it adds the AppArmor profile action.
  plan=$(plan_actions 1 1 0)
  case "$plan" in *namespace*) ;; *) fail "restricted-userns plan should mention user namespaces; got: $plan" ;; esac

  plan=$(plan_actions 1 1 1)
  [ -z "$plan" ] || fail "unrestricted userns with everything else configured should be a no-op; got:
$plan"

  # Omitting the third argument preserves the prior two-argument behavior.
  plan=$(plan_actions 1 1)
  [ -z "$plan" ] || fail "two-arg plan_actions should treat userns as satisfied; got:
$plan"

  plan=$(plan_actions 0 0 0)
  [ "$(printf '%s\n' "$plan" | grep -c .)" -eq 3 ] \
    || fail "fully-unconfigured + restricted userns should plan three actions; got:
$plan"

  # plan_actions takes an optional fourth task_never-satisfied boolean
  # (default 1). When task,never is active (0), it adds a removal action.
  # Fedora's audit-rules package ships this rule and it suppresses sandbox
  # observability; apply mode comments it out.
  plan=$(plan_actions 1 1 1 0)
  case "$plan" in *task,never*) ;; *) fail "task,never plan should mention the rule; got: $plan" ;; esac

  plan=$(plan_actions 1 1 1 1)
  [ -z "$plan" ] || fail "all four satisfied should be a no-op; got:
$plan"

  plan=$(plan_actions 0 0 0 0)
  [ "$(printf '%s\n' "$plan" | grep -c .)" -eq 4 ] \
    || fail "fully-unconfigured + task,never should plan four actions; got:
$plan"

  # plan_remove_actions is the symmetric uninstall planner. Args (1 = present
  # and to be removed; 0 = already absent, skip): apparmor_profile_present,
  # apparmor_profile_loaded, sudoers_present, optional task_never_was_disabled.
  # The profile-present and profile-loaded facts collapse to one action line —
  # unload+delete is one logical step.
  plan=$(plan_remove_actions 0 0 0)
  [ -z "$plan" ] || fail "fully-clean host should yield an empty remove plan; got:
$plan"

  plan=$(plan_remove_actions 1 0 0)
  case "$plan" in *AppArmor*) ;; *) fail "file-present-only should plan AppArmor removal; got: $plan" ;; esac
  [ "$(printf '%s\n' "$plan" | grep -c .)" -eq 1 ] \
    || fail "file-present-only should plan exactly one action; got:
$plan"

  plan=$(plan_remove_actions 0 1 0)
  case "$plan" in *AppArmor*) ;; *) fail "loaded-only should plan AppArmor removal; got: $plan" ;; esac
  [ "$(printf '%s\n' "$plan" | grep -c .)" -eq 1 ] \
    || fail "loaded-only should plan exactly one action; got:
$plan"

  plan=$(plan_remove_actions 1 1 0)
  case "$plan" in *AppArmor*) ;; *) fail "file+loaded should plan AppArmor removal; got: $plan" ;; esac
  case "$plan" in *sudoers*) fail "file+loaded only should NOT plan sudoers removal; got: $plan" ;; *) ;; esac

  plan=$(plan_remove_actions 0 0 1)
  case "$plan" in *sudoers*) ;; *) fail "sudoers-only should plan sudoers removal; got: $plan" ;; esac
  case "$plan" in *AppArmor*) fail "sudoers-only should NOT plan AppArmor removal; got: $plan" ;; *) ;; esac

  plan=$(plan_remove_actions 1 1 1)
  [ "$(printf '%s\n' "$plan" | grep -c .)" -eq 2 ] \
    || fail "fully-installed host should plan two remove actions; got:
$plan"
  case "$plan" in *auditd*) fail "remove plan must never mention auditd (separate concern); got: $plan" ;; *) ;; esac

  # Optional fourth arg: task_never_was_disabled. When set, --remove plans
  # to restore the Fedora-default task,never rule that apply mode commented
  # out. Independent of the AppArmor / sudoers presence facts.
  plan=$(plan_remove_actions 0 0 0 1)
  case "$plan" in *task,never*) ;; *) fail "task_never_was_disabled=1 should plan restoration; got: $plan" ;; esac
  [ "$(printf '%s\n' "$plan" | grep -c .)" -eq 1 ] \
    || fail "task_never-only restore should plan exactly one action; got:
$plan"

  plan=$(plan_remove_actions 1 1 1 1)
  [ "$(printf '%s\n' "$plan" | grep -c .)" -eq 3 ] \
    || fail "fully-installed + task_never_was_disabled should plan three remove actions; got:
$plan"

  # plan_actions takes an optional fifth selinux-fcontext-satisfied boolean
  # (default 1). When 0 — i.e. SELinux Enforcing AND /nix/store labeled
  # default_t (Fedora 44 baseline) — apply mode plans the
  # `semanage fcontext -a -e /usr /nix` equivalence + restorecon -R /nix
  # step. Without that, init_t (the systemd-executor domain for transient
  # units with --property=User=…) cannot execve any store binary the
  # wrapper passes as ExecStart, and the unit exits with 203/EXEC before
  # the jailed binary runs.
  plan=$(plan_actions 1 1 1 1 0)
  case "$plan" in *SELinux*|*selinux*|*fcontext*|*"/nix"*) ;; *) fail "SELinux=unmet plan should mention selinux/fcontext/nix; got: $plan" ;; esac
  [ "$(printf '%s\n' "$plan" | grep -c .)" -eq 1 ] \
    || fail "SELinux-only plan should produce one action; got:
$plan"

  plan=$(plan_actions 1 1 1 1 1)
  [ -z "$plan" ] || fail "all five satisfied should be a no-op; got:
$plan"

  # Omitting the fifth arg preserves prior four-arg behavior.
  plan=$(plan_actions 1 1 1 1)
  [ -z "$plan" ] || fail "four-arg plan_actions should treat selinux as satisfied; got:
$plan"

  plan=$(plan_actions 0 0 0 0 0)
  [ "$(printf '%s\n' "$plan" | grep -c .)" -eq 5 ] \
    || fail "fully-unconfigured + selinux should plan five actions; got:
$plan"

  # plan_remove_actions takes an optional fifth selinux_fcontext_present
  # boolean. When set, --remove plans `semanage fcontext -d -e /nix` (drop
  # the equivalence rule) + restorecon. Independent of the other facts.
  plan=$(plan_remove_actions 0 0 0 0 1)
  case "$plan" in *SELinux*|*selinux*|*fcontext*|*"/nix"*) ;; *) fail "selinux_present=1 should plan fcontext removal; got: $plan" ;; esac
  [ "$(printf '%s\n' "$plan" | grep -c .)" -eq 1 ] \
    || fail "selinux-only remove should plan exactly one action; got:
$plan"

  plan=$(plan_remove_actions 1 1 1 1 1)
  [ "$(printf '%s\n' "$plan" | grep -c .)" -eq 4 ] \
    || fail "fully-installed + task_never + selinux should plan four remove actions; got:
$plan"

  # selinux_apply_cmd / selinux_remove_cmd render the exact host commands.
  # Pin them so a refactor that drops `-e /usr /nix` (the equivalence path
  # — without it semanage would expect a target type instead) fails loudly.
  cmd=$(selinux_apply_cmd) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "selinux_apply_cmd should succeed (rc=$status)"
  case "$cmd" in *"semanage fcontext -a -e /usr /nix"*) ;; *) fail "apply cmd missing -e /usr /nix; got:
$cmd" ;; esac
  case "$cmd" in *"restorecon -R /nix"*) ;; *) fail "apply cmd missing restorecon -R /nix; got:
$cmd" ;; esac

  cmd=$(selinux_remove_cmd) && status=0 || status=$?
  [ "$status" -eq 0 ] || fail "selinux_remove_cmd should succeed (rc=$status)"
  case "$cmd" in *"semanage fcontext -d -e /nix"*) ;; *) fail "remove cmd missing -d -e /nix; got:
$cmd" ;; esac
  case "$cmd" in *"restorecon -R /nix"*) ;; *) fail "remove cmd missing restorecon -R /nix; got:
$cmd" ;; esac

  touch "$out"
''
