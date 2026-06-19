// Package connect implements the HTTP CONNECT half of the Sandbox proxy.
//
// Per ADR-0003 the proxy never terminates TLS. CONNECT exposes the
// destination hostname in cleartext before the tunnel begins, which is
// all the Host Whitelist needs to enforce.
package connect

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"strings"

	"github.com/pete3n/nix-slop-dev/packages/sandbox-proxy/whitelist"
)

// DialFunc opens a TCP connection to address. Injected so tests can use
// in-memory pipes instead of real sockets.
type DialFunc func(network, address string) (net.Conn, error)

// DenyFunc is called once for every refused outbound. The proxy reports
// every deny path through this callback so issue 09's --log subcommand
// can render BLOCKED entries with full context. protocol is "connect"
// for this package; host/port describe the requested destination
// (best-effort when the request was malformed). reason is a short
// human-readable cause. Mirrors socks.DenyFunc and listener.DenyFunc.
type DenyFunc func(host, port, protocol, reason string)

// ServeConnect handles one HTTP CONNECT request on client. It reads the
// request, consults matcher, and either splices the connection to the
// dialled destination (200 Connection established) or refuses it
// (403 Forbidden). Every refusal is reported via deny so violations are
// never silent. The client connection is closed before ServeConnect
// returns.
func ServeConnect(client net.Conn, matcher *whitelist.Matcher, dialer DialFunc, deny DenyFunc) error {
	defer client.Close()
	reader := bufio.NewReader(client)

	requestLine, err := reader.ReadString('\n')
	if err != nil {
		return fmt.Errorf("read request line: %w", err)
	}
	for {
		headerLine, err := reader.ReadString('\n')
		if err != nil {
			return fmt.Errorf("read request headers: %w", err)
		}
		if headerLine == "\r\n" {
			break
		}
	}

	fields := strings.Fields(strings.TrimRight(requestLine, "\r\n"))
	if len(fields) < 2 || fields[0] != "CONNECT" {
		return refuse(client)
	}
	target := fields[1]

	host, port, err := net.SplitHostPort(target)
	if err != nil || host == "" || port == "" {
		return refuse(client)
	}
	if !matcher.Allows(host) {
		deny(host, port, "connect", "host not in whitelist")
		return refuse(client)
	}

	destination, err := dialer("tcp", target)
	if err != nil {
		return refuse(client)
	}
	defer destination.Close()

	if _, err := fmt.Fprint(client, "HTTP/1.1 200 Connection established\r\n\r\n"); err != nil {
		return err
	}
	return splice(client, reader, destination)
}

func refuse(client net.Conn) error {
	_, err := fmt.Fprint(client, "HTTP/1.1 403 Forbidden\r\n\r\n")
	return err
}

// splice copies bytes bidirectionally between the buffered client reader
// (so bytes already consumed by the request parser are not lost) and
// destination, until either side closes. Closing one direction's writer
// unblocks the other goroutine.
func splice(client net.Conn, clientReader io.Reader, destination net.Conn) error {
	errs := make(chan error, 2)
	go func() {
		_, err := io.Copy(destination, clientReader)
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
