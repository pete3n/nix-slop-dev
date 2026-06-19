# macOS Sandbox userspace proxy (per ADR-0003). Single-file Go binary
# that multiplexes HTTP CONNECT + SOCKS5 on a loopback port and
# enforces the Host Whitelist on each request's destination hostname.
# Seatbelt pins each sandboxed process's outbound traffic to this
# proxy's port; the proxy itself runs unprivileged as the calling user.
{ pkgs }:
pkgs.buildGoModule {
  pname = "sandbox-proxy";
  version = "0.0.0";
  src = ./.;
  # No external module dependencies — only the in-module subpackages
  # (whitelist/, connect/, socks/, listener/). buildGoModule still wants
  # this attribute set explicitly so an unintended dep addition becomes
  # a visible build break rather than a silent fetch.
  vendorHash = null;
  subPackages = [ "." ];
  meta = {
    description = "Userspace proxy enforcing the Host Whitelist on macOS (per ADR-0003)";
    mainProgram = "sandbox-proxy";
    platforms = pkgs.lib.platforms.darwin;
  };
}
