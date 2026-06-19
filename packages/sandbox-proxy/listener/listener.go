// Package listener multiplexes HTTP CONNECT and SOCKS5 on a single
// loopback port. Per ADR-0003 the Sandbox proxy accepts either protocol
// — agents discovering it via HTTPS_PROXY/HTTP_PROXY will speak HTTP
// CONNECT; agents via ALL_PROXY may speak SOCKS5. Peeking the first
// byte (0x05 = SOCKS5) avoids requiring callers to pick a port per
// protocol while keeping both handlers' interfaces unchanged.
package listener

import (
	"errors"
	"net"

	"github.com/pete3n/nix-slop-dev/packages/sandbox-proxy/connect"
	"github.com/pete3n/nix-slop-dev/packages/sandbox-proxy/socks"
	"github.com/pete3n/nix-slop-dev/packages/sandbox-proxy/whitelist"
)

// DialFunc opens a TCP connection to address. Mirrors the per-handler
// DialFunc types in connect/ and socks/; converted at the call sites so
// those packages stay independent of this one.
type DialFunc func(network, address string) (net.Conn, error)

// DenyFunc is called once for every refused outbound. Mirrors the
// per-handler DenyFunc types in connect/ and socks/; converted at the
// call sites so those packages stay independent of this one.
type DenyFunc func(host, port, protocol, reason string)

// Serve reads the first byte of client to choose between SOCKS5 and
// HTTP CONNECT, then hands the connection (with the peeked byte still
// visible in its read stream) to the chosen handler. Every refusal is
// reported via deny so violations are never silent. The client
// connection is closed before Serve returns.
func Serve(client net.Conn, matcher *whitelist.Matcher, dialer DialFunc, deny DenyFunc) error {
	first := make([]byte, 1)
	count, err := client.Read(first)
	if err != nil || count == 0 {
		client.Close()
		return errors.New("listener: client closed before first byte")
	}

	wrapped := &peekConn{Conn: client, prefix: first[:count]}

	if first[0] == 0x05 {
		return socks.ServeSocks(wrapped, matcher, socks.DialFunc(dialer), socks.DenyFunc(deny))
	}
	return connect.ServeConnect(wrapped, matcher, connect.DialFunc(dialer), connect.DenyFunc(deny))
}

// peekConn lets a single byte (or short prefix) be put back in front of
// a net.Conn's read stream without changing the conn's interface. The
// chosen handler reads bytes as if Serve never touched them.
type peekConn struct {
	net.Conn
	prefix []byte
}

func (conn *peekConn) Read(buffer []byte) (int, error) {
	if len(conn.prefix) > 0 {
		count := copy(buffer, conn.prefix)
		conn.prefix = conn.prefix[count:]
		return count, nil
	}
	return conn.Conn.Read(buffer)
}
