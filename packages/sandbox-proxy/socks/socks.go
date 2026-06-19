// Package socks implements the SOCKS5 half of the Sandbox proxy.
//
// Per ADR-0003 the proxy never terminates TLS. SOCKS5 carries the
// destination hostname (ATYP=0x03) or IP (ATYP=0x01/0x04) in cleartext
// before any payload, which is all the Host Whitelist needs to enforce.
// Only the CONNECT command and the NO-AUTH method (0x00) are supported;
// everything else fails closed.
package socks

import (
	"encoding/binary"
	"errors"
	"io"
	"net"
	"strconv"

	"github.com/pete3n/nix-slop-dev/packages/sandbox-proxy/whitelist"
)

// DialFunc opens a TCP connection to address. Injected so tests can use
// in-memory pipes instead of real sockets. The signature mirrors
// connect.DialFunc; the two packages stay independent.
type DialFunc func(network, address string) (net.Conn, error)

// DenyFunc is called once for every refused outbound. The proxy reports
// every deny path through this callback so issue 09's --log subcommand
// can render BLOCKED entries with full context. protocol is "socks" for
// this package; host/port describe the requested destination
// (best-effort when the request was malformed). reason is a short
// human-readable cause. Mirrors connect.DenyFunc and listener.DenyFunc.
type DenyFunc func(host, port, protocol, reason string)

// ServeSocks handles one SOCKS5 conversation on client: greeting,
// CONNECT request, and (when the destination is in the Host Whitelist)
// a spliced TCP tunnel via the injected dialer. Every refusal is
// reported via deny so violations are never silent. The client
// connection is closed before ServeSocks returns.
func ServeSocks(client net.Conn, matcher *whitelist.Matcher, dialer DialFunc, deny DenyFunc) error {
	defer client.Close()

	greetingHead := make([]byte, 2)
	if _, err := io.ReadFull(client, greetingHead); err != nil {
		return err
	}
	if greetingHead[0] != 0x05 {
		return errors.New("socks: unsupported version in greeting")
	}
	methods := make([]byte, int(greetingHead[1]))
	if _, err := io.ReadFull(client, methods); err != nil {
		return err
	}
	if !offersNoAuth(methods) {
		_, err := client.Write([]byte{0x05, 0xff})
		if err != nil {
			return err
		}
		return errors.New("socks: client offered no acceptable auth method")
	}
	if _, err := client.Write([]byte{0x05, 0x00}); err != nil {
		return err
	}

	requestHead := make([]byte, 4)
	if _, err := io.ReadFull(client, requestHead); err != nil {
		return err
	}
	if requestHead[0] != 0x05 {
		return errors.New("socks: unsupported version in request")
	}

	var host string
	switch requestHead[3] {
	case 0x01:
		addr := make([]byte, 4)
		if _, err := io.ReadFull(client, addr); err != nil {
			return err
		}
		host = net.IP(addr).String()
	case 0x04:
		addr := make([]byte, 16)
		if _, err := io.ReadFull(client, addr); err != nil {
			return err
		}
		host = net.IP(addr).String()
	case 0x03:
		lengthByte := make([]byte, 1)
		if _, err := io.ReadFull(client, lengthByte); err != nil {
			return err
		}
		domain := make([]byte, int(lengthByte[0]))
		if _, err := io.ReadFull(client, domain); err != nil {
			return err
		}
		host = string(domain)
	default:
		return errors.New("socks: unsupported ATYP")
	}

	portBytes := make([]byte, 2)
	if _, err := io.ReadFull(client, portBytes); err != nil {
		return err
	}

	port := binary.BigEndian.Uint16(portBytes)
	portStr := strconv.Itoa(int(port))

	if requestHead[1] != 0x01 {
		return reply(client, 0x07)
	}
	if !matcher.Allows(host) {
		deny(host, portStr, "socks", "host not in whitelist")
		return reply(client, 0x02)
	}

	address := net.JoinHostPort(host, portStr)
	destination, err := dialer("tcp", address)
	if err != nil {
		return reply(client, 0x01)
	}
	defer destination.Close()

	if err := reply(client, 0x00); err != nil {
		return err
	}
	return splice(client, destination)
}

// splice copies bytes bidirectionally between client and destination
// until either side closes. Closing one direction's writer unblocks the
// other goroutine.
func splice(client net.Conn, destination net.Conn) error {
	errs := make(chan error, 2)
	go func() {
		_, err := io.Copy(destination, client)
		destination.Close()
		errs <- err
	}()
	go func() {
		_, err := io.Copy(client, destination)
		client.Close()
		errs <- err
	}()
	<-errs
	<-errs
	return nil
}

// offersNoAuth reports whether the client's method list includes
// NO-AUTHENTICATION-REQUIRED (0x00) — the only auth method this proxy
// accepts. See RFC 1928 §3.
func offersNoAuth(methods []byte) bool {
	for _, method := range methods {
		if method == 0x00 {
			return true
		}
	}
	return false
}

// reply writes a SOCKS5 reply with the given REP byte and a zeroed
// BND.ADDR/BND.PORT (ATYP=0x01, 0.0.0.0:0) — we never bind, since the
// proxy only ever performs CONNECT.
func reply(client net.Conn, rep byte) error {
	_, err := client.Write([]byte{0x05, rep, 0x00, 0x01, 0, 0, 0, 0, 0, 0})
	return err
}
