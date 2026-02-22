package dns_scanner

import (
	"redrock-dashboard/core/pkg/scanner/dns_scanner/dns_lib"
	"time"
)

type DNSScanResult struct {
	TimeDelay   time.Duration
	ARecord     []string // 可能有负载均衡
	AAAARecord  []string // 可能有负载均衡
	CNAMERecord string
	Match       bool
}

type DNSScanner struct {
	Domain string
	Dest   string
}

func destInRecord(dest string, record []string) bool {
	for _, v := range record {
		if v == dest {
			return true
		}
	}
	return false
}

func (r DNSScanner) Scan() (*DNSScanResult, error) {
	resolver := dns_lib.NewDNSResolver(dns_lib.WithTimeout(3 * time.Second))
	result := resolver.Resolve(r.Domain)

	if result.Error != nil {
		return nil, result.Error
	}

	data := &DNSScanResult{
		TimeDelay:   result.Duration,
		ARecord:     result.IPv4,
		AAAARecord:  result.IPv6,
		CNAMERecord: result.CNAME,
		Match:       destInRecord(r.Dest, result.IPv4) || destInRecord(r.Dest, result.IPv6) || result.CNAME == r.Dest,
	}

	return data, nil
}
