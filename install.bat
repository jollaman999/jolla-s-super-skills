@echo off
rem  Hands install.sh over to Git Bash when started from cmd or Explorer.
rem  This file only locates bash and delegates. All install logic is in install.sh.
rem  Cygwin and WSL bash are skipped on purpose - this repo targets Git Bash.
rem
rem  ASCII only, and it has to stay that way. cmd loses track of its file offset
rem  when a batch file carries non-ASCII text under a switched code page, and ends
rem  up running a later line from the middle. Korean text goes in install.sh.

rem  Switch the console to UTF-8 so the Korean output of install.sh survives.
rem  Do not switch back at the end - that clears the console buffer and wipes out
rem  the notices just printed. Only this one window changes, and closing it resets.
chcp 65001 >nul
setlocal

rem  An Explorer double-click runs this through cmd /c and the window closes the
rem  moment it ends, so the notices below would flash past. Pause only in that case.
rem  Do not use find here: if Cygwin or Git usr\bin comes before System32 on PATH,
rem  GNU find is picked instead of find.exe, reads /i as a file name, and always fails.
setlocal enabledelayedexpansion
set "CL=!cmdcmdline!"
set CL=!CL:"=!
set "FE="
if not "!CL:/c =!"=="!CL!" set "FE=1"
endlocal & set "FROMEXPLORER=%FE%"

set "SH=%~dp0install.sh"
if not exist "%SH%" (
  echo install.sh not found: "%SH%"
  if defined FROMEXPLORER pause
  exit /b 2
)

set "BASH="

rem  1) the same variable Claude Code uses
if defined CLAUDE_CODE_GIT_BASH_PATH if exist "%CLAUDE_CODE_GIT_BASH_PATH%" set "BASH=%CLAUDE_CODE_GIT_BASH_PATH%"

rem  2) standard install locations
if not defined BASH if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "BASH=%LocalAppData%\Programs\Git\bin\bash.exe"

rem  3) the install path recorded in the registry
if not defined BASH call :fromreg HKLM
if not defined BASH call :fromreg HKCU

if not defined BASH (
  echo.
  echo Git Bash not found.
  echo.
  echo Every script in this repo is bash, so Git for Windows is required.
  echo   https://git-scm.com/downloads/win
  echo.
  echo If it is already installed and you still see this, set the path and retry.
  echo   set "CLAUDE_CODE_GIT_BASH_PATH=C:\Program Files\Git\bin\bash.exe"
  echo.
  echo See the Windows section of README.md for the guide in Korean.
  echo.
  if defined FROMEXPLORER pause
  exit /b 1
)

rem  Backslashes become slashes on the way to bash - bash reads them as escapes.
set "SHU=%SH:\=/%"
echo bash: "%BASH%"
"%BASH%" "%SHU%" %*
set "RC=%ERRORLEVEL%"
if defined FROMEXPLORER pause
exit /b %RC%

:fromreg
for /f "tokens=2,*" %%a in ('reg query "%~1\SOFTWARE\GitForWindows" /v InstallPath 2^>nul ^| findstr /i InstallPath') do (
  if exist "%%~b\bin\bash.exe" set "BASH=%%~b\bin\bash.exe"
)
exit /b 0
