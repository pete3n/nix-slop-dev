package whitelist

import (
	"bufio"
	"fmt"
	"os"
	"strings"
)

// LoadFile reads a Host Whitelist file (one entry per line) and returns
// a Matcher seeded with its entries. The file format matches what the
// Linux side reads: bare lines like `example.com`, `1.2.3.4`, or
// `10.0.0.0/8`. Parse errors from New are surfaced verbatim so an
// operator can see exactly which line was rejected.
func LoadFile(path string) (*Matcher, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("whitelist: open %s: %w", path, err)
	}
	defer file.Close()

	var entries []string
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		trimmed := strings.TrimSpace(scanner.Text())
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		entries = append(entries, trimmed)
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("whitelist: read %s: %w", path, err)
	}
	return New(entries)
}
