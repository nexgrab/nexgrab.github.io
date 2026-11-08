#!/usr/bin/env bash
# Linux/macOS version of MAKE_APK.cmd step 4 (used by GitHub Actions).
set -euo pipefail
cd "$(dirname "$0")/../apps/android"
rm -rf android
flutter create . --platforms=android --org com.rsk --project-name rsk_downloader >/dev/null
cp -r android_template/. android/
if [ -f android/app/build.gradle.kts ]; then
  cat android_template/rsk_gradle_append.kts >> android/app/build.gradle.kts; G=android/app/build.gradle.kts
else
  cat android_template/rsk_gradle_append.groovy >> android/app/build.gradle; G=android/app/build.gradle
fi
grep -q youtubedl-android "$G"
rm -f android/rsk_gradle_append.kts android/rsk_gradle_append.groovy
grep -q android.permission.INTERNET android/app/src/main/AndroidManifest.xml
test -f android/app/src/main/kotlin/com/rsk/rsk_downloader/MainActivity.kt
echo "Android project ready ($G)"
