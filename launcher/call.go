package main

import (
	"fmt"
	"syscall"
	"unsafe"
)

const (
	MB_ICONERROR = 0x00000010
)

var (
	user32            = syscall.MustLoadDLL("user32.dll")
	procMessageBoxExW = user32.MustFindProc("MessageBoxExW")
)

func MessageBoxExW(text, caption string, t uint32) {
	textPointer, _ := syscall.UTF16PtrFromString(text)
	captionPointer, _ := syscall.UTF16PtrFromString(caption)

	procMessageBoxExW.Call(
		0,
		uintptr(unsafe.Pointer(textPointer)),
		uintptr(unsafe.Pointer(captionPointer)),
		uintptr(t))
}

func MessageBoxPanic(text string, err error) {
	MessageBoxExW(fmt.Sprintf("%s\n%s", text, err), "panic", MB_ICONERROR)
	panic(err)
}
