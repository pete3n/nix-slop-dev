package connect

import (
	"bufio"
	"errors"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/pete3n/nix-slop-dev/packages/sandbox-proxy/whitelist"
)

// denialRecord captures one Deny callback invocation so tests can assert
// the proxy logs every refused outbound with enough context for issue 09
// to render BLOCKED entries downstream (host, port, protocol, reason).
type denialRecord struct {
	host, port, protocol, reason string
}

// recordingDeny is the test double for the proxy's denial logger. Tests
// inject it as ServeConnect's 4th argument and inspect the captured
// records — a missed deny path means a violation goes silent in the
// real wrapper, which is exactly what issue 09 must rule out.
func recordingDeny(records *[]denialRecord) func(host, port, protocol, reason string) {
	return func(host, port, protocol, reason string) {
		*records = append(*records, denialRecord{host, port, protocol, reason})
	}
}

// noopDeny is the test double for the no-deny-expected path. Existing
// allow/splice tests pass it so the new signature does not force them
// to care about the logger.
var noopDeny = func(host, port, protocol, reason string) {}

// A denied host (target not in the Host Whitelist) must produce
// `HTTP/1.1 403 Forbidden`, and the dialer must NOT be called.
// The Whitelist has to be consulted BEFORE any dial — otherwise a leaked
// outbound dial happens for every denied destination, which defeats the
// point of the Sandbox.
func TestDeniedHostReturns403WithoutDialing(t *testing.T) {
	matcher, err := whitelist.New([]string{"example.com"})
	if err != nil {
		t.Fatalf("whitelist.New: %v", err)
	}

	clientEnd, serverEnd := net.Pipe()
	t.Cleanup(func() { clientEnd.Close() })
	clientEnd.SetDeadline(time.Now().Add(2 * time.Second))

	var dialCalls int
	dialer := func(network, address string) (net.Conn, error) {
		dialCalls++
		return nil, errors.New("dialer must not be called for denied host")
	}

	done := make(chan error, 1)
	go func() {
		done <- ServeConnect(serverEnd, matcher, dialer, noopDeny)
	}()

	request := "CONNECT evil.com:443 HTTP/1.1\r\n\r\n"
	if _, err := io.WriteString(clientEnd, request); err != nil {
		t.Fatalf("write CONNECT request: %v", err)
	}

	statusLine, err := bufio.NewReader(clientEnd).ReadString('\n')
	if err != nil {
		t.Fatalf("read response status line: %v", err)
	}
	if !strings.HasPrefix(statusLine, "HTTP/1.1 403") {
		t.Errorf("status line = %q, want prefix %q", statusLine, "HTTP/1.1 403")
	}
	if dialCalls != 0 {
		t.Errorf("dialer called %d times for denied host; want 0", dialCalls)
	}

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatalf("ServeConnect did not return within 2s")
	}
}

// A denied host must invoke the Deny callback exactly once with the
// CONNECT target's host, port, protocol="connect", and a non-empty
// reason. This is the foundation of issue 09's --log subcommand: the
// proxy's denial entries carry the per-deny context the wrapper needs
// to render Linux-shape BLOCKED records. If the matcher's deny site
// stops calling Deny, the violation goes invisible.
func TestDeniedHostCallsDenyLogger(t *testing.T) {
	matcher, err := whitelist.New([]string{"example.com"})
	if err != nil {
		t.Fatalf("whitelist.New: %v", err)
	}

	clientEnd, serverEnd := net.Pipe()
	t.Cleanup(func() { clientEnd.Close() })
	clientEnd.SetDeadline(time.Now().Add(2 * time.Second))

	dialer := func(network, address string) (net.Conn, error) {
		return nil, errors.New("dialer must not be called for denied host")
	}

	var records []denialRecord
	deny := recordingDeny(&records)

	done := make(chan error, 1)
	go func() {
		done <- ServeConnect(serverEnd, matcher, dialer, deny)
	}()

	if _, err := io.WriteString(clientEnd, "CONNECT evil.com:443 HTTP/1.1\r\n\r\n"); err != nil {
		t.Fatalf("write CONNECT request: %v", err)
	}
	if _, err := bufio.NewReader(clientEnd).ReadString('\n'); err != nil {
		t.Fatalf("read response status line: %v", err)
	}

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatalf("ServeConnect did not return within 2s")
	}

	if len(records) != 1 {
		t.Fatalf("deny callback invocations = %d, want 1; records=%+v", len(records), records)
	}
	got := records[0]
	if got.host != "evil.com" {
		t.Errorf("host = %q, want %q", got.host, "evil.com")
	}
	if got.port != "443" {
		t.Errorf("port = %q, want %q", got.port, "443")
	}
	if got.protocol != "connect" {
		t.Errorf("protocol = %q, want %q", got.protocol, "connect")
	}
	if got.reason == "" {
		t.Errorf("reason is empty; callers need it to render the BLOCKED entry")
	}
}

// An allowed host (target in the Host Whitelist) must produce
// `HTTP/1.1 200 Connection established` and then splice bytes
// bidirectionally between the client and the dialled destination.
// The dialer must be invoked with the original `host:port` from the
// CONNECT request line.
func TestAllowedHostReturns200AndSplicesBidirectionally(t *testing.T) {
	matcher, err := whitelist.New([]string{"example.com"})
	if err != nil {
		t.Fatalf("whitelist.New: %v", err)
	}

	clientEnd, serverEnd := net.Pipe()
	upstream, destination := net.Pipe()
	t.Cleanup(func() {
		clientEnd.Close()
		upstream.Close()
	})
	deadline := time.Now().Add(2 * time.Second)
	clientEnd.SetDeadline(deadline)
	upstream.SetDeadline(deadline)

	var dialedNetwork, dialedAddress string
	dialer := func(network, address string) (net.Conn, error) {
		dialedNetwork, dialedAddress = network, address
		return destination, nil
	}

	done := make(chan error, 1)
	go func() {
		done <- ServeConnect(serverEnd, matcher, dialer, noopDeny)
	}()

	request := "CONNECT example.com:443 HTTP/1.1\r\n\r\n"
	if _, err := io.WriteString(clientEnd, request); err != nil {
		t.Fatalf("write CONNECT request: %v", err)
	}

	clientReader := bufio.NewReader(clientEnd)
	statusLine, err := clientReader.ReadString('\n')
	if err != nil {
		t.Fatalf("read response status line: %v", err)
	}
	if !strings.HasPrefix(statusLine, "HTTP/1.1 200") {
		t.Errorf("status line = %q, want prefix %q", statusLine, "HTTP/1.1 200")
	}
	blank, err := clientReader.ReadString('\n')
	if err != nil {
		t.Fatalf("read blank line after response headers: %v", err)
	}
	if blank != "\r\n" {
		t.Errorf("expected empty line terminating response headers, got %q", blank)
	}

	if dialedNetwork != "tcp" {
		t.Errorf("dialer network = %q, want %q", dialedNetwork, "tcp")
	}
	if dialedAddress != "example.com:443" {
		t.Errorf("dialer address = %q, want %q", dialedAddress, "example.com:443")
	}

	// Client → upstream.
	if _, err := io.WriteString(clientEnd, "ping"); err != nil {
		t.Fatalf("write from client: %v", err)
	}
	fromClient := make([]byte, 4)
	if _, err := io.ReadFull(upstream, fromClient); err != nil {
		t.Fatalf("read at upstream: %v", err)
	}
	if string(fromClient) != "ping" {
		t.Errorf("upstream received %q, want %q", fromClient, "ping")
	}

	// Upstream → client.
	if _, err := io.WriteString(upstream, "pong"); err != nil {
		t.Fatalf("write from upstream: %v", err)
	}
	fromUpstream := make([]byte, 4)
	if _, err := io.ReadFull(clientReader, fromUpstream); err != nil {
		t.Fatalf("read at client: %v", err)
	}
	if string(fromUpstream) != "pong" {
		t.Errorf("client received %q, want %q", fromUpstream, "pong")
	}
}

// An allowed (and successfully spliced) CONNECT request must NOT call
// the Deny callback. Without this guard, a regression that logged on
// every request (or every successful tunnel close) would drown the
// --log subcommand in noise and bury real violations.
func TestAllowedHostDoesNotCallDenyLogger(t *testing.T) {
	matcher, err := whitelist.New([]string{"example.com"})
	if err != nil {
		t.Fatalf("whitelist.New: %v", err)
	}

	clientEnd, serverEnd := net.Pipe()
	upstream, destination := net.Pipe()
	t.Cleanup(func() {
		clientEnd.Close()
		upstream.Close()
	})
	deadline := time.Now().Add(2 * time.Second)
	clientEnd.SetDeadline(deadline)
	upstream.SetDeadline(deadline)

	dialer := func(network, address string) (net.Conn, error) {
		return destination, nil
	}

	var records []denialRecord
	deny := recordingDeny(&records)

	done := make(chan error, 1)
	go func() {
		done <- ServeConnect(serverEnd, matcher, dialer, deny)
	}()

	if _, err := io.WriteString(clientEnd, "CONNECT example.com:443 HTTP/1.1\r\n\r\n"); err != nil {
		t.Fatalf("write CONNECT request: %v", err)
	}
	clientReader := bufio.NewReader(clientEnd)
	if _, err := clientReader.ReadString('\n'); err != nil {
		t.Fatalf("read status line: %v", err)
	}
	if _, err := clientReader.ReadString('\n'); err != nil {
		t.Fatalf("read blank header line: %v", err)
	}

	// Close both sides so the splice tears down and ServeConnect returns.
	clientEnd.Close()
	upstream.Close()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatalf("ServeConnect did not return within 2s")
	}

	if len(records) != 0 {
		t.Errorf("deny callback invocations = %d, want 0; records=%+v", len(records), records)
	}
}

// A malformed CONNECT request must fail closed: no dial attempted, no
// 200 response. The exact rejection code (403 vs 400 vs closed) is not
// load-bearing — what matters is that a parser bug cannot escalate to an
// outbound connection.
func TestMalformedRequestFailsClosedWithoutDialing(t *testing.T) {
	cases := []struct {
		name    string
		request string
	}{
		{"empty request line", "\r\n\r\n"},
		{"method without target", "CONNECT\r\n\r\n"},
		{"target missing port", "CONNECT example.com HTTP/1.1\r\n\r\n"},
		{"target with empty port", "CONNECT example.com: HTTP/1.1\r\n\r\n"},
		{"garbage instead of request line", "junk data here\r\n\r\n"},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			matcher, err := whitelist.New([]string{"example.com"})
			if err != nil {
				t.Fatalf("whitelist.New: %v", err)
			}

			clientEnd, serverEnd := net.Pipe()
			t.Cleanup(func() { clientEnd.Close() })
			clientEnd.SetDeadline(time.Now().Add(2 * time.Second))

			var dialCalls int
			dialer := func(network, address string) (net.Conn, error) {
				dialCalls++
				return nil, errors.New("dialer must not be called for malformed request")
			}

			done := make(chan error, 1)
			go func() {
				done <- ServeConnect(serverEnd, matcher, dialer, noopDeny)
			}()

			if _, err := io.WriteString(clientEnd, testCase.request); err != nil {
				t.Fatalf("write request: %v", err)
			}

			// Drain whatever the proxy responded with — we just need to
			// ensure it is NOT a 200, and unblock ServeConnect's write.
			responseLine, _ := bufio.NewReader(clientEnd).ReadString('\n')
			if strings.HasPrefix(responseLine, "HTTP/1.1 200") {
				t.Errorf("malformed request got 200 response line %q", responseLine)
			}

			clientEnd.Close()

			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatalf("ServeConnect did not return within 2s")
			}

			if dialCalls != 0 {
				t.Errorf("dialer called %d times for malformed request; want 0", dialCalls)
			}
		})
	}
}

// The proxy is HTTPS-tunnel-only (per ADR-0003: no TLS termination,
// hostname enforcement reads `CONNECT host:port` cleartext). Plain HTTP
// forward proxying (GET/POST with absolute-form URI) must be refused
// even when the destination host IS in the Host Whitelist — supporting
// it would require MITM to enforce hostnames, which the ADR rejects.
func TestNonConnectMethodFailsClosed(t *testing.T) {
	cases := []struct {
		name    string
		request string
	}{
		{"GET to allowed host", "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n"},
		{"POST to allowed host", "POST http://example.com/ HTTP/1.1\r\nHost: example.com\r\nContent-Length: 0\r\n\r\n"},
		{"HEAD to allowed host", "HEAD http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n"},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			matcher, err := whitelist.New([]string{"example.com"})
			if err != nil {
				t.Fatalf("whitelist.New: %v", err)
			}

			clientEnd, serverEnd := net.Pipe()
			t.Cleanup(func() { clientEnd.Close() })
			clientEnd.SetDeadline(time.Now().Add(2 * time.Second))

			var dialCalls int
			dialer := func(network, address string) (net.Conn, error) {
				dialCalls++
				return nil, errors.New("dialer must not be called for non-CONNECT method")
			}

			done := make(chan error, 1)
			go func() {
				done <- ServeConnect(serverEnd, matcher, dialer, noopDeny)
			}()

			if _, err := io.WriteString(clientEnd, testCase.request); err != nil {
				t.Fatalf("write request: %v", err)
			}

			responseLine, _ := bufio.NewReader(clientEnd).ReadString('\n')
			if strings.HasPrefix(responseLine, "HTTP/1.1 200") {
				t.Errorf("non-CONNECT method got 200 response line %q (would enable plain-HTTP proxying)", responseLine)
			}

			clientEnd.Close()

			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatalf("ServeConnect did not return within 2s")
			}

			if dialCalls != 0 {
				t.Errorf("dialer called %d times for non-CONNECT method; want 0", dialCalls)
			}
		})
	}
}

// After a tunnel is established, closing either side must promptly tear
// the splice down and let ServeConnect return — otherwise the proxy
// accumulates goroutines for every disconnected agent and eventually
// hangs the listener.
func TestSpliceReturnsWhenEitherSideCloses(t *testing.T) {
	cases := []struct {
		name      string
		closeSide func(client, upstream net.Conn)
	}{
		{"client closes", func(client, upstream net.Conn) { client.Close() }},
		{"upstream closes", func(client, upstream net.Conn) { upstream.Close() }},
	}

	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			matcher, err := whitelist.New([]string{"example.com"})
			if err != nil {
				t.Fatalf("whitelist.New: %v", err)
			}

			clientEnd, serverEnd := net.Pipe()
			upstream, destination := net.Pipe()
			t.Cleanup(func() {
				clientEnd.Close()
				upstream.Close()
			})
			deadline := time.Now().Add(2 * time.Second)
			clientEnd.SetDeadline(deadline)
			upstream.SetDeadline(deadline)

			dialer := func(network, address string) (net.Conn, error) {
				return destination, nil
			}

			done := make(chan error, 1)
			go func() {
				done <- ServeConnect(serverEnd, matcher, dialer, noopDeny)
			}()

			if _, err := io.WriteString(clientEnd, "CONNECT example.com:443 HTTP/1.1\r\n\r\n"); err != nil {
				t.Fatalf("write CONNECT: %v", err)
			}
			clientReader := bufio.NewReader(clientEnd)
			if _, err := clientReader.ReadString('\n'); err != nil {
				t.Fatalf("read status line: %v", err)
			}
			if _, err := clientReader.ReadString('\n'); err != nil {
				t.Fatalf("read blank header line: %v", err)
			}

			testCase.closeSide(clientEnd, upstream)

			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatalf("ServeConnect did not return within 2s after %s", testCase.name)
			}
		})
	}
}
