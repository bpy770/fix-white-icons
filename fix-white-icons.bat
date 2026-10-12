@echo off
rem ===========================================================================
rem  fix-white-icons.bat - Desktop white (blank) icon repair for Windows 10/11
rem
rem  WHAT THIS DOES
rem    1. Reads the mandatory integrity label of the Desktop directory.
rem    2. If the label is Low (S-1-16-4096), sets it back to Medium, which stops
rem       every file in the directory from inheriting a Low label.
rem    3. Restarts explorer.exe so the shell redraws the desktop icons.
rem
rem  The check and the repair are done by Fix-WhiteIcons.ps1, which reads the
rem  real integrity label ACE through the Windows security APIs instead of
rem  parsing localized icacls text. If that script is missing, this file falls
rem  back to plain icacls. Unlike Fix-WhiteIcons.ps1, this wrapper only ever
rem  works on the current user's Desktop.
rem
rem  USAGE
rem    Double-click this file, or run it from a command prompt:
rem        fix-white-icons.bat              repair, then restart Explorer
rem        fix-white-icons.bat -CheckOnly   report only, change nothing
rem        fix-white-icons.bat -NoRestart   repair, but leave Explorer alone
rem
rem  Run it from the directory that contains it: that is where it looks for
rem  Fix-WhiteIcons.ps1 and where it writes fix-log.txt.
rem
rem  NOTHING is deleted - no icon cache, no thumbnail cache, no shortcut. Only
rem  the integrity label of the Desktop directory is touched; every other
rem  permission entry is left exactly as it was.
rem
rem  ENCODING AND LANGUAGE - READ BEFORE EDITING
rem    This file is deliberately pure ASCII and never switches the console code
rem    page. Two reasons, both found the hard way:
rem      * cmd.exe decodes a batch file byte-wise and changes decoding when the
rem        code page changes, so a UTF-8 file that runs 'chcp 65001' and also
rem        contains multi-byte text is parsed incorrectly (commands get split
rem        apart mid-line).
rem      * the localized Chinese status line is printed by Fix-WhiteIcons.ps1,
rem        which is UTF-8 and sets its own output encoding. Leaving the console
rem        code page untouched is what lets that text come through intact.
rem    So: do not add non-ASCII characters to this file, and do not add a
rem    'chcp' line. All wording a user needs to read in Chinese comes from the
rem    PowerShell script.
rem ===========================================================================

setlocal EnableExtensions
title Desktop white icon - repair

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%Fix-WhiteIcons.ps1"
set "LOGFILE=%SCRIPT_DIR%fix-log.txt"
set "TARGET=%USERPROFILE%\Desktop"
set "CHECKONLY="
set "NORESTART="
set "ALLOWFALLBACK="
set "NOPAUSE="
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "PS_EXIT=9"

rem ---- command line ---------------------------------------------------------
:parse
if "%~1"=="" goto parsed
if /i "%~1"=="-CheckOnly" (
    set "CHECKONLY=1"
    shift
    goto parse
)
if /i "%~1"=="/CheckOnly" (
    set "CHECKONLY=1"
    shift
    goto parse
)
if /i "%~1"=="-NoRestart" (
    set "NORESTART=1"
    shift
    goto parse
)
if /i "%~1"=="/NoRestart" (
    set "NORESTART=1"
    shift
    goto parse
)
if /i "%~1"=="-AllowIcaclsFallback" (
    set "ALLOWFALLBACK=1"
    shift
    goto parse
)
  if /i "%~1"=="-NoPause" (
      set "NOPAUSE=1"
      shift
      goto parse
  )
  if /i "%~1"=="/NoPause" (
      set "NOPAUSE=1"
      shift
      goto parse
  )
echo Unknown argument: %*
echo Available: -CheckOnly  -NoRestart  -AllowIcaclsFallback  -NoPause
call :hold
exit /b 1
:parsed

echo ==========================================
echo   Desktop white icon - one click repair
echo ==========================================
echo.
echo Target: %TARGET%
if defined CHECKONLY echo Mode  : CHECK ONLY - nothing will be changed
if not defined CHECKONLY echo Mode  : check and repair if needed
echo.

if not exist "%TARGET%\" (
    echo [ERROR] Desktop directory not found: %TARGET%
    echo         If the Desktop was moved, use:  Fix-WhiteIcons.ps1 -Path "your path"
    echo.
    call :write_log "FAILURE  desktop directory not found"
    call :hold
    exit /b 1
)

rem ---- step 1: report the current label -------------------------------------
echo [1/3] Mandatory integrity label of the Desktop directory:
echo.
icacls "%TARGET%"
echo.
echo       In the list above, "Low Mandatory Level" or S-1-16-4096 means faulty,
echo       "Medium Mandatory Level" or S-1-16-8192 means healthy.
echo.

rem ---- step 2: decide and repair through the PowerShell script --------------
if not exist "%PS1%" goto no_ps1

rem -StatusOnly makes the UTF-8 PowerShell script print the Chinese status line;
rem -Quiet keeps its structured result object off the console.
set "PSARGS=-NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Path "%TARGET%" -StatusOnly -Quiet -Log "%LOGFILE%""
if defined CHECKONLY set "PSARGS=%PSARGS% -CheckOnly"
if defined NORESTART set "PSARGS=%PSARGS% -NoRestart"
if defined ALLOWFALLBACK set "PSARGS=%PSARGS% -AllowIcaclsFallback"

echo [2/3] Checking and repairing the label...
echo.
"%PSEXE%" %PSARGS%
set "PS_EXIT=%ERRORLEVEL%"
echo.

if "%PS_EXIT%"=="0" goto ps_ok
if "%PS_EXIT%"=="2" goto ps_low
goto ps_fail

:ps_ok
echo [2/3] Result: the label is healthy now (Medium or higher).
call :write_log "OK       label is not Low after the run"
goto after_repair

:ps_low
echo [2/3] Result: a Low integrity label was found, but this was a CHECK ONLY run,
echo       so nothing was changed. Run again without -CheckOnly to repair it.
call :write_log "CHECK    Low integrity label found; -CheckOnly so nothing changed"
goto after_repair

:ps_fail
echo [2/3] Result: FAILED, exit code %PS_EXIT% (1 = failure).
echo       Typical causes: the directory belongs to another account, so an
echo       elevated prompt is required, or policy blocks the label write.
call :write_log "FAILURE  Fix-WhiteIcons.ps1 exited with %PS_EXIT%"
goto after_repair

rem ---- fallback: no PowerShell script next to this file ---------------------
:no_ps1
echo [2/3] Fix-WhiteIcons.ps1 not found - falling back to icacls.
echo.
icacls "%TARGET%" | findstr /i /c:"Low Mandatory Level" /c:"S-1-16-4096" >nul 2>&1
if errorlevel 1 goto fb_ok

if defined CHECKONLY (
    echo [2/3] Result: Low integrity label found - CHECK ONLY, nothing changed.
    call :write_log "CHECK    Low label found via icacls; -CheckOnly so nothing changed"
    set "PS_EXIT=2"
    goto after_repair
)

echo          Setting the label back to Medium...
icacls "%TARGET%" /setintegritylevel Medium
if errorlevel 1 (
    echo [2/3] Result: FAILED to set the label - an elevated prompt may be required.
    call :write_log "FAILURE  icacls /setintegritylevel failed"
    set "PS_EXIT=1"
    goto after_repair
)

rem Confirm the change instead of assuming it worked.
icacls "%TARGET%" | findstr /i /c:"Low Mandatory Level" /c:"S-1-16-4096" >nul 2>&1
if not errorlevel 1 (
    echo [2/3] Result: the label still looks Low - retry as administrator.
    call :write_log "FAILURE  label still Low after icacls"
    set "PS_EXIT=1"
    goto after_repair
)
echo [2/3] Result: repaired and verified - the label is no longer Low.
call :write_log "REPAIRED Low label changed back to Medium via icacls"
set "PS_EXIT=0"
goto after_repair

:fb_ok
echo [2/3] Result: the label is healthy (not Low) - nothing was changed.
call :write_log "OK       label is not Low after the run"
set "PS_EXIT=0"
goto after_repair

rem ---- step 3: restart explorer --------------------------------------------
:after_repair
echo.
if defined CHECKONLY (
    echo [3/3] Check only - Explorer is NOT restarted.
    goto done
)
if defined NORESTART (
    echo [3/3] -NoRestart given - Explorer is NOT restarted.
    echo       The desktop keeps its old icons until Explorer restarts.
    goto done
)
if not "%PS_EXIT%"=="0" (
    echo [3/3] The repair did not succeed - Explorer is NOT restarted.
    goto done
)

echo [3/3] Restarting Explorer so the desktop icons are redrawn
echo       (the taskbar will blink, about 10 seconds)...
taskkill /f /im explorer.exe >nul 2>&1
timeout /t 3 /nobreak >nul
start "" "%WINDIR%\explorer.exe"
timeout /t 6 /nobreak >nul
tasklist /fi "imagename eq explorer.exe" | find /i "explorer.exe" >nul 2>&1
if errorlevel 1 (
    echo       Explorer did not come back - trying once more...
    start "" "%WINDIR%\explorer.exe"
    timeout /t 5 /nobreak >nul
    tasklist /fi "imagename eq explorer.exe" | find /i "explorer.exe" >nul 2>&1
    if errorlevel 1 (
        echo       [WARNING] Explorer is still not running.
        echo       If the taskbar is missing: Ctrl+Shift+Esc, File - Run new task,
        echo       type explorer.exe and press Enter.
        call :write_log "FAILURE  explorer.exe did not come back"
    ) else (
        call :write_log "NOTE     explorer.exe restarted after retry"
    )
) else (
    call :write_log "NOTE     explorer.exe restarted"
)

:done
echo.
echo Finished. If a few icons are still blank, press F5 on the desktop.
echo Log file: %LOGFILE%
call :hold
exit /b 0

rem ---- helpers --------------------------------------------------------------
:write_log
rem ASCII message only, one line, appended beside this script. No %date%/%time%
rem on purpose: the localized date string can contain non-ASCII text. The UTF-8
rem PowerShell script writes its own timestamped entries, so nothing is lost.
>>"%LOGFILE%" echo %~1
exit /b 0

:hold
rem Keep the window open so the person who double-clicked can read the result.
rem Automation passes -NoPause to return immediately. The wait is explicit now:
rem Explorer also starts .bat files with cmd /c, so guessing from %CMDCMDLINE%
rem (the previous approach) closed the window on a real double-click.
if defined NOPAUSE exit /b 0
echo.
pause
exit /b 0
