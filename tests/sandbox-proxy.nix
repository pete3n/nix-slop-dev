# Behavior tests for the macOS Sandbox userspace proxy (per ADR-0003).
#
# The proxy's hostname allowlist matcher is a pure Go package consumed by
# both `New(...)` callers and the proxy's connect/splice path. This
# derivation runs `go test` against it inside a Nix sandbox so `nix flake
# check` keeps the suite green.
#
# The actual Seatbelt enforcement (that the kernel pins outbound to
# localhost:<proxyport>) is HITL per the spike's methodology and is not
# covered here.
{ pkgs }:
pkgs.runCommand "sandbox-proxy-tests"
  {
    buildInputs = [ pkgs.go ];
    src = ../packages/sandbox-proxy;
  }
  ''
    set -eu
    export HOME=$TMPDIR
    export GOCACHE=$TMPDIR/go-cache
    export GOFLAGS='-mod=mod'

    # Copy into a subdirectory so go.mod is not at the build root —
    # Go refuses to use a go.mod that sits directly in the system
    # temp root (TMPDIR), which under Nix is the build directory.
    mkdir build
    cp -r $src/* build/
    chmod -R u+w build
    cd build

    go test ./... -count=1

    touch $out
  ''
