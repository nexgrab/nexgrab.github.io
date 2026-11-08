@echo off
setlocal EnableExtensions
title NexGrab - C: drive saaf karo

rem ---- Administrator mode (Windows Temp + Recycle Bin ke liye) ----
net session >nul 2>nul
if errorlevel 1 (
    echo Administrator permission maang rahe hain... "Yes" dabayein.
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo  ==========================================================
echo     C: DRIVE SAAF KARO  (APK build ka kachra)
echo  ==========================================================
echo   Ye delete hoga: Gradle cache, Flutter package cache, Temp files,
echo   purani RSK build folders, Recycle Bin. Android SDK + caches L: par shift.
echo   Aapki apni files (Documents, Pictures, Desktop) ko haath NAHI lagega.
echo   Android Studio / koi build chal raha ho to pehle band kar dein.
echo.
call :free "PEHLE"
echo.
pause

set "U=%USERPROFILE%"
set "LA=%LOCALAPPDATA%"

echo.
echo [1/9] Gradle / Java / Dart background processes band...
taskkill /f /im java.exe >nul 2>nul
taskkill /f /im dart.exe >nul 2>nul
taskkill /f /im dartaotruntime.exe >nul 2>nul
ping -n 3 127.0.0.1 >nul

echo [2/9] Aage se sab build files L: par jayengi (C: phir nahi bharegi)...
if not exist L:\ (
    echo   L: drive nahi mili - ye step skip.
    goto :after_move
)
for %%F in ("L:\DevCache\gradle-home" "L:\DevCache\pub-cache" "L:\DevCache\Temp" "L:\Android") do if not exist "%%~F" mkdir "%%~F"
setx GRADLE_USER_HOME "L:\DevCache\gradle-home" >nul
setx PUB_CACHE "L:\DevCache\pub-cache" >nul
setx TEMP "L:\DevCache\Temp" >nul
setx TMP "L:\DevCache\Temp" >nul
echo   Gradle cache  -^> L:\DevCache\gradle-home
echo   Flutter cache -^> L:\DevCache\pub-cache
echo   Temp folder   -^> L:\DevCache\Temp
set "NEW_GRADLE=L:\DevCache\gradle-home"
set "NEW_PUB=L:\DevCache\pub-cache"
set "NEW_TEMP=L:\DevCache\Temp"
if exist "L:\Android\Sdk\platform-tools" goto :sdk_set
if not exist "%LA%\Android\Sdk\platform-tools" goto :after_move
echo   Android SDK C: se L: par move ho raha hai (kuch minute)...
robocopy "%LA%\Android\Sdk" "L:\Android\Sdk" /E /MOVE /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul
:sdk_set
if exist "L:\Android\Sdk\platform-tools" (
    setx ANDROID_HOME "L:\Android\Sdk" >nul
    setx ANDROID_SDK_ROOT "L:\Android\Sdk" >nul
    echo   Android SDK   -^> L:\Android\Sdk
) else (
    echo   Android SDK move nahi hua - C: par hi rahega.
)
:after_move

echo [3/9] Gradle cache delete  (%U%\.gradle)...
if exist "%U%\.gradle" rd /s /q "%U%\.gradle" 2>nul
if exist "%U%\.gradle" echo   Kuch files use mein thin, baaqi delete ho gayi.

echo [4/9] Flutter package cache delete...
if exist "%LA%\Pub\Cache" rd /s /q "%LA%\Pub\Cache" 2>nul

echo [5/9] Temp files delete...
del /f /s /q "%TEMP%\*" >nul 2>nul
for /d %%D in ("%TEMP%\*") do rd /s /q "%%D" 2>nul
del /f /s /q "%SystemRoot%\Temp\*" >nul 2>nul
for /d %%D in ("%SystemRoot%\Temp\*") do rd /s /q "%%D" 2>nul

echo [6/9] Purani NexGrab / RSK builds delete...
if exist "C:\RSKBuild" rd /s /q "C:\RSKBuild" 2>nul
for %%P in ("%U%\Downloads" "%U%\Desktop") do (
    if exist "%%~P" for /f "delims=" %%N in ('dir /b /ad "%%~P" 2^>nul') do call :rskclean "%%~P\%%N"
)

echo [7/9] Flutter / Dart / Android ki baaqi caches (C:) delete...
for %%C in ("%APPDATA%\.dart" "%APPDATA%\.dart-tool" "%LA%\.dartServer" "%U%\.dartServer" "%U%\.dart-tool" "%U%\.dart" "%U%\.flutter-devtools" "%APPDATA%\Pub\Cache" "%U%\.android\build-cache" "%U%\.android\cache" "%U%\.kotlin" "%LA%\kotlin" "%U%\.m2\repository") do (
    if exist "%%~C" (
        echo   %%~C
        rd /s /q "%%~C" 2>nul
    )
)

echo [8/9] Flutter upgrade...
if defined NEW_GRADLE set "GRADLE_USER_HOME=%NEW_GRADLE%"
if defined NEW_PUB set "PUB_CACHE=%NEW_PUB%"
if defined NEW_TEMP set "TEMP=%NEW_TEMP%"
if defined NEW_TEMP set "TMP=%NEW_TEMP%"
set "FLUTTER_BAT="
for /f "delims=" %%F in ('where flutter.bat 2^>nul') do if not defined FLUTTER_BAT set "FLUTTER_BAT=%%F"
if not defined FLUTTER_BAT if defined FLUTTER_ROOT if exist "%FLUTTER_ROOT%\bin\flutter.bat" set "FLUTTER_BAT=%FLUTTER_ROOT%\bin\flutter.bat"
if not defined FLUTTER_BAT if exist "O:\flutter_windows_3.41.4-stable\flutter\bin\flutter.bat" set "FLUTTER_BAT=O:\flutter_windows_3.41.4-stable\flutter\bin\flutter.bat"
if not defined FLUTTER_BAT (
    echo   Flutter nahi mila - upgrade skip.
    goto :after_flutter
)
echo   Flutter: %FLUTTER_BAT%
where git >nul 2>nul
if errorlevel 1 (
    echo   Git install nahi - Flutter upgrade ke liye Git chahiye. Skip.
    echo   ^(Git yahan se: https://git-scm.com/download/win , phir ye file dobara chalayein^)
    goto :after_flutter
)
for %%F in ("%FLUTTER_BAT%") do set "FLUTTER_HOME=%%~dpF.."
if exist "%FLUTTER_HOME%\bin\cache\lockfile" del /f /q "%FLUTTER_HOME%\bin\cache\lockfile" >nul 2>nul
git config --global --add safe.directory "*" >nul 2>nul
call "%FLUTTER_BAT%" channel stable
call "%FLUTTER_BAT%" upgrade --force
if errorlevel 1 (
    echo   [!] Flutter upgrade fail hua - purana Flutter theek chalta rahega.
) else (
    echo   Flutter upgrade mukammal.
)
call "%FLUTTER_BAT%" --version
:after_flutter

echo [9/9] Recycle Bin khali...
powershell -NoProfile -Command "Clear-RecycleBin -DriveLetter C -Force -ErrorAction SilentlyContinue" >nul 2>nul

echo.
call :free "AB"
echo.
echo  ----------------------------------------------------------
echo   EXTRA (optional): Hibernate file (hiberfil.sys) band karna.
echo   Ye C: par kai GB leti hai. Band karne se "Hibernate" option
echo   chala jayega, Shut down / Sleep normal chalenge.
echo  ----------------------------------------------------------
choice /c YN /m "Hibernate band karke aur jagah khali karein"
if errorlevel 2 goto :done
powercfg -h off
echo   Hibernate band. Wapis chahiye ho to: powercfg -h on
call :free "AB"

:done
echo.
echo  Mukammal. PC RESTART karein, phir "NexGrab Builder.exe" chalayein.
echo  (Agli build libraries dobara download karegi - lekin L: par.)
echo.
pause
exit /b 0

:rskclean
rem only folders whose name starts with RSK or NexGrab
set "NAME=%~nx1"
set "OKNAME="
if /i "%NAME:~0,3%"=="RSK" set "OKNAME=1"
if /i "%NAME:~0,7%"=="NexGrab" set "OKNAME=1"
if not defined OKNAME exit /b 0
for %%B in ("android\build" "android\.dart_tool" "android\android\.gradle" "android\android\app\build" "RSK_Futuristic_Downloader\android\build" "RSK_Futuristic_Downloader\android\.dart_tool" "RSK_Futuristic_Downloader\android\android\.gradle" "RSK_Futuristic_Downloader\android\android\app\build" "RSK_Futuristic_Downloader\pc\build" "RSK_Futuristic_Downloader\pc\venv" "NexGrab\android\build" "NexGrab\android\.dart_tool" "NexGrab\android\android\.gradle" "NexGrab\android\android\app\build" "NexGrab\pc\build" "NexGrab\pc\.venv" "pc\build" "pc\.venv") do (
    if exist "%~1\%%~B" (
        echo   %~1\%%~B
        rd /s /q "%~1\%%~B" 2>nul
    )
)
exit /b 0

:free
for /f "usebackq delims=" %%G in (`powershell -NoProfile -Command "[math]::Round((Get-PSDrive C).Free/1GB,1)"`) do echo   %~1 C: par khali jagah: %%G GB
exit /b 0
