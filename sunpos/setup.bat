@echo off
REM ==========================================================================
REM  sunpos -- isolated install (Windows)
REM
REM  Creates a virtual environment .venv INSIDE the project folder and installs
REM  the dependencies there. The system Python is never modified: nothing is
REM  installed globally, nothing is added to PATH.
REM  To uninstall: delete the .venv folder.
REM ==========================================================================
setlocal
cd /d "%~dp0"

set "VENV=%~dp0.venv"
set "PY=%VENV%\Scripts\python.exe"

echo.
echo   sunpos -- install
echo   -----------------------

where py >nul 2>nul
if %errorlevel%==0 (
    set "LAUNCHER=py -3"
) else (
    where python >nul 2>nul
    if %errorlevel% neq 0 (
        echo   [X] Python not found.
        echo       Install Python 3.9 or newer: https://www.python.org/downloads/
        echo       Tick "Add python.exe to PATH" during installation.
        exit /b 1
    )
    set "LAUNCHER=python"
)

if not exist "%PY%" (
    echo   [1/3] creating the .venv virtual environment ...
    %LAUNCHER% -m venv "%VENV%"
    if %errorlevel% neq 0 (
        echo   [X] Could not create the .venv.
        exit /b 1
    )
) else (
    echo   [1/3] .venv already present.
)

echo   [2/3] upgrading pip ...
"%PY%" -m pip install --upgrade pip --quiet --disable-pip-version-check

echo   [3/3] installing dependencies ...
"%PY%" -m pip install --requirement requirements.txt --quiet --disable-pip-version-check
if %errorlevel% neq 0 (
    echo   [X] Dependency installation failed.
    exit /b 1
)

echo.
echo   Done. Nothing was installed outside .venv\
echo.
echo   Checking:
"%PY%" -m pytest tests -q 2>nul || "%PY%" tests\test_sunpos.py
echo.
echo   Usage:
echo     run.bat "48.840006, 2.276764" "2026-09-29 19:30" --north 121
echo     run.bat "-33.8599, 151.2091" 2026-11-21 --north 5 --path 2
echo.
endlocal
