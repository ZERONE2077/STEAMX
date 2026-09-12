@echo off
chcp 936 >nul
title STEAMX 修复下载 · 线上正式版
setlocal
set "F=%TEMP%\STEAMX-boot.ps1"
set "OK="

rem 依次试三个源取引导脚本；引导脚本本身再去问 GitHub API 拿 main 的最新 sha，
rem 所以这里就算拿到的是稍旧的 boot.ps1，最终跑的还是最新版 DownloadRepair.ps1。
call :try "https://cdn.jsdelivr.net/gh/ZERONE2077/STEAMX@latest/DownloadRepair/boot.ps1"
if defined OK goto run
call :try "https://gh-proxy.com/https://raw.githubusercontent.com/ZERONE2077/STEAMX/main/DownloadRepair/boot.ps1"
if defined OK goto run
call :try "https://ghfast.top/https://raw.githubusercontent.com/ZERONE2077/STEAMX/main/DownloadRepair/boot.ps1"
if defined OK goto run
goto fail

:run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%F%" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%

:fail
echo.
echo   引导脚本下载失败：没网 / CDN 被拦截 / 安全软件拦截。
echo   试过的源：jsDelivr - gh-proxy - ghfast
echo.
pause
exit /b 7

rem 下载 + 校验：必须存在且含 boot 标记（boot.ps1 是纯 ASCII，任何代码页下 findstr 都可靠）
:try
del "%F%" >nul 2>nul
curl.exe -sSL --retry 2 --connect-timeout 12 -o "%F%" "%~1" >nul 2>nul
if not exist "%F%" powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try{Invoke-WebRequest -Uri '%~1' -UseBasicParsing -OutFile '%F%'}catch{}" >nul 2>nul
if not exist "%F%" exit /b 0
findstr /c:"DownloadRepair bootstrap" "%F%" >nul 2>nul
if errorlevel 1 exit /b 0
set "OK=1"
exit /b 0
