@echo off
REM ==========================================================================
REM  sunpos -- launcher (Windows)
REM
REM  Runs the CLI inside the project's .venv. If the .venv does not exist yet,
REM  setup.bat is called automatically.
REM
REM    run.bat "48.840006, 2.276764" "2026-09-29 19:30" --north 121
REM    run.bat "-33.8599, 151.2091" 2026-11-21 --north 5 --path 2
REM    run.bat --list-zones
REM ==========================================================================
setlocal
cd /d "%~dp0"

set "PY=%~dp0.venv\Scripts\python.exe"

if not exist "%PY%" (
    echo [sunpos] no .venv yet, installing ...
    call "%~dp0setup.bat" || exit /b 1
)

"%PY%" "%~dp0sunpos_cli.py" %*
endlocal
