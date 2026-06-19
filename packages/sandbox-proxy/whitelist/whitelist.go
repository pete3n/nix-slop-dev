package whitelist

import (
	"fmt"
	"net"
	"strings"
)

type Matcher struct {
	exact map[string]struct{}
	cidrs []*net.IPNet
}

func New(entries []string) (*Matcher, error) {
	matcher := &Matcher{exact: make(map[string]struct{}, len(entries))}
	for _, entry := range entries {
		if strings.TrimSpace(entry) == "" {
			return nil, fmt.Errorf("allowlist: empty entry")
		}
		if strings.Contains(entry, "/") {
			_, network, err := net.ParseCIDR(entry)
			if err != nil {
				return nil, fmt.Errorf("allowlist: invalid CIDR %q: %w", entry, err)
			}
			matcher.cidrs = append(matcher.cidrs, network)
			continue
		}
		matcher.exact[normalize(entry)] = struct{}{}
	}
	return matcher, nil
}

func (matcher *Matcher) Allows(host string) bool {
	if _, ok := matcher.exact[normalize(host)]; ok {
		return true
	}
	ip := parseHostIP(host)
	if ip == nil {
		return false
	}
	for _, network := range matcher.cidrs {
		if network.Contains(ip) {
			return true
		}
	}
	return false
}

func normalize(host string) string {
	if ip := parseHostIP(host); ip != nil {
		return ip.String()
	}
	return strings.TrimSuffix(strings.ToLower(host), ".")
}

func parseHostIP(host string) net.IP {
	return net.ParseIP(strings.TrimSuffix(strings.ToLower(host), "."))
}
