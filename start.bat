@echo off
chcp 65001 >nul
cd /d "%~dp0"

if not exist "server\.env" (
  copy "server\.env.example" "server\.env" >nul
  echo.
  echo 已创建 server\.env
  echo 请先打开它，把 HPLAYER_PASSWORD 改成你自己的密码，然后重新运行本脚本。
  echo.
  pause
  exit /b 1
)

where ffmpeg >nul 2>nul
if errorlevel 1 (
  echo.
  echo 警告：没有找到 ffmpeg，mkv 等格式将无法播放。
  echo 安装方式：winget install Gyan.FFmpeg
  echo 或在 server\.env 里设置 FFMPEG_PATH
  echo.
)

echo HPlayer 启动中，按 Ctrl+C 停止...
call npm run start
pause
