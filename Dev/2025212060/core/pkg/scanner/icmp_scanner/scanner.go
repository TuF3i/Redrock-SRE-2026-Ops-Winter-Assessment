package icmp_scanner

import (
	"redrock-dashboard/core/pkg/scanner/icmp_scanner/icmp_lib"
	"time"
)

type ICMPScanResult struct {
	TimeDelay time.Duration
	Alive     bool
}

type ICMPScanner struct {
	Target string
}

func (r ICMPScanner) Scan() (*ICMPScanResult, error) {
	scanner := icmp_lib.NewICMPScanner(icmp_lib.WithCount(5))
	result := scanner.Scan(r.Target)

	if result.Error != nil {
		return nil, result.Error
	}

	data := &ICMPScanResult{
		TimeDelay: result.RTT,
		Alive:     result.Alive,
	}

	return data, nil
}
