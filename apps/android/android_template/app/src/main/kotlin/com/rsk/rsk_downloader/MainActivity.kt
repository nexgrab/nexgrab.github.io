package com.rsk.rsk_downloader

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.view.WindowManager
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    private val channelName = "rsk/native"
    private var channel: MethodChannel? = null
    private val worker = Executors.newFixedThreadPool(2)
    // yt-dlp jobs (info + several downloads) run on their own pool so they never block saving/merging.
    private val ytdlpPool = Executors.newCachedThreadPool()
    private var ytdlpReady = false
    private var cookiesResult: MethodChannel.Result? = null
    private val lastLineSent = java.util.concurrent.ConcurrentHashMap<String, Long>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingShared: String? = null
    private var permissionResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) pendingShared = sharedText(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val text = sharedText(intent) ?: return
        val ch = channel
        if (ch != null) ch.invokeMethod("shared", text) else pendingShared = text
    }

    private fun sharedText(i: Intent?): String? {
        if (i == null) return null
        return when (i.action) {
            Intent.ACTION_SEND -> i.getStringExtra(Intent.EXTRA_TEXT) ?: i.getStringExtra(Intent.EXTRA_SUBJECT)
            Intent.ACTION_VIEW -> i.dataString
            else -> null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "info" -> {
                        val work = File(filesDir, "work")
                        work.mkdirs()
                        result.success(
                            mapOf(
                                "work" to work.absolutePath,
                                "data" to filesDir.absolutePath,
                                "sdk" to Build.VERSION.SDK_INT
                            )
                        )
                    }
                    "takeShared" -> {
                        result.success(pendingShared)
                        pendingShared = null
                    }
                    "ensureStoragePermission" -> ensureStoragePermission(result)
                    "keepAwake" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        result.success(null)
                    }
                    "saveToDownloads" -> {
                        val path = call.argument<String>("path")!!
                        val name = call.argument<String>("name")!!
                        val mime = call.argument<String>("mime") ?: "application/octet-stream"
                        val folder = call.argument<String>("folder") ?: "NexGrab"
                        background(result) { saveToDownloads(File(path), name, mime, folder) }
                    }
                    "mux" -> {
                        val video = call.argument<String>("video")!!
                        val audio = call.argument<String>("audio")!!
                        val out = call.argument<String>("out")!!
                        val webm = call.argument<Boolean>("webm") ?: false
                        background(result) {
                            mux(video, audio, out, webm)
                            null
                        }
                    }
                    "ytdlpInit" -> background(result) { ytdlpInit() }
                    "ytdlpRun" -> {
                        val id = call.argument<String>("id")
                        val url = call.argument<String>("url")!!
                        val args = call.argument<List<String>>("args") ?: emptyList()
                        val stream = call.argument<Boolean>("stream") ?: false
                        ytdlpPool.execute {
                            val res = ytdlpRun(id, url, args, stream)
                            mainHandler.post { result.success(res) }
                        }
                    }
                    "ytdlpCancel" -> {
                        val id = call.argument<String>("id")!!
                        result.success(YoutubeDL.getInstance().destroyProcessById(id))
                    }
                    "ytdlpUpdate" -> background(result) {
                        ytdlpInit()
                        val st = YoutubeDL.getInstance().updateYoutubeDL(applicationContext, YoutubeDL.UpdateChannel.STABLE)
                        mapOf("status" to (st?.name ?: ""), "version" to ytdlpVersion())
                    }
                    "pickCookies" -> pickCookies(result)
                    "open" -> {
                        openUri(call.argument<String>("uri")!!, call.argument<String>("mime") ?: "*/*")
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Throwable) {
                result.error("native", e.message ?: e.toString(), null)
            }
        }
    }

    override fun onDestroy() {
        channel?.setMethodCallHandler(null)
        channel = null
        super.onDestroy()
    }

    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (e: Throwable) {
                mainHandler.post { result.error("native", e.message ?: e.toString(), null) }
            }
        }
    }

    // ------------------------------------------------------------------ yt-dlp (all sites)

    @Synchronized
    private fun ytdlpInit(): Map<String, Any?> {
        if (!ytdlpReady) {
            YoutubeDL.getInstance().init(applicationContext)
            FFmpeg.getInstance().init(applicationContext)
            ytdlpReady = true
        }
        return mapOf("version" to ytdlpVersion())
    }

    private fun ytdlpVersion(): String =
        YoutubeDL.getInstance().versionName(applicationContext)
            ?: YoutubeDL.getInstance().version(applicationContext) ?: ""

    /** Runs yt-dlp. Never throws: returns code (0 ok, 1 error, -2 canceled), stdout and stderr. */
    private fun ytdlpRun(id: String?, url: String, args: List<String>, stream: Boolean): Map<String, Any?> {
        return try {
            ytdlpInit()
            val request = YoutubeDLRequest(url)
            request.addCommands(args)
            val callback: ((Float, Long, String) -> Unit)? = if (stream && id != null) fun(_: Float, _: Long, line: String) {
                // Progress lines are throttled; every other line (file paths, errors) always goes through.
                val now = System.currentTimeMillis()
                val isProgress = line.startsWith("RSKP")
                val last = lastLineSent[id] ?: 0L
                if (!isProgress || now - last > 300) {
                    if (isProgress) lastLineSent[id] = now
                    mainHandler.post { channel?.invokeMethod("ytdlpLine", mapOf("id" to id, "line" to line)) }
                }
            } else null
            val response = YoutubeDL.getInstance().execute(request, id, callback)
            mapOf("code" to response.exitCode, "out" to response.out, "err" to response.err)
        } catch (e: YoutubeDL.CanceledException) {
            mapOf("code" to -2, "out" to "", "err" to "canceled")
        } catch (e: Throwable) {
            mapOf("code" to 1, "out" to "", "err" to (e.message ?: e.toString()))
        } finally {
            if (id != null) lastLineSent.remove(id)
        }
    }

    private fun pickCookies(result: MethodChannel.Result) {
        cookiesResult?.success(null)
        cookiesResult = result
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        try {
            startActivityForResult(i, COOKIES_REQUEST)
        } catch (e: Throwable) {
            cookiesResult = null
            result.error("native", "File picker nahi khula", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != COOKIES_REQUEST) return
        val r = cookiesResult ?: return
        cookiesResult = null
        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            r.success(null)
            return
        }
        worker.execute {
            try {
                val dest = File(filesDir, "cookies.txt")
                val input = contentResolver.openInputStream(uri) ?: throw IllegalStateException("File read nahi hui")
                input.use { i -> dest.outputStream().use { o -> i.copyTo(o) } }
                mainHandler.post { r.success(dest.absolutePath) }
            } catch (e: Throwable) {
                mainHandler.post { r.error("native", e.message ?: e.toString(), null) }
            }
        }
    }

    // ------------------------------------------------------------------ storage

    private fun ensureStoragePermission(result: MethodChannel.Result) {
        // Android 10+ saves through MediaStore and needs no permission.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q || Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.success(true)
            return
        }
        if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        permissionResult?.success(false)
        permissionResult = result
        requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), STORAGE_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == STORAGE_REQUEST) {
            val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            permissionResult?.success(granted)
            permissionResult = null
        }
    }

    private fun saveToDownloads(src: File, name: String, mime: String, folder: String): Map<String, String> {
        if (!src.exists()) throw IllegalStateException("Downloaded file missing")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = contentResolver
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/" + folder)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val uri = resolver.insert(collection, values)
                ?: throw IllegalStateException("Downloads folder mein file nahi ban saki")
            try {
                val out = resolver.openOutputStream(uri) ?: throw IllegalStateException("Cannot write to Downloads")
                out.use { o -> FileInputStream(src).use { i -> i.copyTo(o, 256 * 1024) } }
                val done = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
                resolver.update(uri, done, null, null)
            } catch (e: Throwable) {
                resolver.delete(uri, null, null)
                throw e
            }
            var finalName = name
            resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) finalName = c.getString(0) ?: name
            }
            return mapOf(
                "uri" to uri.toString(),
                "path" to Environment.DIRECTORY_DOWNLOADS + "/" + folder + "/" + finalName,
                "name" to finalName
            )
        }

        @Suppress("DEPRECATION")
        val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
        val dir = File(downloads, folder)
        if (!dir.exists() && !dir.mkdirs()) throw IllegalStateException("Cannot create ${dir.absolutePath}")
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var target = File(dir, name)
        var n = 1
        while (target.exists()) {
            target = File(dir, "$base ($n)$ext")
            n++
        }
        src.copyTo(target)
        val latch = CountDownLatch(1)
        var scanned: Uri? = null
        MediaScannerConnection.scanFile(this, arrayOf(target.absolutePath), arrayOf(mime)) { _, u ->
            scanned = u
            latch.countDown()
        }
        latch.await(10, TimeUnit.SECONDS)
        return mapOf(
            "uri" to (scanned?.toString() ?: Uri.fromFile(target).toString()),
            "path" to target.absolutePath,
            "name" to target.name
        )
    }

    private fun openUri(uriString: String, mime: String) {
        val uri = Uri.parse(uriString)
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivity(Intent.createChooser(view, "Open with"))
        } catch (e: ActivityNotFoundException) {
            throw IllegalStateException("Is file ko kholne wali koi app nahi mili")
        }
    }

    // ------------------------------------------------------------------ merge (no FFmpeg needed)

    /** Copies the video track of [videoPath] and audio track of [audioPath] into one file. */
    private fun mux(videoPath: String, audioPath: String, outPath: String, webm: Boolean) {
        File(outPath).delete()
        val videoEx = MediaExtractor()
        val audioEx = MediaExtractor()
        var muxer: MediaMuxer? = null
        var started = false
        try {
            videoEx.setDataSource(videoPath)
            audioEx.setDataSource(audioPath)
            val vIndex = findTrack(videoEx, "video/")
            val aIndex = findTrack(audioEx, "audio/")
            if (vIndex < 0) throw IllegalStateException("Video track nahi mila")
            if (aIndex < 0) throw IllegalStateException("Audio track nahi mila")
            videoEx.selectTrack(vIndex)
            audioEx.selectTrack(aIndex)
            val vFormat = videoEx.getTrackFormat(vIndex)
            val aFormat = audioEx.getTrackFormat(aIndex)

            val format = if (webm) MediaMuxer.OutputFormat.MUXER_OUTPUT_WEBM else MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4
            val m = MediaMuxer(outPath, format)
            muxer = m
            val vTrack = m.addTrack(vFormat)
            val aTrack = m.addTrack(aFormat)
            m.start()
            started = true

            var capacity = maxOf(maxInput(vFormat), maxInput(aFormat), 4 * 1024 * 1024)
            var buffer = ByteBuffer.allocateDirect(capacity)
            val info = MediaCodec.BufferInfo()
            var videoDone = false
            var audioDone = false
            while (!videoDone || !audioDone) {
                // Interleave by timestamp so the file is written in order.
                val useVideo = when {
                    videoDone -> false
                    audioDone -> true
                    else -> videoEx.sampleTime <= audioEx.sampleTime
                }
                val ex = if (useVideo) videoEx else audioEx
                buffer.clear()
                var size: Int
                try {
                    size = ex.readSampleData(buffer, 0)
                } catch (e: IllegalArgumentException) {
                    capacity *= 2
                    buffer = ByteBuffer.allocateDirect(capacity)
                    size = ex.readSampleData(buffer, 0)
                }
                if (size < 0) {
                    if (useVideo) videoDone = true else audioDone = true
                    continue
                }
                info.offset = 0
                info.size = size
                info.presentationTimeUs = maxOf(0L, ex.sampleTime)
                info.flags = if ((ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                m.writeSampleData(if (useVideo) vTrack else aTrack, buffer, info)
                ex.advance()
            }
            m.stop()
            started = false
        } catch (e: Throwable) {
            File(outPath).delete()
            throw IllegalStateException("Video + audio merge fail: ${e.message ?: e}", e)
        } finally {
            try {
                if (started) muxer?.stop()
            } catch (_: Throwable) {
            }
            try {
                muxer?.release()
            } catch (_: Throwable) {
            }
            videoEx.release()
            audioEx.release()
        }
    }

    private fun findTrack(ex: MediaExtractor, prefix: String): Int {
        for (i in 0 until ex.trackCount) {
            val mime = ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith(prefix)) return i
        }
        return -1
    }

    private fun maxInput(f: MediaFormat): Int =
        if (f.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) f.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE) else 0

    companion object {
        private const val STORAGE_REQUEST = 4711
        private const val COOKIES_REQUEST = 4712
    }
}
