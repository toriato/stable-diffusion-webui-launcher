@echo off
go build -o ../launcher.exe -ldflags "-w -H=windowsgui" .