package scanner

import (
	"redrock-dashboard/core/pkg/scanner/dns_scanner"
	"redrock-dashboard/core/pkg/scanner/icmp_scanner"
	"redrock-dashboard/core/pkg/scanner/tcp_scanner"
	"redrock-dashboard/core/pkg/scanner/web_scanner"
)

func GetDNSScanner(domain string, dest string) *dns_scanner.DNSScanner {
	return &dns_scanner.DNSScanner{Domain: domain, Dest: dest}
}

func GetTCPScanner(target string, port string) *tcp_scanner.TCPScanner {
	return &tcp_scanner.TCPScanner{Taget: target, Port: port}
}

func GetICMPScanner(target string) *icmp_scanner.ICMPScanner {
	return &icmp_scanner.ICMPScanner{Target: target}
}

func GetWEBScanner(dest string) *web_scanner.WebScanner {
	return &web_scanner.WebScanner{Dest: dest}
}
