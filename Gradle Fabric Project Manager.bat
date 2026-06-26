@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Gradle Fabric Project Manager.ps1" %*
endlocal
