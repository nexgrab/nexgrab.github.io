@echo off
setlocal
cd /d "%~dp0"
title NexGrab (source)
call :findpy
if errorlevel 1 goto :nopy
if not exist ".venv\Scripts\python.exe" (
    echo Creating Python environment...
    %PY% -m venv .venv
    if errorlevel 1 goto :fail
)
".venv\Scripts\python.exe" -m pip install -q --disable-pip-version-check -U -r requirements.txt
if errorlevel 1 goto :fail
start "" ".venv\Scripts\pythonw.exe" rsk_futuristic_downloader.py
exit /b 0

:findpy
set "PY="
where py >nul 2>nul
if not errorlevel 1 (
    py -3 -c "import sys" >nul 2>nul
    if not errorlevel 1 set "PY=py -3"
)
if defined PY exit /b 0
where python >nul 2>nul
if not errorlevel 1 (
    python -c "import sys" >nul 2>nul
    if not errorlevel 1 set "PY=python"
)
if defined PY exit /b 0
exit /b 1

:nopy
echo Python 3.10+ nahi mila. https://www.python.org/downloads/ se install karein
echo ("Add python.exe to PATH" tick karein), phir dobara chalayein.
pause
exit /b 1

:fail
echo.
echo Kuch ghalat ho gaya. Upar wala error dekhein.
pause
exit /b 1
