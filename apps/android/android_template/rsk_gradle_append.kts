
// ---- RSK: yt-dlp engine (all websites) ----------------------------------
android {
    defaultConfig {
        minSdk = 24
    }
    packaging {
        // yt-dlp's python / ffmpeg binaries must exist as real files on the phone
        jniLibs {
            useLegacyPackaging = true
            // phones are ARM: drop x86 copies of python/ffmpeg (saves ~1 GB build space)
            excludes += setOf("lib/x86/**", "lib/x86_64/**")
            // these are zip archives named .so - nothing to strip (removes llvm-strip noise)
            keepDebugSymbols += setOf("**/*.zip.so")
        }
    }
}

dependencies {
    implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1")
}
