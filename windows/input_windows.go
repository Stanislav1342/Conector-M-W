package main

import (
	"fmt"
	"runtime"
	"syscall"
	"unsafe"
)

var user32 = syscall.NewLazyDLL("user32.dll")
var sendInput = user32.NewProc("SendInput")
var getCursorPos = user32.NewProc("GetCursorPos")
var setCursorPos = user32.NewProc("SetCursorPos")
var monitorFromRect = user32.NewProc("MonitorFromRect")
var getMonitorInfoW = user32.NewProc("GetMonitorInfoW")
var setThreadDPI = user32.NewProc("SetThreadDpiAwarenessContext")

func setDPIAware() {
	user32.NewProc("SetProcessDPIAware").Call()
}

// Cursor coordinates must agree even when hosted by a DPI-unaware Python process.
func cursorDPI() func() {
	if setThreadDPI.Find() != nil {
		return func() {}
	}
	runtime.LockOSThread()
	previous, _, _ := setThreadDPI.Call(^uintptr(3)) // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4.
	return func() {
		if previous != 0 {
			setThreadDPI.Call(previous)
		}
		runtime.UnlockOSThread()
	}
}

type winRect struct {
	left, top, right, bottom int32
}

type monitorInfo struct {
	size    uint32
	monitor winRect
	work    winRect
	flags   uint32
}

// pointAtBottom reports whether (x, y) rests on the bottom edge of its monitor
// and no other Windows monitor lies directly below it. Caller must hold cursorDPI().
func pointAtBottom(x, y int32) bool {
	const (
		monitorDefaultToNull    = 0
		monitorDefaultToNearest = 2
	)
	probe := winRect{left: x, top: y, right: x + 1, bottom: y + 1}
	mon, _, _ := monitorFromRect.Call(uintptr(unsafe.Pointer(&probe)), monitorDefaultToNearest)
	if mon == 0 {
		return false
	}
	var mi monitorInfo
	mi.size = uint32(unsafe.Sizeof(mi))
	ok, _, _ := getMonitorInfoW.Call(mon, uintptr(unsafe.Pointer(&mi)))
	if ok == 0 || y < mi.monitor.bottom-1 {
		return false
	}
	below := winRect{left: x, top: mi.monitor.bottom, right: x + 1, bottom: mi.monitor.bottom + 1}
	nextMon, _, _ := monitorFromRect.Call(uintptr(unsafe.Pointer(&below)), monitorDefaultToNull)
	return nextMon == 0
}

func atBottom() bool {
	defer cursorDPI()()
	var point [2]int32
	ok, _, _ := getCursorPos.Call(uintptr(unsafe.Pointer(&point)))
	if ok == 0 {
		return false
	}
	return pointAtBottom(point[0], point[1])
}

// The union is sized and aligned by MOUSEINPUT on 64-bit Windows.
type mouseInput struct {
	x, y              int32
	data, flags, time uint32
	extra             uintptr
}
type input struct {
	kind  uint32
	mouse mouseInput
}
type keyboardInput struct {
	virtualKey, scanCode uint16
	flags, time          uint32
	extra                uintptr
}

var mouseButtons = [3][2]uint32{{4, 2}, {16, 8}, {64, 32}}

func inject(i *input) error {
	count, _, err := sendInput.Call(1, uintptr(unsafe.Pointer(i)), unsafe.Sizeof(*i))
	if count != 1 {
		return fmt.Errorf("SendInput failed: %v", err)
	}
	return nil
}

func moveCursor(x, y int32) error {
	ok, _, err := setCursorPos.Call(uintptr(x), uintptr(y))
	if ok == 0 {
		return fmt.Errorf("SetCursorPos failed: %v", err)
	}
	return nil
}

func (e event) send() error {
	i := input{}
	switch e.Kind {
	case "enter":
		defer cursorDPI()()
		var point [2]int32
		if ok, _, err := getCursorPos.Call(uintptr(unsafe.Pointer(&point))); ok == 0 {
			return fmt.Errorf("GetCursorPos failed: %v", err)
		}
		if pointAtBottom(point[0], point[1]) {
			return moveCursor(point[0], point[1]-4)
		}
		return nil
	case "move":
		defer cursorDPI()()
		var point [2]int32
		if ok, _, err := getCursorPos.Call(uintptr(unsafe.Pointer(&point))); ok == 0 {
			return fmt.Errorf("GetCursorPos failed: %v", err)
		}
		return moveCursor(point[0]+e.X, point[1]+e.Y)
	case "scroll":
		if e.Y != 0 {
			i.mouse = mouseInput{data: uint32(e.Y), flags: 0x0800}
			if err := inject(&i); err != nil {
				return err
			}
		}
		if e.X == 0 {
			return nil
		}
		i.mouse = mouseInput{data: uint32(e.X), flags: 0x1000}
	case "button":
		index := 0
		if e.Down {
			index = 1
		}
		i.mouse.flags = mouseButtons[e.Code][index]
	case "key":
		i.kind = 1
		k := (*keyboardInput)(unsafe.Pointer(&i.mouse))
		k.scanCode = e.Code & 0xff
		k.flags = 8
		if e.Code&0x100 != 0 {
			k.flags |= 1
		}
		if !e.Down {
			k.flags |= 2
		}
	}
	return inject(&i)
}
