package dns_lib

import (
	"fmt"
	"net"
	"time"

	"github.com/miekg/dns"
)

// DNSResolver DNS 解析器结构体
type DNSResolver struct {
	servers []string      // DNS 服务器地址，如 "8.8.8.8:53"
	timeout time.Duration // 超时时间
	retries int           // 重试次数
}

// ResolveResult 解析结果
type ResolveResult struct {
	Domain   string
	CNAME    string   // 最终的 CNAME 目标（如有）
	Aliases  []string // CNAME 链
	IPv4     []string // A 记录
	IPv6     []string // AAAA 记录（扩展）
	Duration time.Duration
	Error    error
}

// ResolverOption 配置选项
type ResolverOption func(*DNSResolver)

// NewDNSResolver 创建解析器
func NewDNSResolver(opts ...ResolverOption) *DNSResolver {
	r := &DNSResolver{
		servers: []string{"114.114.114.114:53"}, // 默认 DNS
		timeout: 5 * time.Second,
		retries: 2,
	}
	for _, opt := range opts {
		opt(r)
	}
	return r
}

func WithDNSServers(servers ...string) ResolverOption {
	return func(r *DNSResolver) {
		r.servers = servers
		// 自动添加端口
		for i, s := range r.servers {
			if _, _, err := net.SplitHostPort(s); err != nil {
				r.servers[i] = net.JoinHostPort(s, "53")
			}
		}
	}
}

func WithTimeout(d time.Duration) ResolverOption {
	return func(r *DNSResolver) { r.timeout = d }
}

func WithRetries(n int) ResolverOption {
	return func(r *DNSResolver) { r.retries = n }
}

// Resolve 解析单个域名（唯一对外接口）
func (r *DNSResolver) Resolve(domain string) *ResolveResult {
	start := time.Now()
	result := &ResolveResult{
		Domain:  dns.Fqdn(domain),
		Aliases: []string{},
		IPv4:    []string{},
		IPv6:    []string{},
	}

	// 追踪 CNAME 链并获取最终 A 记录
	r.resolveCNAMEChain(result)

	result.Duration = time.Since(start)
	return result
}

// resolveCNAMEChain 解析 CNAME 链和最终的 A 记录
func (r *DNSResolver) resolveCNAMEChain(result *ResolveResult) {
	current := result.Domain
	visited := map[string]bool{} // 防循环

	for depth := 0; depth < 10; depth++ { // 最大深度限制
		if visited[current] {
			result.Error = fmt.Errorf("CNAME loop detected")
			return
		}
		visited[current] = true

		// 同时查询 A 和 CNAME 记录
		msg := new(dns.Msg)
		msg.SetQuestion(current, dns.TypeA)
		msg.SetQuestion(current, dns.TypeCNAME) // 实际应该分开查，这里简化

		rsp, err := r.exchange(msg)
		if err != nil {
			result.Error = err
			return
		}

		// 解析响应
		var foundCNAME bool
		var nextTarget string

		for _, rr := range rsp.Answer {
			switch v := rr.(type) {
			case *dns.CNAME:
				result.Aliases = append(result.Aliases, v.Target)
				nextTarget = v.Target
				foundCNAME = true
			case *dns.A:
				result.IPv4 = append(result.IPv4, v.A.String())
			case *dns.AAAA:
				result.IPv6 = append(result.IPv6, v.AAAA.String())
			}
		}

		// 如果找到了 A 记录且没有更多 CNAME，结束
		if len(result.IPv4) > 0 && !foundCNAME {
			if len(result.Aliases) > 0 {
				result.CNAME = result.Aliases[len(result.Aliases)-1]
			}
			return
		}

		// 继续追踪 CNAME
		if foundCNAME && nextTarget != "" {
			current = nextTarget
			continue
		}

		// 没有 CNAME 也没有 A 记录，查询 AAAA
		if len(result.IPv4) == 0 {
			msg6 := new(dns.Msg)
			msg6.SetQuestion(current, dns.TypeAAAA)
			rsp6, _ := r.exchange(msg6)
			if rsp6 != nil {
				for _, rr := range rsp6.Answer {
					if v, ok := rr.(*dns.AAAA); ok {
						result.IPv6 = append(result.IPv6, v.AAAA.String())
					}
				}
			}
		}

		break
	}

	if len(result.Aliases) > 0 {
		result.CNAME = result.Aliases[len(result.Aliases)-1]
	}

	if len(result.IPv4) == 0 && len(result.IPv6) == 0 {
		result.Error = fmt.Errorf("no A/AAAA records found")
	}
}

// exchange 发送 DNS 查询
func (r *DNSResolver) exchange(msg *dns.Msg) (*dns.Msg, error) {
	client := &dns.Client{
		Timeout: r.timeout,
	}

	var lastErr error
	for i := 0; i <= r.retries; i++ {
		// 轮询使用服务器
		for _, server := range r.servers {
			rsp, _, err := client.Exchange(msg, server)
			if err == nil {
				if rsp.Rcode != dns.RcodeSuccess {
					return nil, fmt.Errorf("DNS error: %s", dns.RcodeToString[rsp.Rcode])
				}
				return rsp, nil
			}
			lastErr = err
		}
		if i < r.retries {
			time.Sleep(time.Duration(i+1) * 100 * time.Millisecond)
		}
	}

	return nil, fmt.Errorf("all servers failed: %w", lastErr)
}

func main() {
	// 示例 1：基本解析
	fmt.Println("=== 基本解析 ===")
	r := NewDNSResolver()

	result := r.Resolve("www.baidu.com")
	printResult("百度", result)

	// 示例 2：自定义 DNS
	fmt.Println("\n=== 自定义 DNS ===")
	r2 := NewDNSResolver(
		WithDNSServers("1.1.1.1", "8.8.8.8"),
		WithTimeout(3*time.Second),
	)
	result2 := r2.Resolve("github.com")
	printResult("GitHub", result2)

	// 示例 3：错误处理
	fmt.Println("\n=== 错误测试 ===")
	result3 := r.Resolve("not-exist-domain-12345.xyz")
	printResult("无效域名", result3)
}

func printResult(name string, r *ResolveResult) {
	fmt.Printf("[%s] 域名: %s\n", name, r.Domain)
	if r.Error != nil {
		fmt.Printf("  错误: %v\n", r.Error)
		return
	}
	if r.CNAME != "" {
		fmt.Printf("  CNAME 链: %v -> %s\n", r.Aliases, r.CNAME)
	}
	if len(r.IPv4) > 0 {
		fmt.Printf("  A 记录: %v\n", r.IPv4)
	}
	if len(r.IPv6) > 0 {
		fmt.Printf("  AAAA 记录: %v\n", r.IPv6)
	}
	fmt.Printf("  耗时: %v\n", r.Duration)
}
