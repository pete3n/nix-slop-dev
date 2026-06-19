// Package denial encodes proxy-side refusals as JSON-Lines records on
// an io.Writer. Each record carries the fields `sandboxed --log` needs
// to render a BLOCKED entry in the same shape as Linux's audit-derived
// output (issue 09 per ADR-0003). The shape is shared with the
// Seatbelt unified-log half via the `src` field — proxy entries have
// src="proxy"; the wrapper tags unified-log entries with src="seatbelt".
package denial

import (
	"encoding/json"
	"io"
	"time"
)

// Func reports one refused outbound. The proxy's connect/ and socks/
// handlers each take a callback of this shape; main.go wires both to
// an instance constructed by New.
type Func func(host, port, protocol, reason string)

// New returns a Func that writes one JSON object per call to writer.
// key is embedded in every record so multi-session log directories can
// be filtered by audit key (sandbox-<binary>-<timestamp>). now is
// injected so tests can pin the timestamp without monkey-patching the
// clock.
func New(writer io.Writer, key string, now func() time.Time) Func {
	encoder := json.NewEncoder(writer)
	return func(host, port, protocol, reason string) {
		_ = encoder.Encode(record{
			Time:     now().UTC().Format(time.RFC3339),
			Key:      key,
			Src:      "proxy",
			Protocol: protocol,
			Host:     host,
			Port:     port,
			Reason:   reason,
		})
	}
}

type record struct {
	Time     string `json:"time"`
	Key      string `json:"key"`
	Src      string `json:"src"`
	Protocol string `json:"protocol"`
	Host     string `json:"host"`
	Port     string `json:"port"`
	Reason   string `json:"reason"`
}
