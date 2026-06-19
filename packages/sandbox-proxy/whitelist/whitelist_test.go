package whitelist

import "testing"

func TestExactHostnameMatch(t *testing.T) {
	matcher, err := New([]string{"example.com"})
	if err != nil {
		t.Fatalf("New returned error: %v", err)
	}
	if !matcher.Allows("example.com") {
		t.Errorf("Allows(%q) = false, want true (exact match)", "example.com")
	}
	if matcher.Allows("evil.com") {
		t.Errorf("Allows(%q) = true, want false (not in allowlist)", "evil.com")
	}
}

func TestCaseInsensitive(t *testing.T) {
	matcher, err := New([]string{"example.com"})
	if err != nil {
		t.Fatalf("New returned error: %v", err)
	}
	for _, host := range []string{"Example.com", "EXAMPLE.COM", "ExAmPlE.cOm"} {
		if !matcher.Allows(host) {
			t.Errorf("Allows(%q) = false, want true (RFC 1035 case-insensitive)", host)
		}
	}
	matcherUpper, err := New([]string{"EXAMPLE.COM"})
	if err != nil {
		t.Fatalf("New returned error: %v", err)
	}
	if !matcherUpper.Allows("example.com") {
		t.Errorf("Allows(%q) = false on uppercase entry, want true", "example.com")
	}
}

func TestTrailingDotEquivalence(t *testing.T) {
	// Entry without trailing dot, lookup with trailing dot.
	matcher, err := New([]string{"example.com"})
	if err != nil {
		t.Fatalf("New returned error: %v", err)
	}
	if !matcher.Allows("example.com.") {
		t.Errorf("Allows(%q) = false, want true (DNS root-label equivalence)", "example.com.")
	}

	// Entry with trailing dot, lookup without.
	matcherDotted, err := New([]string{"example.com."})
	if err != nil {
		t.Fatalf("New returned error: %v", err)
	}
	if !matcherDotted.Allows("example.com") {
		t.Errorf("Allows(%q) = false on dotted entry, want true", "example.com")
	}
}

func TestIPLiteralCanonicalEquivalence(t *testing.T) {
	// Same IPv6 address written multiple ways must match.
	matcher, err := New([]string{"::1"})
	if err != nil {
		t.Fatalf("New returned error: %v", err)
	}
	for _, host := range []string{"::1", "0:0:0:0:0:0:0:1", "0000:0000:0000:0000:0000:0000:0000:0001"} {
		if !matcher.Allows(host) {
			t.Errorf("Allows(%q) = false, want true (IPv6 canonical equivalence)", host)
		}
	}
	if matcher.Allows("::2") {
		t.Errorf("Allows(%q) = true, want false (different IPv6 address)", "::2")
	}

	// IPv4 entries should still work exactly (already covered, but assert here too).
	matcherV4, err := New([]string{"1.1.1.1"})
	if err != nil {
		t.Fatalf("New returned error: %v", err)
	}
	if !matcherV4.Allows("1.1.1.1") {
		t.Errorf("Allows(%q) = false, want true (IPv4 exact)", "1.1.1.1")
	}
	if matcherV4.Allows("1.0.0.1") {
		t.Errorf("Allows(%q) = true, want false (different IPv4)", "1.0.0.1")
	}
}

func TestCIDRMembership(t *testing.T) {
	matcher, err := New([]string{"10.0.0.0/8"})
	if err != nil {
		t.Fatalf("New returned error: %v", err)
	}
	for _, host := range []string{"10.0.0.1", "10.5.6.7", "10.255.255.255"} {
		if !matcher.Allows(host) {
			t.Errorf("Allows(%q) = false, want true (inside 10.0.0.0/8)", host)
		}
	}
	for _, host := range []string{"11.0.0.1", "9.255.255.255", "192.168.1.1"} {
		if matcher.Allows(host) {
			t.Errorf("Allows(%q) = true, want false (outside 10.0.0.0/8)", host)
		}
	}

	// IPv6 CIDR.
	matcherV6, err := New([]string{"2001:db8::/32"})
	if err != nil {
		t.Fatalf("New returned error: %v", err)
	}
	if !matcherV6.Allows("2001:db8:abcd::1") {
		t.Errorf("Allows(%q) = false, want true (inside 2001:db8::/32)", "2001:db8:abcd::1")
	}
	if matcherV6.Allows("2001:db9::1") {
		t.Errorf("Allows(%q) = true, want false (outside 2001:db8::/32)", "2001:db9::1")
	}
}

func TestMalformedEntriesReturnError(t *testing.T) {
	cases := []struct {
		name    string
		entries []string
	}{
		{"empty string", []string{""}},
		{"whitespace only", []string{"   "}},
		{"invalid CIDR mask", []string{"10.0.0.0/99"}},
		{"non-numeric CIDR mask", []string{"10.0.0.0/abc"}},
		{"valid entry mixed with bad", []string{"example.com", ""}},
	}
	for _, testCase := range cases {
		_, err := New(testCase.entries)
		if err == nil {
			t.Errorf("New(%v) = nil error, want non-nil (%s)", testCase.entries, testCase.name)
		}
	}
}

func TestCIDRRejectsNonIPHost(t *testing.T) {
	// A CIDR entry must never match a hostname (only IP literals).
	// Guards against accidental string-prefix matching.
	matcher, err := New([]string{"10.0.0.0/8"})
	if err != nil {
		t.Fatalf("New returned error: %v", err)
	}
	for _, host := range []string{"example.com", "10.example.com", "evil.net", "localhost"} {
		if matcher.Allows(host) {
			t.Errorf("Allows(%q) = true, want false (CIDR entries must not match hostnames)", host)
		}
	}
}
