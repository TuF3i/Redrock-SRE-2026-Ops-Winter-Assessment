package web_lib

import (
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"
)

// HTTPChecker HTTP 检测器结构体
type HTTPChecker struct {
	timeout        time.Duration
	method         string
	followRedirect bool
	skipTLSVerify  bool
	headers        map[string]string
}

// CheckResult 检测结果
type CheckResult struct {
	URL        string
	Available  bool
	StatusCode int
	TotalTime  time.Duration
	Title      string // 网页标题
	Error      error
}

// CheckerOption 配置选项
type CheckerOption func(*HTTPChecker)

// NewHTTPChecker 创建检测器
func NewHTTPChecker(opts ...CheckerOption) *HTTPChecker {
	c := &HTTPChecker{
		timeout:        10 * time.Second,
		method:         "GET",
		followRedirect: true,
		skipTLSVerify:  false,
		headers: map[string]string{
			"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
		},
	}
	for _, opt := range opts {
		opt(c)
	}
	return c
}

func WithTimeout(d time.Duration) CheckerOption {
	return func(c *HTTPChecker) { c.timeout = d }
}

func WithMethod(m string) CheckerOption {
	return func(c *HTTPChecker) { c.method = m }
}

func NoRedirect() CheckerOption {
	return func(c *HTTPChecker) { c.followRedirect = false }
}

func SkipTLSVerify() CheckerOption {
	return func(c *HTTPChecker) { c.skipTLSVerify = true }
}

func WithHeader(key, value string) CheckerOption {
	return func(c *HTTPChecker) { c.headers[key] = value }
}

// Check 检测单个 URL（唯一对外接口）
func (c *HTTPChecker) Check(url string) *CheckResult {
	result := &CheckResult{
		URL:   url,
		Title: "unknown",
	}

	ctx, cancel := context.WithTimeout(context.Background(), c.timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, c.method, url, nil)
	if err != nil {
		result.Error = fmt.Errorf("create request failed: %w", err)
		return result
	}

	for k, v := range c.headers {
		req.Header.Set(k, v)
	}

	transport := &http.Transport{
		TLSClientConfig: &tls.Config{
			InsecureSkipVerify: c.skipTLSVerify,
		},
	}

	client := &http.Client{
		Transport: transport,
		Timeout:   c.timeout,
	}
	if !c.followRedirect {
		client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		}
	}

	start := time.Now()
	resp, err := client.Do(req)
	result.TotalTime = time.Since(start)

	if err != nil {
		result.Error = fmt.Errorf("request failed: %w", err)
		return result
	}
	defer resp.Body.Close()

	result.StatusCode = resp.StatusCode
	result.Available = resp.StatusCode >= 200 && resp.StatusCode < 400

	// 获取 Title
	if result.Available {
		result.Title = c.extractTitle(resp)
	}

	return result
}

// extractTitle 从 HTML 中提取 title
func (c *HTTPChecker) extractTitle(resp *http.Response) string {
	// 只读取前 8KB，避免大页面
	limit := int64(8192)
	body, err := io.ReadAll(io.LimitReader(resp.Body, limit))
	if err != nil {
		return "unknown"
	}

	// 正则匹配 title
	re := regexp.MustCompile(`(?i)<title[^>]*>([^<]*)</title>`)
	matches := re.FindSubmatch(body)
	if len(matches) > 1 {
		title := strings.TrimSpace(string(matches[1]))
		// 清理空白字符
		title = strings.Join(strings.Fields(title), " ")
		if len(title) > 100 {
			title = title[:100] + "..."
		}
		if title != "" {
			return title
		}
	}

	return "unknown"
}
