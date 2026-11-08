
// ---- RSK: yt-dlp engine (all websites) ----------------------------------
android {
    defaultConfig {
        minSdkVersion 24
    }
    packagingOptions {
        jniLibs {
            useLegacyPackaging = true
            excludes += ['lib/x86/**', 'lib/x86_64/**']
            keepDebugSymbols += ['**/*.zip.so']
        }
    }
}

dependencies {
    implementation "io.github.junkfood02.youtubedl-android:library:0.18.1"
    implementation "io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1"
}
