package main

import (
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"syscall"
	"unsafe"
)

var (
	gdi32                  = syscall.NewLazyDLL("gdi32.dll")
	createCompatibleDC     = gdi32.NewProc("CreateCompatibleDC")
	createCompatibleBitmap = gdi32.NewProc("CreateCompatibleBitmap")
	selectObject           = gdi32.NewProc("SelectObject")
	bitBlt                 = gdi32.NewProc("BitBlt")
	getDIBits              = gdi32.NewProc("GetDIBits")
	setDIBits              = gdi32.NewProc("SetDIBits")
	deleteObject           = gdi32.NewProc("DeleteObject")
	deleteDC               = gdi32.NewProc("DeleteDC")
	createSolidBrush       = gdi32.NewProc("CreateSolidBrush")
	setBkMode              = gdi32.NewProc("SetBkMode")
	setTextColor           = gdi32.NewProc("SetTextColor")
	getDC                  = user32.NewProc("GetDC")
	releaseDC              = user32.NewProc("ReleaseDC")
	getSystemMetrics       = user32.NewProc("GetSystemMetrics")
	registerClassExW       = user32.NewProc("RegisterClassExW")
	createWindowExW        = user32.NewProc("CreateWindowExW")
	showWindow             = user32.NewProc("ShowWindow")
	updateWindow           = user32.NewProc("UpdateWindow")
	setForegroundWindow    = user32.NewProc("SetForegroundWindow")
	destroyWindow          = user32.NewProc("DestroyWindow")
	defWindowProcW         = user32.NewProc("DefWindowProcW")
	getMessageW            = user32.NewProc("GetMessageW")
	translateMessage       = user32.NewProc("TranslateMessage")
	dispatchMessageW       = user32.NewProc("DispatchMessageW")
	postQuitMessage        = user32.NewProc("PostQuitMessage")
	invalidateRect         = user32.NewProc("InvalidateRect")
	beginPaint             = user32.NewProc("BeginPaint")
	endPaint               = user32.NewProc("EndPaint")
	setCapture             = user32.NewProc("SetCapture")
	releaseCapture         = user32.NewProc("ReleaseCapture")
	loadCursorW            = user32.NewProc("LoadCursorW")
	fillRect               = user32.NewProc("FillRect")
	frameRect              = user32.NewProc("FrameRect")
	drawTextW              = user32.NewProc("DrawTextW")
	getModuleHandleW       = kernel32.NewProc("GetModuleHandleW")
)

type wndClassExW struct {
	cbSize        uint32
	style         uint32
	lpfnWndProc   uintptr
	cbClsExtra    int32
	cbWndExtra    int32
	hInstance     uintptr
	hIcon         uintptr
	hCursor       uintptr
	hbrBackground uintptr
	lpszMenuName  uintptr
	lpszClassName uintptr
	hIconSm       uintptr
}

type paintStruct struct {
	hdc        uintptr
	fErase     int32
	rcPaint    winRect
	fRestore   int32
	fIncUpdate int32
	reserved   [32]byte
}

type winMsg struct {
	hwnd     uintptr
	message  uint32
	wParam   uintptr
	lParam   uintptr
	time     uint32
	pt       [2]int32
	lPrivate uint32
}

type bitmapInfoHeader struct {
	biSize          uint32
	biWidth         int32
	biHeight        int32
	biPlanes        uint16
	biBitCount      uint16
	biCompression   uint32
	biSizeImage     uint32
	biXPelsPerMeter int32
	biYPelsPerMeter int32
	biClrUsed       uint32
	biClrImportant  uint32
}

type snipSession struct {
	vx, vy, vw, vh int
	origPixels     []byte
	hOrigBmp       uintptr
	hDimBmp        uintptr
	hSrcDC         uintptr
	hBackDC        uintptr
	hBackBmp       uintptr
	hBorderBrush   uintptr
	hBadgeBrush    uintptr
	dragging       bool
	startX, startY int
	curX, curY     int
	capturedPNG    []byte
}

var (
	snipActive    atomic.Bool
	snipClassOnce sync.Once
	snipClassErr  error
	currentSnip   *snipSession
	snipProcPtr   = syscall.NewCallback(snipWndProc)
)

func ensureSnipClass(hInst uintptr) error {
	snipClassOnce.Do(func() {
		name, err := syscall.UTF16PtrFromString("ConectorSnipOverlay")
		if err != nil {
			snipClassErr = err
			return
		}
		cursor, _, _ := loadCursorW.Call(0, 32515) // IDC_CROSS
		wc := wndClassExW{
			cbSize:        uint32(unsafe.Sizeof(wndClassExW{})),
			style:         0x0003, // CS_VREDRAW | CS_HREDRAW
			lpfnWndProc:   snipProcPtr,
			hInstance:     hInst,
			hCursor:       cursor,
			lpszClassName: uintptr(unsafe.Pointer(name)),
		}
		atom, _, regErr := registerClassExW.Call(uintptr(unsafe.Pointer(&wc)))
		if atom == 0 {
			snipClassErr = fmt.Errorf("RegisterClassExW(ConectorSnipOverlay): %v", regErr)
		}
	})
	return snipClassErr
}

func startSnipOverlay(onCaptured func([]byte)) {
	if !snipActive.CompareAndSwap(false, true) {
		return
	}
	go func() {
		defer snipActive.Store(false)
		defer cursorDPI()()

		vx := int(getSystemMetricsInt(76)) // SM_XVIRTUALSCREEN
		vy := int(getSystemMetricsInt(77)) // SM_YVIRTUALSCREEN
		vw := int(getSystemMetricsInt(78)) // SM_CXVIRTUALSCREEN
		vh := int(getSystemMetricsInt(79)) // SM_CYVIRTUALSCREEN
		if vw <= 0 || vh <= 0 {
			return
		}

		screenDC, _, _ := getDC.Call(0)
		if screenDC == 0 {
			return
		}
		defer releaseDC.Call(0, screenDC)

		hSrcDC, _, _ := createCompatibleDC.Call(screenDC)
		if hSrcDC == 0 {
			return
		}
		defer deleteDC.Call(hSrcDC)

		hBackDC, _, _ := createCompatibleDC.Call(screenDC)
		if hBackDC == 0 {
			return
		}
		defer deleteDC.Call(hBackDC)

		hOrigBmp, _, _ := createCompatibleBitmap.Call(screenDC, uintptr(vw), uintptr(vh))
		if hOrigBmp == 0 {
			return
		}
		defer deleteObject.Call(hOrigBmp)

		hDimBmp, _, _ := createCompatibleBitmap.Call(screenDC, uintptr(vw), uintptr(vh))
		if hDimBmp == 0 {
			return
		}
		defer deleteObject.Call(hDimBmp)

		hBackBmp, _, _ := createCompatibleBitmap.Call(screenDC, uintptr(vw), uintptr(vh))
		if hBackBmp == 0 {
			return
		}
		defer deleteObject.Call(hBackBmp)

		oldSrc, _, _ := selectObject.Call(hSrcDC, hOrigBmp)
		bitBlt.Call(hSrcDC, 0, 0, uintptr(vw), uintptr(vh), screenDC, uintptr(vx), uintptr(vy), 0x00CC0020) // SRCCOPY
		selectObject.Call(hSrcDC, oldSrc)

		bmi := bitmapInfoHeader{
			biSize:        uint32(unsafe.Sizeof(bitmapInfoHeader{})),
			biWidth:       int32(vw),
			biHeight:      -int32(vh), // top-down
			biPlanes:      1,
			biBitCount:    32,
			biCompression: 0,
		}
		origPixels := make([]byte, vw*vh*4)
		getDIBits.Call(screenDC, hOrigBmp, 0, uintptr(vh), uintptr(unsafe.Pointer(&origPixels[0])), uintptr(unsafe.Pointer(&bmi)), 0)

		dimPixels := make([]byte, len(origPixels))
		for i := 0; i < len(origPixels); i += 4 {
			dimPixels[i] = origPixels[i] / 2
			dimPixels[i+1] = origPixels[i+1] / 2
			dimPixels[i+2] = origPixels[i+2] / 2
			dimPixels[i+3] = 255
		}
		setDIBits.Call(screenDC, hDimBmp, 0, uintptr(vh), uintptr(unsafe.Pointer(&dimPixels[0])), uintptr(unsafe.Pointer(&bmi)), 0)

		oldBack, _, _ := selectObject.Call(hBackDC, hBackBmp)
		defer selectObject.Call(hBackDC, oldBack)

		hBorderBrush, _, _ := createSolidBrush.Call(0x00F6823B) // #3B82F6
		defer deleteObject.Call(hBorderBrush)
		hBadgeBrush, _, _ := createSolidBrush.Call(0x00281E14)
		defer deleteObject.Call(hBadgeBrush)

		hInst, _, _ := getModuleHandleW.Call(0)
		if err := ensureSnipClass(hInst); err != nil {
			log.Printf("snip class: %v", err)
			return
		}
		className, _ := syscall.UTF16PtrFromString("ConectorSnipOverlay")
		winTitle, _ := syscall.UTF16PtrFromString("Conector Snip")

		sess := &snipSession{
			vx: vx, vy: vy, vw: vw, vh: vh,
			origPixels:   origPixels,
			hOrigBmp:     hOrigBmp,
			hDimBmp:      hDimBmp,
			hSrcDC:       hSrcDC,
			hBackDC:      hBackDC,
			hBackBmp:     hBackBmp,
			hBorderBrush: hBorderBrush,
			hBadgeBrush:  hBadgeBrush,
		}
		currentSnip = sess
		defer func() { currentSnip = nil }()

		const (
			wsExTopmost    = 0x00000008
			wsExToolWindow = 0x00000080
			wsPopup        = 0x80000000
			wsVisible      = 0x10000000
		)
		hwnd, _, err := createWindowExW.Call(
			wsExTopmost|wsExToolWindow,
			uintptr(unsafe.Pointer(className)),
			uintptr(unsafe.Pointer(winTitle)),
			wsPopup|wsVisible,
			uintptr(vx), uintptr(vy), uintptr(vw), uintptr(vh),
			0, 0, hInst, 0,
		)
		if hwnd == 0 {
			log.Printf("snip CreateWindowExW: %v", err)
			return
		}
		showWindow.Call(hwnd, 5) // SW_SHOW
		updateWindow.Call(hwnd)
		setForegroundWindow.Call(hwnd)

		var msg winMsg
		for {
			ret, _, _ := getMessageW.Call(uintptr(unsafe.Pointer(&msg)), 0, 0, 0)
			if int32(ret) <= 0 {
				break
			}
			translateMessage.Call(uintptr(unsafe.Pointer(&msg)))
			dispatchMessageW.Call(uintptr(unsafe.Pointer(&msg)))
		}

		if len(sess.capturedPNG) > 0 && onCaptured != nil {
			onCaptured(sess.capturedPNG)
		}
	}()
}

func getSystemMetricsInt(idx int) int32 {
	v, _, _ := getSystemMetrics.Call(uintptr(idx))
	return int32(v)
}

func drawTextLine(hdc uintptr, text string, rc *winRect) {
	u16, err := syscall.UTF16FromString(text)
	if err != nil {
		return
	}
	setBkMode.Call(hdc, 1) // TRANSPARENT
	setTextColor.Call(hdc, 0x00FFFFFF)
	drawTextW.Call(hdc, uintptr(unsafe.Pointer(&u16[0])), uintptr(len(u16)-1), uintptr(unsafe.Pointer(rc)), 0x0825) // DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX
}

func snipWndProc(hwnd, msg, wParam, lParam uintptr) uintptr {
	sess := currentSnip
	if sess == nil {
		r, _, _ := defWindowProcW.Call(hwnd, msg, wParam, lParam)
		return r
	}
	switch msg {
	case 0x0014: // WM_ERASEBKGND
		return 1
	case 0x000F: // WM_PAINT
		var ps paintStruct
		hdc, _, _ := beginPaint.Call(hwnd, uintptr(unsafe.Pointer(&ps)))
		if hdc != 0 {
			oldSrc, _, _ := selectObject.Call(sess.hSrcDC, sess.hDimBmp)
			bitBlt.Call(sess.hBackDC, 0, 0, uintptr(sess.vw), uintptr(sess.vh), sess.hSrcDC, 0, 0, 0x00CC0020)

			if sess.dragging {
				l, t, r, b := normalizeRect(sess.startX, sess.startY, sess.curX, sess.curY, sess.vw, sess.vh)
				if r-l >= 2 && b-t >= 2 {
					selectObject.Call(sess.hSrcDC, sess.hOrigBmp)
					bitBlt.Call(sess.hBackDC, uintptr(l), uintptr(t), uintptr(r-l), uintptr(b-t), sess.hSrcDC, uintptr(l), uintptr(t), 0x00CC0020)
					rc := winRect{left: int32(l), top: int32(t), right: int32(r), bottom: int32(b)}
					frameRect.Call(sess.hBackDC, uintptr(unsafe.Pointer(&rc)), sess.hBorderBrush)
					if r-l > 2 && b-t > 2 {
						rc2 := winRect{left: int32(l + 1), top: int32(t + 1), right: int32(r - 1), bottom: int32(b - 1)}
						frameRect.Call(sess.hBackDC, uintptr(unsafe.Pointer(&rc2)), sess.hBorderBrush)
					}
					badgeTop := t - 28
					if badgeTop < 4 {
						badgeTop = t + 6
					}
					badge := winRect{left: int32(l), top: int32(badgeTop), right: int32(l + 110), bottom: int32(badgeTop + 24)}
					fillRect.Call(sess.hBackDC, uintptr(unsafe.Pointer(&badge)), sess.hBadgeBrush)
					drawTextLine(sess.hBackDC, fmt.Sprintf("%d × %d", r-l, b-t), &badge)
				}
			} else {
				pw := int(getSystemMetricsInt(0)) // SM_CXSCREEN
				cx := -sess.vx + pw/2
				hint := winRect{left: int32(cx - 240), top: int32(-sess.vy + 18), right: int32(cx + 240), bottom: int32(-sess.vy + 52)}
				fillRect.Call(sess.hBackDC, uintptr(unsafe.Pointer(&hint)), sess.hBadgeBrush)
				frameRect.Call(sess.hBackDC, uintptr(unsafe.Pointer(&hint)), sess.hBorderBrush)
				drawTextLine(sess.hBackDC, "Выделите область мышью • Пробел — экран • Esc — отмена", &hint)
			}

			selectObject.Call(sess.hSrcDC, oldSrc)
			bitBlt.Call(hdc, 0, 0, uintptr(sess.vw), uintptr(sess.vh), sess.hBackDC, 0, 0, 0x00CC0020)
			endPaint.Call(hwnd, uintptr(unsafe.Pointer(&ps)))
		}
		return 0
	case 0x0201: // WM_LBUTTONDOWN
		x := int(int16(lParam & 0xffff))
		y := int(int16((lParam >> 16) & 0xffff))
		sess.startX, sess.startY = x, y
		sess.curX, sess.curY = x, y
		sess.dragging = true
		setCapture.Call(hwnd)
		invalidateRect.Call(hwnd, 0, 0)
		return 0
	case 0x0200: // WM_MOUSEMOVE
		if sess.dragging {
			sess.curX = int(int16(lParam & 0xffff))
			sess.curY = int(int16((lParam >> 16) & 0xffff))
			invalidateRect.Call(hwnd, 0, 0)
		}
		return 0
	case 0x0202: // WM_LBUTTONUP
		if sess.dragging {
			sess.dragging = false
			releaseCapture.Call()
			x := int(int16(lParam & 0xffff))
			y := int(int16((lParam >> 16) & 0xffff))
			l, t, r, b := normalizeRect(sess.startX, sess.startY, x, y, sess.vw, sess.vh)
			if r-l >= 4 && b-t >= 4 {
				if pngBytes, err := encodeBGRACropToPNG(sess.origPixels, sess.vw, sess.vh, l, t, r, b); err == nil {
					sess.capturedPNG = pngBytes
				} else {
					log.Printf("snip encode: %v", err)
				}
			}
			destroyWindow.Call(hwnd)
		}
		return 0
	case 0x0204: // WM_RBUTTONDOWN
		destroyWindow.Call(hwnd)
		return 0
	case 0x0100: // WM_KEYDOWN
		switch wParam {
		case 0x1B: // VK_ESCAPE
			destroyWindow.Call(hwnd)
			return 0
		case 0x20, 0x0D: // VK_SPACE, VK_RETURN -> capture active monitor
			var pt [2]int32
			if ok, _, _ := getCursorPos.Call(uintptr(unsafe.Pointer(&pt))); ok != 0 {
				probe := winRect{left: pt[0], top: pt[1], right: pt[0] + 1, bottom: pt[1] + 1}
				if mon, _, _ := monitorFromRect.Call(uintptr(unsafe.Pointer(&probe)), 2); mon != 0 {
					var mi monitorInfo
					mi.size = uint32(unsafe.Sizeof(mi))
					if ok2, _, _ := getMonitorInfoW.Call(mon, uintptr(unsafe.Pointer(&mi))); ok2 != 0 {
						if pngBytes, err := encodeBGRACropToPNG(
							sess.origPixels, sess.vw, sess.vh,
							int(mi.monitor.left)-sess.vx, int(mi.monitor.top)-sess.vy,
							int(mi.monitor.right)-sess.vx, int(mi.monitor.bottom)-sess.vy,
						); err == nil {
							sess.capturedPNG = pngBytes
						}
					}
				}
			}
			destroyWindow.Call(hwnd)
			return 0
		}
	case 0x0002: // WM_DESTROY
		postQuitMessage.Call(0)
		return 0
	}
	r, _, _ := defWindowProcW.Call(hwnd, msg, wParam, lParam)
	return r
}
