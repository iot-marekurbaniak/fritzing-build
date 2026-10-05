@echo off
rem Local Windows build of Fritzing, no GitHub Actions. Double-click or run from cmd.exe:
rem   build-local-windows.cmd
rem   build-local-windows.cmd -WorkDir "D:\fritzing build" -OutDir "D:\fritzing out"
rem The .cmd only starts scripts\build-local-windows.ps1 with an execution policy that works on a
rem freshly installed Windows; it does not change any system setting.
setlocal
set "PSEXE=powershell.exe"
where pwsh.exe >nul 2>&1
if not errorlevel 1 set "PSEXE=pwsh.exe"
"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build-local-windows.ps1" %*
set "CODE=%ERRORLEVEL%"
if not "%CODE%"=="0" echo.
if not "%CODE%"=="0" echo Build failed with exit code %CODE%. See the log in the out\logs folder.
exit /b %CODE%
