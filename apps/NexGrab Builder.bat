@echo off
setlocal EnableExtensions
title NexGrab Builder
cd /d "%~dp0"
set "APPDIR=%~dp0builder"
set "VENV=%APPDIR%\.venv"

if exist "%VENV%\Scripts\pythonw.exe" (
    "%VENV%\Scripts\python.exe" -c "import customtkinter, PIL" >nul 2>nul
    if not errorlevel 1 goto :run
)

echo ==========================================================
echo   NexGrab Builder - pehli dafa setup (1-2 minute, sirf ek baar)
echo ==========================================================
call :findpy
if not defined PY (
    echo Python nahi mila. winget se Python 3.12 install kar rahe hain...
    winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements
    call :findpy
)
if not defined PY (
    echo.
    echo [ERROR] Python install nahi ho saka. https://www.python.org/downloads/ se Python 3.12 install karein
    echo         ^("Add python.exe to PATH" tick karein^), phir ye file dobara chalayein.
    pause
    exit /b 1
)
echo Python: %PY%
if exist "%VENV%" rmdir /s /q "%VENV%"
%PY% -m venv "%VENV%"
if errorlevel 1 goto :setupfail
"%VENV%\Scripts\python.exe" -m pip install --disable-pip-version-check -q -U pip
"%VENV%\Scripts\python.exe" -m pip install --disable-pip-version-check -q customtkinter pillow
if errorlevel 1 goto :setupfail
"%VENV%\Scripts\python.exe" -c "import customtkinter, PIL, tkinter; tkinter.Tcl()"
if errorlevel 1 goto :setupfail
echo Setup mukammal.

:run
start "" "%VENV%\Scripts\pythonw.exe" "%APPDIR%\rsk_builder.py"
exit /b 0

:setupfail
echo.
echo [ERROR] Setup fail hua (internet check karein). Python 3.12 python.org wala ho, "tcl/tk" option ke saath.
pause
exit /b 1

:findpy
set "PY="
where py >nul 2>nul
if not errorlevel 1 (
    py -3 -c "import sys; assert sys.version_info >= (3, 10)" >nul 2>nul
    if not errorlevel 1 set "PY=py -3"
)
if defined PY exit /b 0
where python >nul 2>nul
if not errorlevel 1 (
    python -c "import sys; assert sys.version_info >= (3, 10)" >nul 2>nul
    if not errorlevel 1 set "PY=python"
)
if defined PY exit /b 0
for %%P in ("%LOCALAPPDATA%\Programs\Python\Python313\python.exe" "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" "%LOCALAPPDATA%\Programs\Python\Python311\python.exe" "%ProgramFiles%\Python312\python.exe" "%ProgramFiles%\Python313\python.exe") do (
    if not defined PY if exist "%%~P" set "PY="%%~P""
)
exit /b 0
