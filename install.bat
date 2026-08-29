@echo off
rem  한글 메시지가 깨지지 않게 콘솔 코드페이지를 UTF-8 로 바꾸고 끝나면 되돌린다.
for /f "tokens=2 delims=:" %%a in ('chcp') do for /f "tokens=1 delims=." %%b in ("%%a") do set "OLDCP=%%b"
chcp 65001 >nul
rem  cmd 나 탐색기에서 실행했을 때 install.sh 를 Git Bash 로 넘긴다.
rem  이 파일은 bash 를 찾아 위임하는 것만 한다. 설치 로직은 전부 install.sh 에 있다.
rem  Cygwin 과 WSL 의 bash 는 일부러 거른다 - 이 repo 의 지원 대상은 Git Bash 다.
setlocal

set "SH=%~dp0install.sh"
if not exist "%SH%" (
  echo install.sh 를 찾을 수 없습니다: "%SH%"
  call :restorecp
  exit /b 2
)

set "BASH="

rem  1) Claude Code 가 쓰는 것과 같은 변수를 먼저 본다
if defined CLAUDE_CODE_GIT_BASH_PATH if exist "%CLAUDE_CODE_GIT_BASH_PATH%" set "BASH=%CLAUDE_CODE_GIT_BASH_PATH%"

rem  2) 정식 설치 위치
if not defined BASH if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "BASH=%LocalAppData%\Programs\Git\bin\bash.exe"

rem  3) 레지스트리에 적힌 설치 경로
if not defined BASH call :fromreg HKLM
if not defined BASH call :fromreg HKCU

if not defined BASH (
  echo.
  echo Git Bash 를 찾지 못했습니다.
  echo.
  echo 이 repo 는 전부 bash 스크립트라 Git for Windows 가 있어야 동작합니다.
  echo   https://git-scm.com/downloads/win
  echo.
  echo 설치했는데도 이 메시지가 나오면 경로를 직접 지정하고 다시 실행하세요.
  echo   set "CLAUDE_CODE_GIT_BASH_PATH=C:\Program Files\Git\bin\bash.exe"
  echo.
  call :restorecp
  exit /b 1
)

rem  bash 에 넘길 때는 역슬래시를 슬래시로 바꾼다. 역슬래시는 bash 가 이스케이프로 읽는다.
set "SHU=%SH:\=/%"
echo bash: "%BASH%"
"%BASH%" "%SHU%" %*
set "RC=%ERRORLEVEL%"
call :restorecp
exit /b %RC%

:restorecp
if defined OLDCP chcp %OLDCP% >nul
exit /b 0

:fromreg
for /f "tokens=2,*" %%a in ('reg query "%~1\SOFTWARE\GitForWindows" /v InstallPath 2^>nul ^| findstr /i InstallPath') do (
  if exist "%%~b\bin\bash.exe" set "BASH=%%~b\bin\bash.exe"
)
exit /b 0
