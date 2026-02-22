package web_scanner

import (
	"redrock-dashboard/core/pkg/scanner/web_scanner/playwright_lib"
	"redrock-dashboard/core/pkg/scanner/web_scanner/web_lib"
	"time"
)

type TCPScanResult struct {
	TimeDelay  time.Duration
	Accessible bool
	Screenshot string
}

type WebScanner struct {
	Dest string
}

func (r WebScanner) Scan() (*TCPScanResult, error) {
	requester := web_lib.NewHTTPChecker(web_lib.WithTimeout(5 * time.Second))
	screenShotter := playwright_lib.NewScreenshotter(playwright_lib.WithTimeout(15 * time.Second))

	result := requester.Check(r.Dest)
	if result.Error != nil {
		return nil, result.Error
	}

	data := &TCPScanResult{
		TimeDelay:  result.TotalTime,
		Accessible: result.Available,
	}

	screen := screenShotter.Screenshot(r.Dest)
	if screen.Error != nil {
		// TODO Log
		return data, nil
	}
	data.Screenshot = screen.Base64

	return data, nil
}
