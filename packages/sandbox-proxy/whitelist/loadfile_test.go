package whitelist

import (
	"os"
	"path/filepath"
	"testing"
)

// LoadFile reads a whitelist file (one entry per line) into a working
// *Matcher. Hand-rolled rather than reusing New so tests can assert on
// file-format behaviour (comments, blanks, error surfaces) without
// teaching New about a file API.
func TestLoadFileReadsOneEntryPerLine(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "wl")
	contents := "example.com\napi.openai.com\n1.2.3.4\n"
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	matcher, err := LoadFile(path)
	if err != nil {
		t.Fatalf("LoadFile: %v", err)
	}
	for _, host := range []string{"example.com", "api.openai.com", "1.2.3.4"} {
		if !matcher.Allows(host) {
			t.Errorf("Allows(%q) = false, want true (entry in file)", host)
		}
	}
	if matcher.Allows("evil.com") {
		t.Errorf("Allows(%q) = true, want false (not in file)", "evil.com")
	}
}

// Operators annotate the whitelist. Blank lines and `#`-prefixed
// comments must be skipped, not fed through to New (which fails closed
// on empty entries). Without this the very first attempt at a
// human-edited file becomes a startup error.
func TestLoadFileSkipsBlanksAndComments(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "wl")
	contents := "" +
		"# top-level comment\n" +
		"\n" +
		"example.com\n" +
		"   \n" +
		"  # indented comment\n" +
		"api.openai.com  \n" +
		"\n"
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	matcher, err := LoadFile(path)
	if err != nil {
		t.Fatalf("LoadFile: %v", err)
	}
	for _, host := range []string{"example.com", "api.openai.com"} {
		if !matcher.Allows(host) {
			t.Errorf("Allows(%q) = false, want true", host)
		}
	}
}

// A missing whitelist file must return an error, not a silently empty
// allowlist. An empty allowlist would deny-all, which sounds safe — but
// it would also mask a misconfiguration (wrong --whitelist path) until
// the agent makes its first outbound call. Surfacing the error at
// startup is the visible failure mode an operator wants.
func TestLoadFileMissingFileReturnsError(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "does-not-exist")

	matcher, err := LoadFile(path)
	if err == nil {
		t.Fatalf("LoadFile(missing) = nil error, want non-nil")
	}
	if matcher != nil {
		t.Errorf("LoadFile(missing) returned non-nil matcher %v; want nil", matcher)
	}
}

// A malformed entry in the file (e.g. bad CIDR) must propagate out as
// an error. New already rejects these — what LoadFile must guarantee
// is that the parse failure isn't swallowed by the file-reading layer.
// Without this assertion a future "skip bad lines" refactor could
// silently widen the allowlist surface.
func TestLoadFileSurfacesParseErrors(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "wl")
	contents := "example.com\n10.0.0.0/99\n"
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	matcher, err := LoadFile(path)
	if err == nil {
		t.Fatalf("LoadFile(bad CIDR) = nil error, want non-nil")
	}
	if matcher != nil {
		t.Errorf("LoadFile(bad CIDR) returned non-nil matcher %v; want nil", matcher)
	}
}
