@echo off
setlocal EnableExtensions
title RAR Archiver
cd /d "%~dp0"

if not exist "%~dp0CLEANUP.ps1" (
  echo CLEANUP.ps1 must be in the same folder as RUN.bat: %~dp0
  goto :end
)

rem ---------- 1. PowerShell 7 ----------
call :find_pwsh
if not defined PWSH (
  echo [setup] PowerShell 7 not found. Installing it now. Click Yes if Windows asks for permission.
  call :install_pwsh
  call :find_pwsh
)
if not defined PWSH (
  echo.
  echo [setup] PowerShell 7 could not be installed automatically.
  echo         Install it from https://aka.ms/powershell and run RUN.bat again.
  goto :end
)

rem ---------- 2. WinRAR ----------
call :find_rar
if not defined RAREXE (
  echo [setup] WinRAR not found. Installing it now. Click Yes if Windows asks for permission.
  where winget >nul 2>&1
  if not errorlevel 1 (
    winget install --id RARLab.WinRAR --source winget --accept-package-agreements --accept-source-agreements
  ) else (
    echo [setup] winget is not available on this PC.
  )
  call :find_rar
)
if not defined RAREXE (
  echo.
  echo [setup] WinRAR could not be installed automatically.
  echo         Install it from https://www.win-rar.com/download.html and run RUN.bat again.
  goto :end
)

rem ---------- 3. run ----------
"%PWSH%" -NoLogo -ExecutionPolicy Bypass -File "%~dp0CLEANUP.ps1" %*
goto :end

:find_pwsh
set "PWSH="
for /f "delims=" %%P in ('where pwsh 2^>nul') do if not defined PWSH set "PWSH=%%P"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
goto :eof

:find_rar
set "RAREXE="
if exist "%ProgramFiles%\WinRAR\Rar.exe" set "RAREXE=%ProgramFiles%\WinRAR\Rar.exe"
if not defined RAREXE if exist "%ProgramFiles(x86)%\WinRAR\Rar.exe" set "RAREXE=%ProgramFiles(x86)%\WinRAR\Rar.exe"
goto :eof

:install_pwsh
where winget >nul 2>&1
if not errorlevel 1 (
  winget install --id Microsoft.PowerShell --source winget --accept-package-agreements --accept-source-agreements
  goto :eof
)
echo [setup] winget is not available. Downloading the installer from GitHub.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; $r=Invoke-RestMethod 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -Headers @{'User-Agent'='RUN.bat'}; $a=$r.assets | Where-Object { $_.name -like '*win-x64.msi' } | Select-Object -First 1; $f=Join-Path $env:TEMP $a.name; Invoke-WebRequest $a.browser_download_url -OutFile $f; Start-Process msiexec.exe -ArgumentList '/i',$f,'/qn','ADD_PATH=1' -Wait -Verb RunAs"
goto :eof

:end
echo.
pause
endlocal
