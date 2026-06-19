package denial

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// A single denial must emit one JSON-Lines record carrying every field
// downstream needs: time (RFC3339 UTC), the per-session audit key, the
// src tag distinguishing proxy-side entries from Seatbelt unified-log
// entries when both are merged by `sandboxed --log`, the protocol that
// caught the deny, the host:port the agent tried to reach, and a
// human-readable reason. Any field that goes missing here goes missing
// from the BLOCKED record the wrapper renders.
func TestDenialWritesJSONLineWithAllFields(t *testing.T) {
	var buf bytes.Buffer
	fixed := time.Date(2026, 6, 13, 21, 30, 1, 0, time.UTC)

	deny := New(&buf, "sandbox-curl-20260613-213001", func() time.Time { return fixed })
	deny("evil.com", "443", "connect", "host not in whitelist")

	line := buf.String()
	if !strings.HasSuffix(line, "\n") {
		t.Errorf("output = %q, want trailing newline (JSON-Lines convention)", line)
	}
	if strings.Count(line, "\n") != 1 {
		t.Errorf("output has %d newlines, want exactly 1", strings.Count(line, "\n"))
	}

	var record map[string]string
	if err := json.Unmarshal([]byte(line), &record); err != nil {
		t.Fatalf("JSON unmarshal: %v; line=%q", err, line)
	}

	for field, want := range map[string]string{
		"time":     "2026-06-13T21:30:01Z",
		"key":      "sandbox-curl-20260613-213001",
		"src":      "proxy",
		"protocol": "connect",
		"host":     "evil.com",
		"port":     "443",
		"reason":   "host not in whitelist",
	} {
		if got := record[field]; got != want {
			t.Errorf("record[%q] = %q, want %q", field, got, want)
		}
	}
}

// Multiple denials must produce one JSON object per line (the JSON-Lines
// format) so the wrapper's --log reader can stream them with `jq -c .`
// or a plain awk loop. A regression that buffered into a single object
// or comma-separated list would break parseability.
func TestMultipleDenialsAreOneLineEach(t *testing.T) {
	var buf bytes.Buffer
	fixed := time.Date(2026, 6, 13, 21, 30, 1, 0, time.UTC)

	deny := New(&buf, "sandbox-curl-20260613-213001", func() time.Time { return fixed })
	deny("evil.com", "443", "connect", "host not in whitelist")
	deny("foo.bar", "443", "socks", "host not in whitelist")

	lines := strings.Split(strings.TrimRight(buf.String(), "\n"), "\n")
	if len(lines) != 2 {
		t.Fatalf("got %d lines, want 2; output=%q", len(lines), buf.String())
	}
	for index, line := range lines {
		var record map[string]string
		if err := json.Unmarshal([]byte(line), &record); err != nil {
			t.Errorf("line %d not valid JSON: %v; line=%q", index, err, line)
		}
	}
}
