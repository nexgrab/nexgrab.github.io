@echo off
setlocal EnableExtensions
title NexGrab v3.2 - Build EXE + APK
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
set "OUTDIR=%ROOT%\OUTPUT"
set "EXE_OK=-"
set "APK_OK=-"

rem  Usage:  BUILD_ALL.bat            (menu)
rem          BUILD_ALL.bat exe | apk | all

set "CHOICE=%~1"
if /i "%CHOICE%"=="exe" goto :do_exe_only
if /i "%CHOICE%"=="apk" goto :do_apk_only
if /i "%CHOICE%"=="all" goto :do_all

:menu
cls
echo.
echo   ============================================================
echo        NEXGRAB v3.2   -   by WSNex
echo   ============================================================
echo.
echo     1.  Windows EXE banao        (PC app)
echo     2.  Android APK banao        (phone app)
echo     3.  Dono banao               (EXE + APK)
echo     0.  Exit
echo.
choice /c 1230 /n /m "   Number dabayein: "
if errorlevel 4 exit /b 0
if errorlevel 3 goto :do_all
if errorlevel 2 goto :do_apk_only
if errorlevel 1 goto :do_exe_only
goto :menu

:do_exe_only
call :build_exe
goto :summary

:do_apk_only
call :build_apk
goto :summary

:do_all
call :build_exe
call :build_apk
goto :summary

:build_exe
echo.
echo ################  WINDOWS EXE  ################
call "%ROOT%\pc\build_exe.bat" nopause
if errorlevel 1 (set "EXE_OK=FAILED" & exit /b 1)
if not exist "%OUTDIR%\Windows" mkdir "%OUTDIR%\Windows"
xcopy "%ROOT%\pc\release\NexGrab\*" "%OUTDIR%\Windows\NexGrab\" /E /I /Y /Q >nul
if exist "%ROOT%\pc\release\NexGrab_v3.2_Windows.zip" copy /Y "%ROOT%\pc\release\NexGrab_v3.2_Windows.zip" "%OUTDIR%\Windows\" >nul
set "EXE_OK=OK"
exit /b 0

:build_apk
echo.
echo ################  ANDROID APK  ################
call "%ROOT%\android\MAKE_APK.cmd" nopause
if errorlevel 1 (set "APK_OK=FAILED" & exit /b 1)
if not exist "%OUTDIR%\Android" mkdir "%OUTDIR%\Android"
copy /Y "%ROOT%\android\APK\NexGrab.apk" "%OUTDIR%\Android\NexGrab_v3.2.apk" >nul
if errorlevel 1 (set "APK_OK=FAILED" & exit /b 1)
if exist "%ROOT%\android\APK\NexGrab_32bit.apk" copy /Y "%ROOT%\android\APK\NexGrab_32bit.apk" "%OUTDIR%\Android\NexGrab_v3.2_32bit.apk" >nul
set "APK_OK=OK"
exit /b 0

:summary
cd /d "%ROOT%"
echo.
echo   ============================================================
echo     RESULT
echo   ============================================================
echo     Windows EXE : %EXE_OK%
echo     Android APK : %APK_OK%
echo.
if "%EXE_OK%"=="OK" echo     EXE:  OUTPUT\Windows\NexGrab\NexGrab.exe
if "%APK_OK%"=="OK" echo     APK:  OUTPUT\Android\NexGrab_v3.2.apk
if "%EXE_OK%"=="FAILED" echo     EXE log: upar ka error dekhein  (pc\build_exe.bat)
if "%APK_OK%"=="FAILED" echo     APK log: android\build_apk.log
echo.
if exist "%OUTDIR%" start "" "%OUTDIR%"
pause
exit /b 0
