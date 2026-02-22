package playwright_lib

import (
	"context"
	"encoding/base64"
	"fmt"
	"time"

	"github.com/playwright-community/playwright-go"
)

// Screenshotter 截图器结构体
type Screenshotter struct {
	timeout   time.Duration
	width     int
	height    int
	fullPage  bool
	waitUntil string // load, domcontentloaded, networkidle
}

// ScreenshotResult 截图结果
type ScreenshotResult struct {
	Base64 string // data:image/png;base64,xxx
	Error  error
}

// ScreenshotterOption 配置选项
type ScreenshotterOption func(*Screenshotter)

// NewScreenshotter 创建截图器
func NewScreenshotter(opts ...ScreenshotterOption) *Screenshotter {
	s := &Screenshotter{
		timeout:   30 * time.Second,
		width:     1920,
		height:    1080,
		fullPage:  true,
		waitUntil: "networkidle",
	}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

func WithTimeout(d time.Duration) ScreenshotterOption {
	return func(s *Screenshotter) { s.timeout = d }
}

func WithViewport(width, height int) ScreenshotterOption {
	return func(s *Screenshotter) {
		s.width = width
		s.height = height
	}
}

func WithoutFullPage() ScreenshotterOption {
	return func(s *Screenshotter) { s.fullPage = false }
}

func WithWaitUntil(state string) ScreenshotterOption {
	return func(s *Screenshotter) { s.waitUntil = state }
}

// Screenshot 截图单个 URL（唯一对外接口）
func (s *Screenshotter) Screenshot(url string) *ScreenshotResult {
	result := &ScreenshotResult{}

	// 创建 context 控制超时
	ctx, cancel := context.WithTimeout(context.Background(), s.timeout)
	defer cancel()

	// 启动 Playwright
	pw, err := playwright.Run()
	if err != nil {
		result.Error = fmt.Errorf("start playwright failed: %w", err)
		return result
	}
	defer pw.Stop()

	// 启动浏览器
	browser, err := pw.Chromium.Launch(playwright.BrowserTypeLaunchOptions{
		Headless: playwright.Bool(true),
	})
	if err != nil {
		result.Error = fmt.Errorf("launch browser failed: %w", err)
		return result
	}
	defer browser.Close()

	// 创建页面
	page, err := browser.NewPage(playwright.BrowserNewPageOptions{
		Viewport: &playwright.Size{
			Width:  s.width,
			Height: s.height,
		},
	})
	if err != nil {
		result.Error = fmt.Errorf("new page failed: %w", err)
		return result
	}

	// 导航到目标页面
	_, err = page.Goto(url, playwright.PageGotoOptions{
		Timeout: playwright.Float(float64(s.timeout.Milliseconds())),
	})
	if err != nil {
		result.Error = fmt.Errorf("goto url failed: %w", err)
		return result
	}

	// 等待额外一点时间确保渲染完成
	select {
	case <-ctx.Done():
		result.Error = fmt.Errorf("screenshot timeout")
		return result
	case <-time.After(500 * time.Millisecond):
	}

	// 截图
	screenshotOptions := playwright.PageScreenshotOptions{
		Type: playwright.ScreenshotTypePng,
	}
	if s.fullPage {
		screenshotOptions.FullPage = playwright.Bool(true)
	}

	imageBytes, err := page.Screenshot(screenshotOptions)
	if err != nil {
		result.Error = fmt.Errorf("screenshot failed: %w", err)
		return result
	}

	// 编码为 base64 并拼接前缀
	base64Str := base64.StdEncoding.EncodeToString(imageBytes)
	result.Base64 = "data:image/png;base64," + base64Str

	return result
}

// ScreenshotSimple 简化接口，只返回 base64 和 error
func (s *Screenshotter) ScreenshotSimple(url string) (string, error) {
	result := s.Screenshot(url)
	return result.Base64, result.Error
}
