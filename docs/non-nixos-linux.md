# Non-NixOS Linux setup

The `sandboxed` wrapper and the jailed templates run on any systemd-based Linux
distribution (Ubuntu, Debian, Fedora). The `setup-linux` app configures the host 
system, or you can perform the same steps by hand.

## Install Nix and enable flakes

The wrapper and templates require Nix with flakes enabled. Install Nix
using either the [official Nix installer](https://nix.dev/install-nix)
or the [Determinate Systems installer](https://github.com/DeterminateSystems/nix-installer).

**Fedora and other SELinux-enforcing distributions must use the
Determinate Systems installer.** The official installer does not
support SELinux; running it on an enforcing host produces a Nix
installation that fails at first use. Determinate's installer ships
the SELinux policy bits needed for the daemon and the store to work
under enforcing mode.

After installing, enable flakes by adding this line to your Nix
configuration (*note:* the Determinate Systems installer enables flakes by default)

```sh
mkdir -p ~/.config/nix
echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf
```

For a system-wide enable instead, append the same line to
`/etc/nix/nix.conf` and restart the Nix daemon
(`sudo systemctl restart nix-daemon` on multi-user installs).

Verify:

```sh
nix --version
nix flake show github:pete3n/nix-slop-dev   # should list packages and templates
```

If `flake show` errors with "experimental Nix feature 'nix-command' is
disabled", the previous step didn't take — check your editor wrote to
the right path and that `~/.config/nix/nix.conf` is owned by your user.

To setup using the provided app:

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
  them to bubblewrap (step 4). Only relevant on Ubuntu 23.10+/24.04+.
- **SELinux `/nix` file-context** — when SELinux is enforcing, `/nix/store`
  must be labeled like `/usr` (step 5). Only relevant on SELinux distros
  (Fedora, RHEL, derivatives).

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

### Fedora: remove the `task,never` suppression rule

Fedora's `audit` package ships `/etc/audit/rules.d/audit.rules` containing
`-a task,never`, which clears the per-task audit context and silently disables
**all** syscall auditing — even when explicit `-S connect` rules are
installed. The Sandbox's violation banner and `setup-linux --log` are
syscall-audit-based, so this rule must be commented out for alerts to
work.

`setup-linux --apply` does this automatically (and `setup-linux --remove`
restores it). To do it by hand:

```sh
sudo sed -i 's|^-a task,never$|# nix-slop-dev: -a task,never  (re-enable with setup-linux --remove) (was: -a task,never)|' /etc/audit/rules.d/audit.rules
sudo augenrules --load
sudo auditctl -d task,never
```

Verify with `sudo auditctl -l` — the `-a never,task` line should be gone.

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

## 4. AppArmor unprivileged user namespaces (Ubuntu 23.10+/24.04+)

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

## 5. SELinux `/nix` file-context (Fedora / RHEL / derivatives)

Targeted SELinux policies ship no entry for `/nix`, so every store path
ends up labeled `default_t`. `sudo systemd-run --property=User=…` runs the
wrapper's `ExecStart` via `systemd-executor` in the `init_t` domain, and
the kernel refuses `init_t → default_t : file execute` — the transient
unit exits with `EXIT_EXEC=203` before the jailed binary ever runs.
Check the host state:

```sh
getenforce                                                       # "Enforcing" / "Permissive" / "Disabled"
stat -c '%C' "$(readlink -f "$(command -v nix)")"                # type field should NOT be default_t
sudo ausearch -m AVC -ts recent | grep -E 'default_t|nix/store'  # past denials, if any
```

If `getenforce` prints `Enforcing` and the `stat` type field is
`default_t`, install a file-context equivalence that treats `/nix` like
`/usr` (so `/nix/store/.../bin/foo` inherits `bin_t`):

```sh
sudo dnf install -y policycoreutils-python-utils   # provides `semanage` on minimal Fedora
sudo semanage fcontext -a -e /usr /nix
sudo restorecon -R /nix
```

Verify:

```sh
stat -c '%C' "$(readlink -f "$(command -v nix)")"   # type should be bin_t now
```

`setup-linux --apply` does all of this for you (and `setup-linux --remove`
drops the equivalence + relabels `/nix` back to `default_t`).

### Why an equivalence rule and not a custom type?

The `-e /usr /nix` form tells SELinux "label paths under `/nix` the way
you label the same suffix under `/usr`". After `restorecon -R /nix`,
`/nix/store/.../bin/setpriv` gets the same context the equivalent
`/usr/.../bin/setpriv` would have — typically `bin_t` — which `init_t`
already has policy to execute. Inventing a custom `nix_store_t` type
would require shipping a policy module (.te + .pp + semodule install)
just to re-add every `init_t → bin_t` rule against the new type. The
equivalence is one `semanage` call and inherits Fedora's existing
`bin_t` policy verbatim.

## 6. Verify

```sh
nix run github:pete3n/nix-slop-dev#setup-linux   # all ✓, exits 0
```
