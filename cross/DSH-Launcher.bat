@echo off
rem DeepSeek Harness 启动台 - Windows 启动入口（带控制台；无窗口版用 DSH-Launcher.vbs）
setlocal
set PORT=4899
set URL=http://127.0.0.1:%PORT%/

curl -fsS -m 2 -o NUL "%URL%" 2>NUL
if %errorlevel%==0 (
    start "" "%URL%"
    exit /b 0
)

where node >NUL 2>NUL
if errorlevel 1 (
    echo 未找到 node，请先安装 Node.js（dsh 也依赖它）
    pause
    exit /b 1
)

start "DeepSeek Harness 启动台" /min node "%~dp0server.js"
timeout /t 2 /nobreak >NUL
start "" "%URL%"
