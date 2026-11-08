@echo off
setlocal EnableExtensions EnableDelayedExpansion
title NexGrab v3.2 - APK Builder
cd /d "%~dp0"
set "NOPAUSE=%~1"
set "LOG=%CD%\build_apk.log"
set "TOOLS=%CD%\.tools"
set "APK_OUT=%CD%\APK\NexGrab.apk"
if not exist "%TOOLS%" mkdir "%TOOLS%"

> "%LOG%" echo NexGrab APK build started %date% %time%

echo ================================================================
echo        NEXGRAB v3.2  -  APK BUILDER
echo ================================================================
echo  Aapka INSTALLED Flutter use hota hai. Flutter dobara download
echo  NAHI hota (sirf tab jab PC par Flutter bilkul na ho).
echo  Log: %LOG%
echo ================================================================
echo.

rem ================================================================
rem [1/7] JAVA 17+
rem ================================================================
echo [1/7] Java 17+ check...
set "JDK_HOME="
for %%D in ("C:\Program Files\Android\Android Studio\jbr") do if exist "%%~D\bin\java.exe" set "JDK_HOME=%%~D"
if not defined JDK_HOME call :findjdk
if not defined JDK_HOME (
    echo Java 17 nahi mila. winget se install kar rahe hain ^(ek dafa^)...
    winget install -e --id Microsoft.OpenJDK.17 --silent --accept-package-agreements --accept-source-agreements
    call :findjdk
)
if not defined JDK_HOME (
    echo [ERROR] Java 17 install nahi ho saka. https://learn.microsoft.com/java/openjdk/download se JDK 17 install karein.
    goto :failed
)
set "JAVA_HOME=%JDK_HOME%"
set "PATH=%JAVA_HOME%\bin;%PATH%"
echo   Java: %JAVA_HOME%
>>"%LOG%" echo JAVA_HOME=%JAVA_HOME%
echo.

rem ================================================================
rem [2/7] FLUTTER - use the one already installed
rem ================================================================
echo [2/7] Installed Flutter dhoond rahe hain...
set "FLUTTER_BAT="
for /f "delims=" %%F in ('where flutter.bat 2^>nul') do if not defined FLUTTER_BAT set "FLUTTER_BAT=%%F"
if not defined FLUTTER_BAT if defined FLUTTER_ROOT if exist "%FLUTTER_ROOT%\bin\flutter.bat" set "FLUTTER_BAT=%FLUTTER_ROOT%\bin\flutter.bat"
if not defined FLUTTER_BAT for %%D in ("C:\flutter" "C:\src\flutter" "C:\dev\flutter" "C:\tools\flutter" "D:\flutter" "D:\src\flutter" "E:\flutter" "%USERPROFILE%\flutter" "%USERPROFILE%\dev\flutter" "%USERPROFILE%\Documents\flutter" "%USERPROFILE%\Downloads\flutter" "%USERPROFILE%\Desktop\flutter" "%LOCALAPPDATA%\flutter" "%TOOLS%\flutter") do (
    if not defined FLUTTER_BAT if exist "%%~D\bin\flutter.bat" set "FLUTTER_BAT=%%~D\bin\flutter.bat"
)

if defined FLUTTER_BAT (
    echo   Mil gaya: !FLUTTER_BAT!
    rem Leftovers of the old builder's 1 GB download are no longer needed.
    if exist "%TOOLS%\flutter_stable.zip" del /q "%TOOLS%\flutter_stable.zip" >nul 2>nul
) else (
    echo   PC par Flutter nahi mila. Ek dafa download karna padega.
    call :get_flutter
    if errorlevel 1 goto :failed
    set "FLUTTER_BAT=%TOOLS%\flutter\bin\flutter.bat"
)
>>"%LOG%" echo FLUTTER_BAT=%FLUTTER_BAT%
rem A stale lock file makes Flutter wait forever ("Waiting for another flutter command...").
for %%F in ("%FLUTTER_BAT%") do set "FLUTTER_HOME=%%~dpF.."
if exist "%FLUTTER_HOME%\bin\cache\lockfile" del /f /q "%FLUTTER_HOME%\bin\cache\lockfile" >nul 2>nul
echo.
echo   Agar yahan 10 minute se zyada ruk jaye to Ctrl+C dabayein aur screenshot bhejein.
echo   Flutter version ^(pehli dafa Flutter apna Dart SDK ~200 MB khud leta hai, sirf ek baar^):
call "%FLUTTER_BAT%" --version
if errorlevel 1 (
    echo [ERROR] Flutter chal nahi raha. Upar ka error dekhein.
    goto :failed
)
call "%FLUTTER_BAT%" --version >>"%LOG%" 2>&1
call "%FLUTTER_BAT%" config --no-analytics --enable-android --jdk-dir="%JDK_HOME%" >>"%LOG%" 2>&1
echo.

rem ================================================================
rem [3/7] ANDROID SDK (no Android Studio needed)
rem ================================================================
echo [3/7] Android SDK check...
set "SDK="
for %%S in ("%ANDROID_HOME%" "%ANDROID_SDK_ROOT%" "%LOCALAPPDATA%\Android\Sdk" "C:\Android\Sdk" "C:\Android\sdk") do (
    if not defined SDK if not "%%~S"=="" if exist "%%~S\platform-tools" set "SDK=%%~S"
)
if not defined SDK set "SDK=%LOCALAPPDATA%\Android\Sdk"
set "SDKMANAGER="
for %%M in ("%SDK%\cmdline-tools\latest\bin\sdkmanager.bat") do if exist "%%~M" set "SDKMANAGER=%%~M"
if not defined SDKMANAGER for /f "delims=" %%V in ('dir /b /ad "%SDK%\cmdline-tools" 2^>nul') do if exist "%SDK%\cmdline-tools\%%V\bin\sdkmanager.bat" set "SDKMANAGER=%SDK%\cmdline-tools\%%V\bin\sdkmanager.bat"

if not defined SDKMANAGER (
    echo   Android command-line tools nahi mile. Install kar rahe hain ^(~150 MB, ek dafa^)...
    call :get_cmdline_tools
    if errorlevel 1 goto :failed
    set "SDKMANAGER=%SDK%\cmdline-tools\latest\bin\sdkmanager.bat"
)
echo   SDK: %SDK%
>>"%LOG%" echo SDK=%SDK%
set "ANDROID_HOME=%SDK%"
set "ANDROID_SDK_ROOT=%SDK%"

echo   Licenses accept kar rahe hain...
if exist "%TOOLS%\yes.txt" del /q "%TOOLS%\yes.txt"
for /l %%i in (1,1,40) do echo y>>"%TOOLS%\yes.txt"
call "%SDKMANAGER%" --sdk_root="%SDK%" --licenses < "%TOOLS%\yes.txt" >>"%LOG%" 2>&1
if not exist "%SDK%\platform-tools" (
    echo   SDK packages install ho rahe hain ^(platform-tools, Android 36, build-tools^)...
    call "%SDKMANAGER%" --sdk_root="%SDK%" "platform-tools" "platforms;android-36" "build-tools;35.0.0"
    if errorlevel 1 (
        echo [ERROR] SDK packages install nahi hue. Internet check karein.
        goto :failed
    )
)
call "%FLUTTER_BAT%" config --android-sdk "%SDK%" >>"%LOG%" 2>&1
echo.

rem ================================================================
rem [4/7] FRESH ANDROID PROJECT FILES + RSK TEMPLATE
rem ================================================================
echo [4/7] Android project files...
if exist "%CD%\android" rmdir /s /q "%CD%\android"
call "%FLUTTER_BAT%" create . --platforms=android --org com.rsk --project-name rsk_downloader >>"%LOG%" 2>&1
if errorlevel 1 (
    echo [ERROR] flutter create fail hua. Log dekhein.
    goto :failed
)
if not exist "%CD%\android_template\app\src\main\AndroidManifest.xml" (
    echo [ERROR] android_template folder missing. ZIP dobara extract karein.
    goto :failed
)
xcopy "%CD%\android_template\*" "%CD%\android\" /E /Y /I /Q >>"%LOG%" 2>&1
findstr /C:"android.permission.INTERNET" "%CD%\android\app\src\main\AndroidManifest.xml" >nul
if errorlevel 1 (
    echo [ERROR] Manifest apply nahi hua.
    goto :failed
)
if not exist "%CD%\android\app\src\main\kotlin\com\rsk\rsk_downloader\MainActivity.kt" (echo [ERROR] MainActivity.kt copy nahi hui. & goto :failed)

rem yt-dlp engine (all websites): add the library to app/build.gradle(.kts)
set "GRADLE_FILE=%CD%\android\app\build.gradle"
if exist "%CD%\android\app\build.gradle.kts" (
    set "GRADLE_FILE=%CD%\android\app\build.gradle.kts"
    type "%CD%\android_template\rsk_gradle_append.kts" >> "%CD%\android\app\build.gradle.kts"
) else (
    type "%CD%\android_template\rsk_gradle_append.groovy" >> "%CD%\android\app\build.gradle"
)
findstr /C:"youtubedl-android" "%GRADLE_FILE%" >nul
if errorlevel 1 (
    echo [ERROR] yt-dlp library gradle mein add nahi hui.
    goto :failed
)
del /q "%CD%\android\rsk_gradle_append.kts" "%CD%\android\rsk_gradle_append.groovy" >nul 2>nul

rem This app has no C/C++ code. Without NDK installed, skip the ~1 GB NDK auto-download.
if not exist "%SDK%\ndk" (
    powershell -NoProfile -Command "foreach($f in 'android\app\build.gradle.kts','android\app\build.gradle'){ if(Test-Path $f){ (Get-Content $f) | Where-Object { $_ -notmatch 'ndkVersion' } | Set-Content $f } }" >>"%LOG%" 2>&1
)
echo   OK
echo.

rem ================================================================
rem [5/7] PACKAGES
rem ================================================================
echo [5/7] Flutter packages...
call "%FLUTTER_BAT%" pub get
if errorlevel 1 goto :failed
echo.

rem ================================================================
rem [6/7] BUILD
rem ================================================================
set "FREE_GB="
for /f "usebackq delims=" %%G in (`powershell -NoProfile -Command "[math]::Floor((Get-Item -LiteralPath '%CD%').PSDrive.Free/1GB)" 2^>nul`) do set "FREE_GB=%%G"
set "GHOME=%USERPROFILE%"
if defined GRADLE_USER_HOME if exist "%GRADLE_USER_HOME:~0,3%" set "GHOME=%GRADLE_USER_HOME%"
set "FREE_C="
for /f "usebackq delims=" %%G in (`powershell -NoProfile -Command "[math]::Floor((Get-Item -LiteralPath '%GHOME:~0,3%').PSDrive.Free/1GB)" 2^>nul`) do set "FREE_C=%%G"
if defined FREE_GB echo   Khali jagah: project drive %CD:~0,2% = %FREE_GB% GB,  Gradle cache drive %GHOME:~0,2% = %FREE_C% GB
if defined FREE_GB if %FREE_GB% LSS 4 goto :nospace
if defined FREE_C if %FREE_C% LSS 3 goto :nospace
echo.
echo [6/7] Release APK build ho rahi hai...
echo   Pehli build: Gradle + Flutter engine + yt-dlp library download hoti hain ^(15-25 min^).
echo   Agli builds: 1-3 minute.
set "RSK_V="
if "%RSK_VERBOSE%"=="1" set "RSK_V=-v"
call "%FLUTTER_BAT%" build apk --release --split-per-abi --target-platform android-arm,android-arm64 %RSK_V%
if errorlevel 1 (
    echo.
    echo Build fail. Doctor report log mein likh rahe hain...
    call "%FLUTTER_BAT%" doctor -v >>"%LOG%" 2>&1
    goto :failed
)
set "SOURCE_APK=%CD%\build\app\outputs\flutter-apk\app-arm64-v8a-release.apk"
set "SOURCE_APK32=%CD%\build\app\outputs\flutter-apk\app-armeabi-v7a-release.apk"
if not exist "%SOURCE_APK%" (
    echo [ERROR] app-release.apk nahi mili.
    goto :failed
)
echo.

rem ================================================================
rem [7/7] FINAL APK
rem ================================================================
echo [7/7] Final APK...
if not exist "%CD%\APK" mkdir "%CD%\APK"
copy /Y "%SOURCE_APK%" "%APK_OUT%" >nul
if exist "%SOURCE_APK32%" copy /Y "%SOURCE_APK32%" "%CD%\APK\NexGrab_32bit.apk" >nul
if not exist "%APK_OUT%" goto :failed

echo.
echo ================================================================
echo                        BUILD SUCCESS
echo ================================================================
echo   %APK_OUT%
echo   ^(Purane / 32-bit phone ke liye: APK\NexGrab_32bit.apk^)
echo.
if /i not "%NOPAUSE%"=="nopause" (
    start "" "%CD%\APK"
    echo Koi bhi key dabayein...
    pause >nul
)
exit /b 0


rem ================================================================
rem  Helpers
rem ================================================================
:findjdk
rem Only JDK 21 / 17 (Gradle does not support very new Java like 25).
for %%B in ("C:\Program Files\Eclipse Adoptium" "C:\Program Files\Microsoft" "C:\Program Files\Java" "C:\Program Files\Zulu") do (
    for %%P in (21 17) do (
        for /f "delims=" %%J in ('dir /b /ad "%%~B\jdk-%%P*" 2^>nul') do (
            if exist "%%~B\%%J\bin\java.exe" set "JDK_HOME=%%~B\%%J"
        )
    )
)
exit /b 0

:get_flutter
rem Fast + resumable. Never PowerShell Invoke-WebRequest (that was the all-night "bytes written").
where git >nul 2>nul
if not errorlevel 1 (
    if exist "%TOOLS%\flutter" rmdir /s /q "%TOOLS%\flutter"
    echo   git se Flutter stable clone ho raha hai...
    git clone --depth 1 -b stable https://github.com/flutter/flutter.git "%TOOLS%\flutter"
    if not errorlevel 1 exit /b 0
)
echo   curl se Flutter zip ^(resume support ke saath^)...
powershell -NoProfile -Command "$ProgressPreference='SilentlyContinue'; $j=Invoke-RestMethod 'https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json'; $r=$j.releases | ? { $_.hash -eq $j.current_release.stable } | select -First 1; 'https://storage.googleapis.com/flutter_infra_release/releases/' + $r.archive" > "%TOOLS%\flutter_url.txt"
set /p FLUTTER_URL=<"%TOOLS%\flutter_url.txt"
if not defined FLUTTER_URL exit /b 1
curl.exe -L --fail --retry 5 -C - -o "%TOOLS%\flutter_stable.zip" "%FLUTTER_URL%"
if errorlevel 1 exit /b 1
if exist "%TOOLS%\flutter" rmdir /s /q "%TOOLS%\flutter"
echo   Extract ho raha hai...
tar -xf "%TOOLS%\flutter_stable.zip" -C "%TOOLS%"
if errorlevel 1 exit /b 1
del /q "%TOOLS%\flutter_stable.zip"
exit /b 0

:get_cmdline_tools
if not exist "%SDK%" mkdir "%SDK%"
set "CLT_ZIP=%TOOLS%\cmdline-tools.zip"
del /q "%CLT_ZIP%.ok" >nul 2>nul
for %%B in (14742923 13114758 11076708) do (
    if not exist "%CLT_ZIP%.ok" (
        del /q "%CLT_ZIP%" >nul 2>nul
        curl.exe -L --fail --retry 3 -o "%CLT_ZIP%" "https://dl.google.com/android/repository/commandlinetools-win-%%B_latest.zip"
        if not errorlevel 1 echo ok> "%CLT_ZIP%.ok"
    )
)
if not exist "%CLT_ZIP%.ok" (
    echo [ERROR] Android command-line tools download nahi hue.
    exit /b 1
)
rem Extract inside the SDK folder itself so the final "move" never crosses drives.
set "CLT_TMP=%SDK%\cmdline-tools\_rsk_tmp"
if exist "%CLT_TMP%" rmdir /s /q "%CLT_TMP%"
mkdir "%CLT_TMP%"
tar -xf "%CLT_ZIP%" -C "%CLT_TMP%"
if errorlevel 1 exit /b 1
if exist "%SDK%\cmdline-tools\latest" rmdir /s /q "%SDK%\cmdline-tools\latest"
move "%CLT_TMP%\cmdline-tools" "%SDK%\cmdline-tools\latest" >nul
if errorlevel 1 exit /b 1
rmdir /s /q "%CLT_TMP%" >nul 2>nul
del /q "%CLT_ZIP%" "%CLT_ZIP%.ok" >nul 2>nul
setx ANDROID_HOME "%SDK%" >nul
exit /b 0


:nospace
echo.
echo [ERROR] Disk par jagah kam hai. APK build ke liye chahiye:
echo         project drive par kam az kam 4 GB, aur %GHOME:~0,2% drive par 3 GB.
echo   Jagah khali karne ke tareeqe:
echo     - Purane extract kiye hue NexGrab / RSK project folders delete karein (har ek ke andar android\build kai GB ka hota hai)
echo     - C:\RSKBuild ke purane folders delete karein
echo     - Recycle Bin khali karein, Win+R mein %%TEMP%% likh kar wahan ki files delete karein
echo     - Ya project ko kisi aur drive par extract karein jahan jagah ho
goto :failed

:failed
echo.
echo ================================================================
echo                         BUILD FAILED
echo ================================================================
echo   Log: %LOG%
echo   Is log ya screen ka screenshot bhej dein.
echo.
if /i not "%NOPAUSE%"=="nopause" pause
exit /b 1
