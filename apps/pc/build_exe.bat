@echo off
setlocal EnableExtensions EnableDelayedExpansion
title NexGrab - EXE Builder
cd /d "%~dp0"
set "NOPAUSE=%~1"
set "NAME=NexGrab"
set "OUT=%CD%\release\%NAME%"

echo ==========================================================
echo   NEXGRAB v3.2  -  Windows EXE builder
echo ==========================================================
echo.

echo [1/6] Python check...
call :findpy
if errorlevel 1 (
    echo Python nahi mila. winget se Python 3.12 install karne ki koshish...
    winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements
    call :findpy
    if errorlevel 1 (
        echo [ERROR] Python 3.10+ install karein: https://www.python.org/downloads/
        echo         Install ke waqt "Add python.exe to PATH" tick karein.
        goto :fail
    )
)
%PY% -c "import sys; assert sys.version_info >= (3, 10), sys.version"
if errorlevel 1 (
    echo [ERROR] Python 3.10 ya naya chahiye.
    goto :fail
)
%PY% -c "import tkinter"
if errorlevel 1 (
    echo [ERROR] Python mein tkinter nahi. Python dobara install karein - tcl/tk option ke saath.
    goto :fail
)

echo.
echo [2/6] Build environment (.venv)...
if not exist ".venv\Scripts\python.exe" (
    %PY% -m venv .venv
    if errorlevel 1 goto :fail
)
set "VPY=%CD%\.venv\Scripts\python.exe"
"%VPY%" -m pip install --disable-pip-version-check -q -U pip
"%VPY%" -m pip install --disable-pip-version-check -U -r requirements.txt -r requirements-build.txt
if errorlevel 1 goto :fail
rem PyInstaller silently drops a broken tkinter and the EXE then dies at start - check first.
"%VPY%" -c "import tkinter; tkinter.Tcl()" >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Is Python ka Tcl/Tk ^(tkinter^) theek nahi. python.org se Python 3.12 install karein
    echo         ^("tcl/tk and IDLE" option ON^), phir .venv folder delete karke dobara chalayein.
    goto :fail
)

echo.
echo [3/6] Icon...
"%VPY%" make_icon.py
if errorlevel 1 goto :fail

echo.
echo [4/6] Cleaning old build...
if exist build rmdir /s /q build
if exist dist rmdir /s /q dist
if exist "%OUT%" rmdir /s /q "%OUT%"
if exist "%NAME%.spec" del /q "%NAME%.spec"

echo.
echo [5/6] Building EXE (2-5 minute)...
"%VPY%" -m PyInstaller --noconfirm --clean --onefile --windowed ^
  --name "%NAME%" ^
  --icon "assets\nexgrab.ico" ^
  --add-data "assets;assets" ^
  --collect-all customtkinter ^
  --collect-submodules yt_dlp ^
  --collect-data yt_dlp_ejs ^
  --hidden-import PIL._tkinter_finder ^
  --hidden-import PIL.ImageTk ^
  --exclude-module imageio_ffmpeg ^
  --exclude-module deno ^
  rsk_futuristic_downloader.py
if errorlevel 1 goto :fail
if not exist "dist\%NAME%.exe" (echo [ERROR] EXE nahi bani. & goto :fail)

echo.
echo [6/6] Release folder (EXE + FFmpeg + YouTube JS engine)...
mkdir "%OUT%\tools" 2>nul
copy /Y "dist\%NAME%.exe" "%OUT%\" >nul
if errorlevel 1 goto :fail
"%VPY%" collect_tools.py "%OUT%\tools"
powershell -NoProfile -Command "Compress-Archive -Force -Path '%OUT%' -DestinationPath '%CD%\release\NexGrab_v3.2_Windows.zip'" >nul 2>nul

echo.
echo ==========================================================
echo   EXE READY
echo ==========================================================
echo   %OUT%\%NAME%.exe
echo   (tools folder EXE ke saath hi rakhein)
echo   Share karne ke liye: release\NexGrab_v3.2_Windows.zip
echo.
if /i not "%NOPAUSE%"=="nopause" (
    start "" "%OUT%"
    pause
)
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

:fail
echo.
echo ==========================================================
echo   EXE BUILD FAILED - upar wala error dekhein
echo ==========================================================
if /i not "%NOPAUSE%"=="nopause" pause
exit /b 1
