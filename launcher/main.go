package main

import (
	"io"
	"net/http"
	"os"
	"os/exec"
	"syscall"
)

const (
	scriptPath = "launcher.ps1"
	scriptURL  = "https://raw.githubusercontent.com/toriato/stable-diffusion-webui-launcher/main/launcher.ps1"
)

func fetch() (err error) {
	f, err := os.Create(scriptPath)
	if err != nil {
		return err
	}
	defer f.Close()

	res, err := http.Get(scriptURL)
	if err != nil {
		return err
	}
	defer res.Body.Close()

	_, err = io.Copy(f, res.Body)
	return
}

func main() {
	// 실행 스크립트가 존재하지 않으면 인터넷으로부터 받아오기
	if _, err := os.Stat(scriptPath); os.IsNotExist(err) {
		if err := fetch(); err != nil {
			MessageBoxPanic("스크립트를 인터넷으로부터 받아오는 중 오류가 발생했습니다", err)
		}
	}

	args := []string{
		"-NoLogo",
		"-NoProfile",
		"-ExecutionPolicy", "Bypass",
		"-File", scriptPath}
	args = append(args, os.Args[1:]...)

	ps, err := exec.LookPath("powershell.exe")
	if err != nil {
		MessageBoxPanic("파워쉘 경로를 찾을 수 없습니다", err)
	}

	cmd := exec.Cmd{
		Path: ps,
		Args: args,
		SysProcAttr: &syscall.SysProcAttr{
			CreationFlags:    0x10, // CREATE_NEW_CONSOLE
			NoInheritHandles: true,
		},
	}
	// 0xc000013a = STATUS_CONTROL_C_EXIT
	if err := cmd.Run(); err != nil && err.Error() != "exit status 0xc000013a" {
		MessageBoxPanic("스크립트 실행 중 오류가 발생했습니다", err)
	}
}
