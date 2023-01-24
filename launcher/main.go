package main

import (
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"golang.org/x/sys/windows"
)

const (
	scriptPath = "launcher.ps1"
	scriptURL  = "https://raw.githubusercontent.com/toriato/stable-diffusion-webui-launcher/main/launcher.ps1"
)

var (
	logPath = filepath.Join("logs", time.Now().Format("2006-01-02T15-04-05.log"))
)

// PowerShell 스크립트 파일을 인터넷으로부터 가져옵니다
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
	// 콘솔 초기화
	stdout := windows.Handle(os.Stdout.Fd())
	var outConsoleMode uint32
	windows.GetConsoleMode(stdout, &outConsoleMode)
	windows.SetConsoleMode(stdout, outConsoleMode|windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING)

	stderr := windows.Handle(os.Stderr.Fd())
	var errConsoleMode uint32
	windows.GetConsoleMode(stderr, &errConsoleMode)
	windows.SetConsoleMode(stderr, errConsoleMode|windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING)

	// 로그 파일 만들기
	os.MkdirAll(filepath.Dir(logPath), 0755)

	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		MessageBoxPanic("로그 파일 생성 중 오류가 발생했습니다", err)
	}
	defer func() {
		if err := logFile.Close(); err != nil {
			MessageBoxPanic("로그 파일을 정리하는 중 오류가 발생했습니다", err)
		}
	}()

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
		Path:   ps,
		Args:   args,
		Stdin:  os.Stdin,
		Stdout: io.MultiWriter(os.Stdout, logFile),
		Stderr: io.MultiWriter(os.Stderr, logFile),
		Env:    os.Environ(),
	}
	cmd.Env = append(cmd.Env, "PYTHONUNBUFFERED=1")

	// 0xc000013a = STATUS_CONTROL_C_EXIT
	if err := cmd.Run(); err != nil && err.Error() != "exit status 0xc000013a" {
		MessageBoxPanic("스크립트 실행 중 오류가 발생했습니다", err)
	}
}
