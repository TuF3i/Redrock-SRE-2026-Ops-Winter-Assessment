package icmp_lib

import (
	"fmt"
	"net"
	"os"
	"time"

	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
	"golang.org/x/net/ipv6"
)

// ICMPScanner ICMP 扫描器结构体
type ICMPScanner struct {
	timeout time.Duration
	count   int
	size    int
	ttl     int
	network string // "ip4" 或 "ip6"
	id      int
	seq     int
}

// ScanResult 扫描结果
type ScanResult struct {
	IP       net.IP
	Alive    bool
	RTT      time.Duration
	Sent     int
	Received int
	Loss     float64
	Error    error
}

// NewICMPScanner 创建新的 ICMP 扫描器
func NewICMPScanner(opts ...ScannerOption) *ICMPScanner {
	s := &ICMPScanner{
		timeout: 2 * time.Second,
		count:   3,
		size:    56,
		ttl:     64,
		network: "ip4",
		id:      os.Getpid() & 0xffff,
		seq:     0,
	}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

// ScannerOption 扫描器配置选项
type ScannerOption func(*ICMPScanner)

func WithTimeout(d time.Duration) ScannerOption {
	return func(s *ICMPScanner) { s.timeout = d }
}

func WithCount(n int) ScannerOption {
	return func(s *ICMPScanner) { s.count = n }
}

func WithTTL(ttl int) ScannerOption {
	return func(s *ICMPScanner) { s.ttl = ttl }
}

func WithIPv6() ScannerOption {
	return func(s *ICMPScanner) { s.network = "ip6" }
}

// Scan 扫描单个 IP 地址（对外暴露的唯一接口）
func (s *ICMPScanner) Scan(ip string) *ScanResult {
	dst, err := net.ResolveIPAddr(s.network, ip)
	if err != nil {
		return &ScanResult{IP: nil, Alive: false, Error: fmt.Errorf("resolve failed: %w", err)}
	}

	result := &ScanResult{
		IP:   dst.IP,
		Sent: s.count,
	}

	// 根据协议选择扫描方法
	if dst.IP.To4() != nil {
		result = s.scanIPv4(dst)
	} else {
		result = s.scanIPv6(dst)
	}

	if result.Received > 0 {
		result.Alive = true
		result.Loss = float64(result.Sent-result.Received) / float64(result.Sent) * 100
	} else {
		result.Loss = 100
	}

	return result
}

// scanIPv4 IPv4 ICMP 扫描
func (s *ICMPScanner) scanIPv4(dst *net.IPAddr) *ScanResult {
	result := &ScanResult{IP: dst.IP, Sent: s.count}

	// 创建 ICMP 连接
	conn, err := icmp.ListenPacket("ip4:icmp", "0.0.0.0")
	if err != nil {
		result.Error = fmt.Errorf("listen failed: %w", err)
		return result
	}
	defer conn.Close()

	// 设置 TTL
	if pc := conn.IPv4PacketConn(); pc != nil {
		pc.SetTTL(s.ttl)
	}

	// 发送多个探测包
	var totalRTT time.Duration
	for i := 0; i < s.count; i++ {
		s.seq++
		rtt, err := s.ping(conn, dst, ipv4.ICMPTypeEcho, s.seq)
		if err == nil {
			result.Received++
			totalRTT += rtt
		}
		time.Sleep(10 * time.Millisecond) // 短暂间隔避免拥塞
	}

	if result.Received > 0 {
		result.RTT = totalRTT / time.Duration(result.Received)
	}

	return result
}

// scanIPv6 IPv6 ICMP 扫描
func (s *ICMPScanner) scanIPv6(dst *net.IPAddr) *ScanResult {
	result := &ScanResult{IP: dst.IP, Sent: s.count}

	conn, err := icmp.ListenPacket("ip6:ipv6-icmp", "::")
	if err != nil {
		result.Error = fmt.Errorf("listen failed: %w", err)
		return result
	}
	defer conn.Close()

	var totalRTT time.Duration
	for i := 0; i < s.count; i++ {
		s.seq++
		rtt, err := s.ping(conn, dst, ipv6.ICMPTypeEchoRequest, s.seq)
		if err == nil {
			result.Received++
			totalRTT += rtt
		}
		time.Sleep(10 * time.Millisecond)
	}

	if result.Received > 0 {
		result.RTT = totalRTT / time.Duration(result.Received)
	}

	return result
}

// ping 发送单个 ICMP Echo 请求并等待响应
func (s *ICMPScanner) ping(conn *icmp.PacketConn, dst *net.IPAddr, typ icmp.Type, seq int) (time.Duration, error) {
	// 构造 ICMP Echo 请求
	data := make([]byte, s.size)
	for i := range data {
		data[i] = byte(i & 0xff)
	}

	msg := &icmp.Message{
		Type: typ,
		Code: 0,
		Body: &icmp.Echo{
			ID:   s.id,
			Seq:  seq,
			Data: data,
		},
	}

	msgBytes, err := msg.Marshal(nil)
	if err != nil {
		return 0, err
	}

	// 发送
	start := time.Now()
	if _, err := conn.WriteTo(msgBytes, dst); err != nil {
		return 0, err
	}

	// 接收响应
	reply := make([]byte, 1500)
	conn.SetReadDeadline(time.Now().Add(s.timeout))
	n, peer, err := conn.ReadFrom(reply)
	if err != nil {
		return 0, err
	}
	rtt := time.Since(start)

	// 解析响应
	rm, err := icmp.ParseMessage(typ.Protocol(), reply[:n])
	if err != nil {
		return 0, err
	}

	// 验证响应
	if rm.Type == ipv4.ICMPTypeEchoReply || rm.Type == ipv6.ICMPTypeEchoReply {
		if echo, ok := rm.Body.(*icmp.Echo); ok {
			if echo.ID == s.id && echo.Seq == seq {
				return rtt, nil
			}
		}
	}

	// 处理其他 ICMP 消息（如 Time Exceeded）
	return 0, fmt.Errorf("unexpected reply from %v: %v", peer, rm.Type)
}
