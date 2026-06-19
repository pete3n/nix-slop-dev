package listener

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
// the listener dispatches the callback through to whichever handler the
// peeked first byte selects.
type denialRecord struct {
	host, port, protocol, reason string
}

func recordingDeny(records *[]denialRecord) func(host, port, protocol, reason string) {
	return func(host, port, protocol, reason string) {
		*records = append(*records, denialRecord{host, port, protocol, reason})
	}
}

// noopDeny is the test double for the no-deny-expected path. Existing
// dispatch tests pass it so the new signature does not force them to
// care about the logger.
var noopDeny = func(host, port, protocol, reason string) {}

// A client whose first byte is 0x05 must be dispatched to the SOCKS5
// handler. The dispatch is verified by observing a well-formed SOCKS5
// greeting reply (`05 00` for NO-AUTH accepted) — only the SOCKS5
// handler emits that reply shape. Critically, the peeked first byte
// must reach the handler's read stream (the SOCKS5 handler reads VER
// from offset 0 with io.ReadFull); if Serve consumed the byte without
// putting it back, the handler would see VER=0x01 (NMETHODS) and
// fail closed instead of replying.
func TestFirstByte0x05DispatchesToSocks(t *testing.T) {
	matcher, err := whitelist.New([]string{"example.com"})
	if err != nil {
		t.Fatalf("whitelist.New: %v", err)
	}

	clientEnd, serverEnd := net.Pipe()
	t.Cleanup(func() { clientEnd.Close() })
	clientEnd.SetDeadline(time.Now().Add(2 * time.Second))

	dialer := func(network, address string) (net.Conn, error) {
		return nil, errors.New("dialer must not be called before request is parsed")
	}

	done := make(chan error, 1)
	go func() {
		done <- Serve(serverEnd, matcher, dialer, noopDeny)
	}()

	// SOCKS5 greeting: VER=0x05, NMETHODS=1, METHODS=[0x00 NO-AUTH].
	if _, err := clientEnd.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		t.Fatalf("write greeting: %v", err)
	}

	greetingReply := make([]byte, 2)
	if _, err := io.ReadFull(clientEnd, greetingReply); err != nil {
		t.Fatalf("read greeting reply: %v", err)
	}
	if greetingReply[0] != 0x05 || greetingReply[1] != 0x00 {
		t.Errorf("greeting reply = % x, want 05 00 (SOCKS5 handler must see peeked byte)", greetingReply)
	}

	// Close client to let ServeSocks unblock from the next read and
	// allow Serve to return.
	clientEnd.Close()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatalf("Serve did not return within 2s")
	}
}

// A client that closes before sending any byte must cause Serve to
// return without invoking either protocol handler and without dialing.
// Without this, a flood of half-open connections (curl that gives up
// before writing) could starve the listener of goroutines and would
// leave the matcher's deny path unexercised — the dispatch must fail
// closed by construction, not by accident at a later read.
func TestEOFBeforeFirstByteFailsClosedWithoutDialing(t *testing.T) {
	matcher, err := whitelist.New([]string{"example.com"})
	if err != nil {
		t.Fatalf("whitelist.New: %v", err)
	}

	clientEnd, serverEnd := net.Pipe()

	var dialCalls int
	dialer := func(network, address string) (net.Conn, error) {
		dialCalls++
		return nil, errors.New("dialer must not be called for empty client")
	}

	done := make(chan error, 1)
	go func() {
		done <- Serve(serverEnd, matcher, dialer, noopDeny)
	}()

	// Close immediately — no bytes ever cross.
	clientEnd.Close()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatalf("Serve did not return within 2s after immediate client close")
	}

	if dialCalls != 0 {
		t.Errorf("dialer called %d times for EOF-before-first-byte; want 0", dialCalls)
	}
}

// A client whose first byte is anything other than 0x05 must be
// dispatched to the HTTP CONNECT handler. The dispatch is verified by
// observing an `HTTP/1.1` status line — only the CONNECT handler emits
// that shape. Critically, the peeked first byte (the 'C' of "CONNECT")
// must reach the handler — otherwise the handler's request-line parser
// reads "ONNECT host…" and fails closed instead of either allowing or
// refusing. Using a denied host keeps the test focused on dispatch
// (deny path needs no dialer, no upstream pipe).
func TestNonSocksFirstByteDispatchesToConnect(t *testing.T) {
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
		done <- Serve(serverEnd, matcher, dialer, noopDeny)
	}()

	if _, err := io.WriteString(clientEnd, "CONNECT evil.com:443 HTTP/1.1\r\n\r\n"); err != nil {
		t.Fatalf("write CONNECT request: %v", err)
	}

	statusLine, err := bufio.NewReader(clientEnd).ReadString('\n')
	if err != nil {
		t.Fatalf("read response status line: %v", err)
	}
	if !strings.HasPrefix(statusLine, "HTTP/1.1 ") {
		t.Errorf("status line = %q, want HTTP/1.1 prefix (CONNECT handler must see peeked byte)", statusLine)
	}
	if dialCalls != 0 {
		t.Errorf("dialer called %d times for denied host; want 0", dialCalls)
	}

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatalf("Serve did not return within 2s")
	}
}
