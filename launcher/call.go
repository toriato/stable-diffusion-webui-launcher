package main

import (
	"fmt"

	"golang.org/x/sys/windows"
)

func MessageBox(text, caption string, t uint32) {
	textPointer, _ := windows.UTF16PtrFromString(text)
	captionPointer, _ := windows.UTF16PtrFromString(caption)

	windows.MessageBox(0, textPointer, captionPointer, t)
}

func MessageBoxPanic(text string, err error) {
	MessageBox(
		fmt.Sprintf("%s\n%s", text, err),
		"panic",
		windows.MB_TOPMOST|windows.MB_SETFOREGROUND|windows.MB_ICONERROR)
	panic(err)
}
