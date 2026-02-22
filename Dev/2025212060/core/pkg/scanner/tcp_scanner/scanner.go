package tcp_scanner

import (
	"fmt"
	"net"
	vscan "redrock-dashboard/core/pkg/scanner/tcp_scanner/service_lib"
	"time"
)

type TCPScanResult struct {
	TimeDelay     time.Duration
	Open          bool
	ServiceBanner string
}

type TCPScanner struct {
	Taget string
	Port  string
}

func (r TCPScanner) Scan() (*TCPScanResult, error) {
	start := time.Now()
	address, err := net.ResolveTCPAddr("tcp", net.JoinHostPort(r.Taget, r.Port))
	if err != nil {
		return nil, err
	}

	conn, err := net.DialTCP("tcp", nil, address)
	defer conn.Close()

	duration := time.Since(start)

	if err != nil {
		data := &TCPScanResult{
			TimeDelay: duration,
			Open:      false,
		}

		return data, nil
	}

	serviceBanner := vscan.GetProbes(fmt.Sprintf("%v, %v", r.Taget, r.Port))

	data := &TCPScanResult{
		TimeDelay:     duration,
		ServiceBanner: serviceBanner,
		Open:          true,
	}

	return data, nil
}
