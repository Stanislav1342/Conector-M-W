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
var getSystemMetrics = user32.NewProc("GetSystemMetrics")
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

func atBottom() bool {
	defer cursorDPI()()
	var point [2]int32
	ok, _, _ := getCursorPos.Call(uintptr(unsafe.Pointer(&point)))
	height, _, _ := getSystemMetrics.Call(1)
	return ok != 0 && point[1] >= int32(height)-1
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
		width, _, _ := getSystemMetrics.Call(0)
		height, _, _ := getSystemMetrics.Call(1)
		x := int32(int64(e.X) * int64(width-1) / 65535)
		y := max(0, int32(height)-20)
		return moveCursor(x, y)
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
