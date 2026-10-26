@echo off
REM Двойной клик по этому файлу = запуск всей настройки.
REM Качает adb (если нужно), находит телефон, ставит Google вместо Breeno.
setlocal
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0oneclick.ps1" %*
endlocal
