# Non-NixOS Linux setup

The `sandboxed` wrapper and the jailed templates run on any systemd-based Linux
distribution (Ubuntu, Debian, Fedora, …), not just NixOS. On NixOS the
`security.sandboxed` module configures the host; elsewhere the `setup-linux`
app does the equivalent, or you can perform the same steps by hand.

The quickest path:

```sh
nix run github:pete3n/nix-slop-dev#setup-linux            # diagnose (mutates nothing)
nix run github:pete3n/nix-slop-dev#setup-linux -- --apply  # configure (asks before changing anything)
```

The rest of this page documents, step by step, exactly what `--apply` does, for
people who would rather not run a root-touching script. Following these steps
by hand produces the same end state as apply mode.

## 1. Prerequisites

`setup-linux --check` reports each of these with a ✓/✗ and a fix hint; it never
modifies anything. The prerequisites are:

- **systemd ≥ 235** — first release with `IPAddressDeny`/`IPAddressAllow`, on
  which the Sandbox network filtering depends. Check with `systemctl --version`.
- **cgroup v2 unified hierarchy** — required for per-unit IP filtering. Present
  when `/sys/fs/cgroup/cgroup.controllers` exists. If missing, boot with
  `systemd.unified_cgroup_hierarchy=1`.
- **auditd** — installed and active (step 2).
- **sudoers drop-in** — `/etc/sudoers.d/sandboxed` (step 3).
- **unprivileged user namespaces** — permitted, or an AppArmor profile grants
  them to bubblewrap (step 4). Only relevant on Ubuntu 23.10+/24.04.

## 2. Install and enable auditd

auditd records the `connect()` syscall violations the Sandbox alerts on.

```sh
# Debian / Ubuntu
sudo apt-get install -y auditd

# Fedora
sudo dnf install -y audit

# Both
sudo systemctl enable --now auditd
```

## 3. Write the sudoers drop-in

The wrapper invokes five privileged tools through `sudo`. On non-NixOS it calls
them by bare name and relies on sudo's `secure_path` to resolve the host
binaries, so the sudoers rule lists their **absolute paths**. Find them:

```sh
command -v systemd-run systemctl tail
command -v auditctl ausearch || ls /usr/sbin/auditctl /usr/sbin/ausearch /sbin/auditctl /sbin/ausearch 2>/dev/null
```

Create `/etc/sudoers.d/sandboxed` granting your user passwordless sudo for
exactly those paths (substitute the paths you found and your username):

```
# Managed by nix-slop-dev setup-linux — do not edit by hand.
# Grants <user> passwordless sudo for the sandboxed wrapper's
# privileged tools (systemd-run, systemctl, tail, auditctl, ausearch).
<user> ALL=(root) NOPASSWD: /usr/bin/systemd-run, /usr/bin/systemctl, /usr/bin/tail, /usr/sbin/auditctl, /usr/sbin/ausearch
```

Validate it **before** installing, then install it with the required `0440`
permissions:

```sh
sudo visudo -cf /path/to/your/draft        # must report "parsed OK"
sudo install -m 0440 -o root -g root /path/to/your/draft /etc/sudoers.d/sandboxed
```

## 4. AppArmor unprivileged user namespaces (Ubuntu 23.10+/24.04)

These releases block unprivileged user namespaces — which bubblewrap (the Jail)
needs — when `kernel.apparmor_restrict_unprivileged_userns=1`. Check it:

```sh
cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null
```

If it prints `1`, install an AppArmor profile that grants `userns` to
bubblewrap. The profile attaches to the bwrap **store-path glob**, not a fixed
path, so it stays valid when a flake update changes bwrap's `/nix/store` hash.

Write `/etc/apparmor.d/nix-slop-dev-bwrap`:

```
abi <abi/4.0>,
include <tunables/global>

profile nix-slop-dev-bwrap "/nix/store/*/bin/bwrap" flags=(unconfined) {
  userns,

  include if exists <local/nix-slop-dev-bwrap>
}
```

Then validate and load it:

```sh
sudo apparmor_parser -Q /etc/apparmor.d/nix-slop-dev-bwrap   # parse check
sudo apparmor_parser -r /etc/apparmor.d/nix-slop-dev-bwrap   # load
```

### Why not just flip the sysctl?

`sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` would also let
bubblewrap create the namespace — by lifting the restriction **for every
process on the host**, not just bwrap. Ubuntu added this restriction by
default because unprivileged user namespaces have historically been a kernel
CVE vector (bugs in fs / netfilter / etc. become reachable when a process
gets "root in a namespace"); flipping it system-wide restores the broader
attack surface. The AppArmor profile narrows the grant to bwrap's
`/nix/store/*/bin/bwrap` store-path glob — same end result for the Jail,
much smaller security regression. The runtime `sysctl -w` also reverts on
reboot, so persisting it would require an `/etc/sysctl.d/` drop-in — at
which point you have a persistent system-wide regression for marginal
convenience. The AppArmor profile is the recommended path.

## 5. Verify

```sh
nix run github:pete3n/nix-slop-dev#setup-linux   # all ✓, exits 0
```
