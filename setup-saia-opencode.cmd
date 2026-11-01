@echo off
rem setup-saia-opencode.cmd - Windows launcher for setup-saia-opencode.sh.
rem Keep both files in the same folder; arguments are passed through
rem (e.g. setup-saia-opencode.cmd --solo --auto).
rem
rem Runs the installer under Git Bash, the same bash opencode uses on Windows.
rem Deliberately NOT plain "bash": on Windows that is usually WSL's
rem System32\bash.exe, which would install into the WSL home where the
rem Windows opencode never looks. No labels/goto: safe with LF line endings.
setlocal
set "GITBASH=%OPENCODE_GIT_BASH_PATH%"
if not defined GITBASH for /f "delims=" %%G in ('where git 2^>nul') do if not defined GITBASH set "GITBASH=%%~dpG..\bin\bash.exe"
if not exist "%GITBASH%" set "GITBASH=%ProgramFiles%\Git\bin\bash.exe"
if exist "%GITBASH%" (
  "%GITBASH%" "%~dp0setup-saia-opencode.sh" %*
) else (
  echo ERROR: Git for Windows is required: winget install Git.Git
  echo        Already installed elsewhere? Set OPENCODE_GIT_BASH_PATH to its bin\bash.exe.
  cmd /c exit 1
)
set RC=%ERRORLEVEL%
rem Double-clicked (no arguments): keep the window open so the result stays readable.
if "%~1"=="" pause
exit /b %RC%
