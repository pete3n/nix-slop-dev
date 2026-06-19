package socks

import (
	"errors"
	"io"
	"net"
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
// inject it as ServeSocks's 4th argument and inspect the captured
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

// A denied destination host (not in the Host Whitelist) must produce a
// SOCKS5 reply with REP=0x02 ("connection not allowed by ruleset"), and
// the dialer must NOT be called. The Host Whitelist has to be consulted
// BEFORE any dial — otherwise a leaked outbound dial happens for every
// denied destination, which defeats the point of the Sandbox.
func TestDeniedDomainReturnsNotAllowedWithoutDialing(t *testing.T) {
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
		done <- ServeSocks(serverEnd, matcher, dialer, noopDeny)
	}()

	// Greeting: VER=0x05, NMETHODS=1, METHODS=[0x00 NO-AUTH].
	if _, err := clientEnd.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		t.Fatalf("write greeting: %v", err)
	}

	greetingReply := make([]byte, 2)
	if _, err := io.ReadFull(clientEnd, greetingReply); err != nil {
		t.Fatalf("read greeting reply: %v", err)
	}
	if greetingReply[0] != 0x05 || greetingReply[1] != 0x00 {
		t.Errorf("greeting reply = % x, want 05 00", greetingReply)
	}

	// Request: VER=0x05, CMD=0x01 CONNECT, RSV=0x00, ATYP=0x03 DOMAIN,
	// LEN=8, "evil.com", PORT=443 (0x01BB).
	request := []byte{0x05, 0x01, 0x00, 0x03, 0x08}
	request = append(request, []byte("evil.com")...)
	request = append(request, 0x01, 0xBB)
	if _, err := clientEnd.Write(request); err != nil {
		t.Fatalf("write request: %v", err)
	}

	// Reply: VER, REP, RSV, ATYP=0x01, BND.ADDR(4), BND.PORT(2) = 10 bytes.
	requestReply := make([]byte, 10)
	if _, err := io.ReadFull(clientEnd, requestReply); err != nil {
		t.Fatalf("read request reply: %v", err)
	}
	if requestReply[0] != 0x05 {
		t.Errorf("reply VER = 0x%02x, want 0x05", requestReply[0])
	}
	if requestReply[1] != 0x02 {
		t.Errorf("reply REP = 0x%02x, want 0x02 (not allowed by ruleset)", requestReply[1])
	}
	if dialCalls != 0 {
		t.Errorf("dialer called %d times for denied host; want 0", dialCalls)
	}

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatalf("ServeSocks did not return within 2s")
	}
}

// A denied SOCKS5 destination must invoke the Deny callback exactly
// once with the request's host, port, protocol="socks", and a non-empty
// reason. Parallel to TestDeniedHostCallsDenyLogger in connect/, but
// driven through the SOCKS5 wire format so the SOCKS deny path is also
// covered by issue 09's --log surface. A regression here means a
// SOCKS-side violation goes invisible.
func TestDeniedDomainCallsDenyLogger(t *testing.T) {
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
		done <- ServeSocks(serverEnd, matcher, dialer, deny)
	}()

	if _, err := clientEnd.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		t.Fatalf("write greeting: %v", err)
	}
	if _, err := io.ReadFull(clientEnd, make([]byte, 2)); err != nil {
		t.Fatalf("read greeting reply: %v", err)
	}

	request := []byte{0x05, 0x01, 0x00, 0x03, 0x08}
	request = append(request, []byte("evil.com")...)
	request = append(request, 0x01, 0xBB) // port 443
	if _, err := clientEnd.Write(request); err != nil {
		t.Fatalf("write request: %v", err)
	}
	if _, err := io.ReadFull(clientEnd, make([]byte, 10)); err != nil {
		t.Fatalf("read request reply: %v", err)
	}

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatalf("ServeSocks did not return within 2s")
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
	if got.protocol != "socks" {
		t.Errorf("protocol = %q, want %q", got.protocol, "socks")
	}
	if got.reason == "" {
		t.Errorf("reason is empty; callers need it to render the BLOCKED entry")
	}
}

// An allowed destination (in the Host Whitelist) must produce a SOCKS5
// reply with REP=0x00 ("succeeded") and then splice bytes
// bidirectionally between the client and the dialled destination. The
// dialer must be invoked with "host:port" reconstructed from the
// request's DOMAIN address and big-endian port bytes.
func TestAllowedDomainReturnsSucceededAndSplicesBidirectionally(t *testing.T) {
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
		done <- ServeSocks(serverEnd, matcher, dialer, noopDeny)
	}()

	if _, err := clientEnd.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		t.Fatalf("write greeting: %v", err)
	}
	greetingReply := make([]byte, 2)
	if _, err := io.ReadFull(clientEnd, greetingReply); err != nil {
		t.Fatalf("read greeting reply: %v", err)
	}

	request := []byte{0x05, 0x01, 0x00, 0x03, 0x0B}
	request = append(request, []byte("example.com")...)
	request = append(request, 0x01, 0xBB) // port 443
	if _, err := clientEnd.Write(request); err != nil {
		t.Fatalf("write request: %v", err)
	}

	requestReply := make([]byte, 10)
	if _, err := io.ReadFull(clientEnd, requestReply); err != nil {
		t.Fatalf("read request reply: %v", err)
	}
	if requestReply[0] != 0x05 || requestReply[1] != 0x00 {
		t.Errorf("reply VER/REP = % x, want 05 00", requestReply[:2])
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
	if _, err := io.ReadFull(clientEnd, fromUpstream); err != nil {
		t.Fatalf("read at client: %v", err)
	}
	if string(fromUpstream) != "pong" {
		t.Errorf("client received %q, want %q", fromUpstream, "pong")
	}
}

// An allowed (and successfully spliced) SOCKS5 request must NOT call
// the Deny callback. Without this guard, a regression that logged on
// every allowed request would drown the --log subcommand in noise and
// bury real violations.
func TestAllowedDomainDoesNotCallDenyLogger(t *testing.T) {
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
		done <- ServeSocks(serverEnd, matcher, dialer, deny)
	}()

	if _, err := clientEnd.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		t.Fatalf("write greeting: %v", err)
	}
	if _, err := io.ReadFull(clientEnd, make([]byte, 2)); err != nil {
		t.Fatalf("read greeting reply: %v", err)
	}

	request := []byte{0x05, 0x01, 0x00, 0x03, 0x0B}
	request = append(request, []byte("example.com")...)
	request = append(request, 0x01, 0xBB) // port 443
	if _, err := clientEnd.Write(request); err != nil {
		t.Fatalf("write request: %v", err)
	}
	if _, err := io.ReadFull(clientEnd, make([]byte, 10)); err != nil {
		t.Fatalf("read request reply: %v", err)
	}

	clientEnd.Close()
	upstream.Close()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatalf("ServeSocks did not return within 2s")
	}

	if len(records) != 0 {
		t.Errorf("deny callback invocations = %d, want 0; records=%+v", len(records), records)
	}
}

// If the client greeting does not offer NO-AUTH (method 0x00), the proxy
// must reply (0x05, 0xff) "no acceptable methods" and close without
// reading any request bytes. Skipping authentication would let an agent
// reach the dialer without the matcher being consulted — fail closed.
func TestNoAcceptableMethodReplies0xFFWithoutDialing(t *testing.T) {
	cases := []struct {
		name    string
		methods []byte
	}{
		{"only USER/PASS offered", []byte{0x02}},
		{"only GSSAPI offered", []byte{0x01}},
		{"unknown methods only", []byte{0x80, 0x90}},
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
				return nil, errors.New("dialer must not be called when no acceptable method")
			}

			done := make(chan error, 1)
			go func() {
				done <- ServeSocks(serverEnd, matcher, dialer, noopDeny)
			}()

			greeting := append([]byte{0x05, byte(len(testCase.methods))}, testCase.methods...)
			if _, err := clientEnd.Write(greeting); err != nil {
				t.Fatalf("write greeting: %v", err)
			}

			reply := make([]byte, 2)
			if _, err := io.ReadFull(clientEnd, reply); err != nil {
				t.Fatalf("read greeting reply: %v", err)
			}
			if reply[0] != 0x05 || reply[1] != 0xff {
				t.Errorf("greeting reply = % x, want 05 ff", reply)
			}

			clientEnd.Close()

			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatalf("ServeSocks did not return within 2s")
			}

			if dialCalls != 0 {
				t.Errorf("dialer called %d times for no-acceptable-method; want 0", dialCalls)
			}
		})
	}
}

// Only CONNECT (CMD=0x01) is supported. BIND (0x02) and UDP ASSOCIATE
// (0x03) must reply REP=0x07 ("command not supported") without dialing,
// even when the destination host IS in the Host Whitelist — supporting
// BIND would let an agent open inbound listeners, and UDP would bypass
// the TCP-only Sandbox boundary entirely.
func TestUnsupportedCommandReturns0x07WithoutDialing(t *testing.T) {
	cases := []struct {
		name string
		cmd  byte
	}{
		{"BIND", 0x02},
		{"UDP ASSOCIATE", 0x03},
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
				return nil, errors.New("dialer must not be called for unsupported command")
			}

			done := make(chan error, 1)
			go func() {
				done <- ServeSocks(serverEnd, matcher, dialer, noopDeny)
			}()

			if _, err := clientEnd.Write([]byte{0x05, 0x01, 0x00}); err != nil {
				t.Fatalf("write greeting: %v", err)
			}
			if _, err := io.ReadFull(clientEnd, make([]byte, 2)); err != nil {
				t.Fatalf("read greeting reply: %v", err)
			}

			request := []byte{0x05, testCase.cmd, 0x00, 0x03, 0x0B}
			request = append(request, []byte("example.com")...)
			request = append(request, 0x01, 0xBB)
			if _, err := clientEnd.Write(request); err != nil {
				t.Fatalf("write request: %v", err)
			}

			reply := make([]byte, 10)
			if _, err := io.ReadFull(clientEnd, reply); err != nil {
				t.Fatalf("read request reply: %v", err)
			}
			if reply[1] != 0x07 {
				t.Errorf("reply REP = 0x%02x, want 0x07 (command not supported)", reply[1])
			}
			if dialCalls != 0 {
				t.Errorf("dialer called %d times for %s; want 0", dialCalls, testCase.name)
			}

			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatalf("ServeSocks did not return within 2s")
			}
		})
	}
}

// SOCKS5 ATYP=0x01 carries a raw 4-byte IPv4 address. The proxy must
// stringify it ("1.2.3.4"), consult the matcher against that form, and
// dial with `host:port` reconstructed via net.JoinHostPort. Critical
// for the matcher: it must accept the dotted-quad form just as the
// CONNECT path's host:port string does.
func TestAllowedIPv4ReturnsSucceededAndDials(t *testing.T) {
	matcher, err := whitelist.New([]string{"1.2.3.4"})
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

	var dialedAddress string
	dialer := func(network, address string) (net.Conn, error) {
		dialedAddress = address
		return destination, nil
	}

	done := make(chan error, 1)
	go func() {
		done <- ServeSocks(serverEnd, matcher, dialer, noopDeny)
	}()

	if _, err := clientEnd.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		t.Fatalf("write greeting: %v", err)
	}
	if _, err := io.ReadFull(clientEnd, make([]byte, 2)); err != nil {
		t.Fatalf("read greeting reply: %v", err)
	}

	// VER, CMD CONNECT, RSV, ATYP=0x01 IPv4, 1.2.3.4, port 443.
	request := []byte{0x05, 0x01, 0x00, 0x01, 1, 2, 3, 4, 0x01, 0xBB}
	if _, err := clientEnd.Write(request); err != nil {
		t.Fatalf("write request: %v", err)
	}

	reply := make([]byte, 10)
	if _, err := io.ReadFull(clientEnd, reply); err != nil {
		t.Fatalf("read request reply: %v", err)
	}
	if reply[1] != 0x00 {
		t.Errorf("reply REP = 0x%02x, want 0x00 (succeeded)", reply[1])
	}
	if dialedAddress != "1.2.3.4:443" {
		t.Errorf("dialer address = %q, want %q", dialedAddress, "1.2.3.4:443")
	}
}

// SOCKS5 ATYP=0x04 carries a raw 16-byte IPv6 address. The proxy must
// stringify it canonically ("::1") and dial with net.JoinHostPort so the
// address comes out bracketed ("[::1]:443"). Without bracketing the
// dialer would parse the port boundary ambiguously and `net.Dial`
// would reject the address.
func TestAllowedIPv6ReturnsSucceededAndDials(t *testing.T) {
	matcher, err := whitelist.New([]string{"::1"})
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

	var dialedAddress string
	dialer := func(network, address string) (net.Conn, error) {
		dialedAddress = address
		return destination, nil
	}

	done := make(chan error, 1)
	go func() {
		done <- ServeSocks(serverEnd, matcher, dialer, noopDeny)
	}()

	if _, err := clientEnd.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		t.Fatalf("write greeting: %v", err)
	}
	if _, err := io.ReadFull(clientEnd, make([]byte, 2)); err != nil {
		t.Fatalf("read greeting reply: %v", err)
	}

	// VER, CMD CONNECT, RSV, ATYP=0x04 IPv6, ::1 (15 zero bytes + 0x01),
	// port 443.
	request := []byte{0x05, 0x01, 0x00, 0x04,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
		0x01, 0xBB}
	if _, err := clientEnd.Write(request); err != nil {
		t.Fatalf("write request: %v", err)
	}

	reply := make([]byte, 10)
	if _, err := io.ReadFull(clientEnd, reply); err != nil {
		t.Fatalf("read request reply: %v", err)
	}
	if reply[1] != 0x00 {
		t.Errorf("reply REP = 0x%02x, want 0x00 (succeeded)", reply[1])
	}
	if dialedAddress != "[::1]:443" {
		t.Errorf("dialer address = %q, want %q", dialedAddress, "[::1]:443")
	}
}

// Malformed input must fail closed: no dial attempted. The exact reply
// (a SOCKS5 error code, an unexpected close, or no bytes at all) is
// not load-bearing — what matters is that a parser bug cannot escalate
// to an outbound connection. Each row exercises a distinct code path.
func TestMalformedRequestFailsClosedWithoutDialing(t *testing.T) {
	cases := []struct {
		name  string
		bytes []byte
	}{
		{"wrong greeting VER", []byte{0x04, 0x01, 0x00}},
		{"truncated greeting (EOF before methods)", []byte{0x05, 0x02, 0x00}},
		{"wrong request VER", append(
			[]byte{0x05, 0x01, 0x00, 0x04, 0x01, 0x00, 0x03, 0x0B},
			append([]byte("example.com"), 0x01, 0xBB)...,
		)},
		{"unknown ATYP", []byte{0x05, 0x01, 0x00, 0x05, 0x01, 0x00, 0x05, 0x99, 0x00, 0x00}},
		{"DOMAIN with zero length", []byte{0x05, 0x01, 0x00, 0x05, 0x01, 0x00, 0x03, 0x00, 0x01, 0xBB}},
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
				return nil, errors.New("dialer must not be called for malformed input")
			}

			done := make(chan error, 1)
			go func() {
				done <- ServeSocks(serverEnd, matcher, dialer, noopDeny)
			}()

			// Drain replies so the server's Write (greeting reply,
			// failure reply) never blocks on the synchronous net.Pipe.
			drained := make(chan struct{})
			go func() {
				io.Copy(io.Discard, clientEnd)
				close(drained)
			}()

			// Write may fail mid-stream once the server closes — that is
			// fine. The assertion is on dial count, not on write success.
			go func() {
				clientEnd.Write(testCase.bytes)
				clientEnd.Close()
			}()

			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatalf("ServeSocks did not return within 2s")
			}
			<-drained

			if dialCalls != 0 {
				t.Errorf("dialer called %d times for malformed input; want 0", dialCalls)
			}
		})
	}
}

// After the tunnel is established, closing either side must promptly
// tear the splice down and let ServeSocks return — otherwise the proxy
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
				done <- ServeSocks(serverEnd, matcher, dialer, noopDeny)
			}()

			if _, err := clientEnd.Write([]byte{0x05, 0x01, 0x00}); err != nil {
				t.Fatalf("write greeting: %v", err)
			}
			if _, err := io.ReadFull(clientEnd, make([]byte, 2)); err != nil {
				t.Fatalf("read greeting reply: %v", err)
			}

			request := []byte{0x05, 0x01, 0x00, 0x03, 0x0B}
			request = append(request, []byte("example.com")...)
			request = append(request, 0x01, 0xBB)
			if _, err := clientEnd.Write(request); err != nil {
				t.Fatalf("write request: %v", err)
			}
			if _, err := io.ReadFull(clientEnd, make([]byte, 10)); err != nil {
				t.Fatalf("read request reply: %v", err)
			}

			testCase.closeSide(clientEnd, upstream)

			select {
			case <-done:
			case <-time.After(2 * time.Second):
				t.Fatalf("ServeSocks did not return within 2s after %s", testCase.name)
			}
		})
	}
}
