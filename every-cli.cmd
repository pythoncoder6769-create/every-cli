@echo off
setlocal
chcp 65001 >nul 2>nul

set "BASH_EXE="
where bash >nul 2>nul && set "BASH_EXE=bash"
if not defined BASH_EXE if exist "C:\Program Files\Git\bin\bash.exe" set "BASH_EXE=C:\Program Files\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%LOCALAPPDATA%\Programs\Git\bin\bash.exe" set "BASH_EXE=%LOCALAPPDATA%\Programs\Git\bin\bash.exe"

if not defined BASH_EXE (
    echo Error: Git Bash not found. Please install Git for Windows or Scoop.
    exit /b 1
)

:: Auto-detect MPV and FZF if installed in standard locations but not on PATH
if exist "C:\Program Files\MPV Player" set "PATH=%PATH%;C:\Program Files\MPV Player"
if exist "C:\Program Files\mpv" set "PATH=%PATH%;C:\Program Files\mpv"
if exist "C:\Program Files (x86)\MPV Player" set "PATH=%PATH%;C:\Program Files (x86)\MPV Player"
if exist "%USERPROFILE%\scoop\apps\mpv\current" set "PATH=%PATH%;%USERPROFILE%\scoop\apps\mpv\current"
if exist "%USERPROFILE%\scoop\apps\fzf\current" set "PATH=%PATH%;%USERPROFILE%\scoop\apps\fzf\current"
where fzf >nul 2>nul || (
    for /d %%D in ("%LOCALAPPDATA%\Microsoft\WinGet\Packages\*fzf*") do (
        if exist "%%D\fzf.exe" set "PATH=%PATH%;%%D"
    )
)

"%BASH_EXE%" "%~dp0every-cli" %*
exit /b %ERRORLEVEL%
