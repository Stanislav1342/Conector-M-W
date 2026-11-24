package main

type shortcutKey struct {
	vk       uint16
	scan     uint16
	extended bool
}

var shortcutCombos = map[string][]shortcutKey{
	"desktopNext": {
		{vk: 0xA2, scan: 0x1D},                 // LCtrl
		{vk: 0x5B, scan: 0x5B, extended: true}, // LWin
		{vk: 0x27, scan: 0x4D, extended: true}, // Right
	},
	"desktopPrev": {
		{vk: 0xA2, scan: 0x1D},                 // LCtrl
		{vk: 0x5B, scan: 0x5B, extended: true}, // LWin
		{vk: 0x25, scan: 0x4B, extended: true}, // Left
	},
	"taskView": {
		{vk: 0x5B, scan: 0x5B, extended: true}, // LWin
		{vk: 0x09, scan: 0x0F},                 // Tab
	},
	"showDesktop": {
		{vk: 0x5B, scan: 0x5B, extended: true}, // LWin
		{vk: 0x44, scan: 0x20},                 // D
	},
	"switchAppNext": {
		{vk: 0xA4, scan: 0x38}, // LAlt
		{vk: 0x09, scan: 0x0F}, // Tab
	},
	"switchAppPrev": {
		{vk: 0xA4, scan: 0x38}, // LAlt
		{vk: 0xA0, scan: 0x2A}, // LShift
		{vk: 0x09, scan: 0x0F}, // Tab
	},
	"browserForward": {
		{vk: 0xA4, scan: 0x38},                 // LAlt
		{vk: 0x27, scan: 0x4D, extended: true}, // Right
	},
	"browserBack": {
		{vk: 0xA4, scan: 0x38},                 // LAlt
		{vk: 0x25, scan: 0x4B, extended: true}, // Left
	},
	"snip": {
		{vk: 0x2C, scan: 0x37, extended: true}, // Print Screen (VK_SNAPSHOT)
	},
}

func shortcutCombo(action string) ([]shortcutKey, bool) {
	keys, ok := shortcutCombos[action]
	return keys, ok
}

func validShortcutAction(action string) bool {
	if action == "zoomIn" || action == "zoomOut" {
		return true
	}
	_, ok := shortcutCombos[action]
	return ok
}
