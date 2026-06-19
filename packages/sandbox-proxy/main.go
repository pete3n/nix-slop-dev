// Command sandbox-proxy is the macOS Sandbox userspace proxy (per
// ADR-0003). It listens on a single loopback TCP port, multiplexes HTTP
// CONNECT and SOCKS5 (peeking the first byte), enforces the Host
// Whitelist against each request's destination hostname, and splices
// allowed connections to the real upstream via net.Dial.
//
// The actual confinement is provided by the surrounding Seatbelt
// profile, which pins each sandboxed process's outbound traffic to
// 127.0.0.1:<proxyport>. The proxy itself runs unprivileged as the
// invoking user.
package main

import (
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/pete3n/nix-slop-dev/packages/sandbox-proxy/denial"
	"github.com/pete3n/nix-slop-dev/packages/sandbox-proxy/listener"
	"github.com/pete3n/nix-slop-dev/packages/sandbox-proxy/whitelist"
)

func main() {
	listenAddr := flag.String("listen", "127.0.0.1:0",
		"address to listen on (default 127.0.0.1:0 — let the kernel pick)")
	whitelistPath := flag.String("whitelist", "",
		"path to the Host Whitelist file (one entry per line; `#` comments allowed)")
	key := flag.String("key", "",
		"audit key embedded in every denial JSON record (sandbox-<binary>-<timestamp>)")
	flag.Parse()

	if *whitelistPath == "" {
		fmt.Fprintln(os.Stderr, "sandbox-proxy: --whitelist is required")
		flag.Usage()
		os.Exit(2)
	}
	if *key == "" {
		fmt.Fprintln(os.Stderr, "sandbox-proxy: --key is required")
		flag.Usage()
		os.Exit(2)
	}

	matcher, err := whitelist.LoadFile(*whitelistPath)
	if err != nil {
		log.Fatalf("sandbox-proxy: %v", err)
	}

	tcpListener, err := net.Listen("tcp", *listenAddr)
	if err != nil {
		log.Fatalf("sandbox-proxy: listen %s: %v", *listenAddr, err)
	}
	fmt.Fprintf(os.Stderr, "sandbox-proxy: listening on %s\n",
		tcpListener.Addr().String())

	// The proxy is the lifetime of one sandboxed invocation. On SIGINT/
	// SIGTERM the parent expects an immediate, clean exit — in-flight
	// spliced tunnels (long TLS streams from `npm install`,
	// `claude-code`) are abandoned to the OS rather than drained. The
	// sandboxed agents are torn down alongside the proxy, so there is
	// no caller left to receive any drained bytes.
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-signals
		os.Exit(0)
	}()

	dialer := listener.DialFunc(net.Dial)
	deny := listener.DenyFunc(denial.New(os.Stderr, *key, time.Now))

	for {
		client, err := tcpListener.Accept()
		if err != nil {
			log.Printf("sandbox-proxy: accept: %v", err)
			continue
		}
		go func() {
			if err := listener.Serve(client, matcher, dialer, deny); err != nil {
				log.Printf("sandbox-proxy: %v", err)
			}
		}()
	}
}
