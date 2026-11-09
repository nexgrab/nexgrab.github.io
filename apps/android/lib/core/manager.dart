import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'fetcher.dart';
import 'models.dart';
import 'net.dart';
import 'resolver.dart';
import 'ytdlp.dart';

class SavedFile {
  SavedFile({required this.uri, required this.path, required this.name});
  final String uri;
  final String path;
  final String name;
}

/// Everything that needs Android APIs. The app uses a MethodChannel implementation;
/// tests use a plain-Dart fake.
abstract class NativeBridge {
  int get sdkInt;
  Future<String> workDir();
  Future<String> dataDir();
  Future<bool> ensureStoragePermission();
  Future<SavedFile> saveToDownloads(String path, String name, String mime, String folder);
  Future<void> mux(String videoPath, String audioPath, String outPath, {required bool webm});
  Future<void> open(String uri, String mime);
  Future<void> keepAwake(bool on);

  // yt-dlp engine (all websites) - runs inside the app via youtubedl-android
  Future<String> ytdlpInit();
  Future<YtdlpResult> ytdlpRun({String? id, required String url, required List<String> args, bool stream = false});
  Future<void> ytdlpCancel(String id);
  Future<String> ytdlpUpdate();
  Future<String?> pickCookies();
  Stream<YtdlpLine> get ytdlpLines;
}

class YtdlpLine {
  YtdlpLine(this.id, this.line);
  final String id;
  final String line;
}

class DownloadManager {
  DownloadManager(this.native);

  final NativeBridge native;
  final AppSettings settings = AppSettings();
  final List<DownloadTask> tasks = [];
  final List<HistoryEntry> history = [];

  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  final Map<String, CancelToken> _tokens = {};
  final Map<String, int> _lastBytes = {};
  late Directory _work;
  late Directory _data;
  Timer? _ticker;
  bool _dirty = false;
  bool _awake = false;
  bool _ready = false;

  bool get ready => _ready;

  // yt-dlp engine state
  String ytdlpVersion = '';
  String ytdlpInitError = '';
  bool ytdlpReady = false;
  bool ytdlpUpdating = false;
  // The library's updater deletes + rewrites the yt-dlp file. Python reading it at the same
  // moment crashes (Traceback). So updates wait for running jobs, and jobs wait for updates.
  Completer<void>? _updateGate;
  int _ytdlpActive = 0;
  Future<bool>? _ytdlpInit;

  Future<void> init() async {
    _work = Directory(await native.workDir());
    _data = Directory(await native.dataDir());
    await _work.create(recursive: true);
    await _data.create(recursive: true);

    final s = await _readJson('settings.json');
    if (s is Map) settings.load(s.cast<String, dynamic>());

    final h = await _readJson('history.json');
    if (h is List) {
      for (final e in h) {
        try {
          history.add(HistoryEntry.fromJson((e as Map).cast<String, dynamic>()));
        } catch (_) {}
      }
    }

    final q = await _readJson('queue.json');
    if (q is List) {
      for (final e in q) {
        try {
          final t = DownloadTask.fromJson((e as Map).cast<String, dynamic>());
          // Anything that was running when the app closed waits for the user to resume.
          if (t.status.isActive) t.status = TaskStatus.paused;
          tasks.add(t);
        } catch (_) {}
      }
    }
    await refreshTor();
    _ytdlpInit = _initYtdlp();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => _tick());
    _ready = true;
    _notify();
    _pump();
  }

  void dispose() {
    _ticker?.cancel();
    for (final t in _tokens.values) {
      t.pause();
    }
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  // ------------------------------------------------------------------ routes / analyze

  /// Auto mode: last Tor detection result (null = not checked / not in auto mode).
  bool? torUp;
  int _tickCount = 0;

  /// The route actually used right now. In Auto mode: Tor if Orbot is running, else Direct
  /// (same as the PC app: open Tor, paste link, it goes through Tor).
  NetRoute get route {
    if (settings.route == RouteMode.auto) {
      return NetRoute(torUp == true ? RouteMode.tor : RouteMode.direct);
    }
    return NetRoute.fromSettings(settings);
  }

  String get routeLabel {
    if (settings.route != RouteMode.auto) return route.label;
    return torUp == true ? 'Auto → Tor (Orbot connected)' : 'Auto → Direct (Tor band hai)';
  }

  Future<void> refreshTor() async {
    if (settings.route != RouteMode.auto) {
      if (torUp != null) {
        torUp = null;
        _notify();
      }
      return;
    }
    final up = await torRunning();
    if (up != torUp) {
      torUp = up;
      _notify();
    }
  }

  NetRoute _routeFor(int failedAttempts) {
    final r = route;
    // Never fall back to Direct when the user explicitly chose Tor (no IP leak).
    if (settings.smartFallback && r.mode != RouteMode.direct && settings.route != RouteMode.tor && failedAttempts >= 2) {
      return NetRoute(RouteMode.direct);
    }
    return r;
  }

  Resolver _resolver([NetRoute? r]) => Resolver(r ?? route, webmMerge: native.sdkInt >= 29);

  Future<bool> _initYtdlp() async {
    try {
      ytdlpVersion = await native.ytdlpInit();
      ytdlpReady = true;
      ytdlpInitError = '';
      _notify();
      // Sites change often: refresh yt-dlp in the background every 3 days.
      final age = DateTime.now().millisecondsSinceEpoch - settings.lastYtdlpUpdate;
      if (age > const Duration(days: 3).inMilliseconds) unawaited(updateYtdlp().catchError((_) => ''));
      return true;
    } catch (e) {
      ytdlpReady = false;
      ytdlpInitError = friendlyError(e);
      _notify();
      return false;
    }
  }

  /// Downloads the latest yt-dlp. Returns the new version.
  Future<String> updateYtdlp() async {
    if (ytdlpUpdating) return ytdlpVersion;
    ytdlpUpdating = true;
    _notify();
    try {
      if (_ytdlpInit != null) await _ytdlpInit;
      // wait (max 15 min) until no yt-dlp process is running, then lock out new ones
      final until = DateTime.now().add(const Duration(minutes: 15));
      while (_ytdlpActive > 0 && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      if (_ytdlpActive > 0) throw UserFacingException('Downloads chal rahe hain. Khatam hone ke baad Update karein.');
      _updateGate = Completer<void>();
      final v = await native.ytdlpUpdate();
      if (v.isNotEmpty) ytdlpVersion = v;
      ytdlpReady = true;
      settings.lastYtdlpUpdate = DateTime.now().millisecondsSinceEpoch;
      await _writeJson('settings.json', settings.toJson());
      return ytdlpVersion;
    } finally {
      final g = _updateGate;
      _updateGate = null;
      if (g != null && !g.isCompleted) g.complete();
      ytdlpUpdating = false;
      _notify();
    }
  }

  /// Runs yt-dlp safely: waits for an update in progress; retries once if the engine crashed.
  Future<YtdlpResult> _ytdlp({String? id, required String url, required List<String> args, bool stream = false}) async {
    for (var attempt = 0;; attempt++) {
      while (_updateGate != null) {
        await _updateGate!.future.timeout(const Duration(minutes: 3), onTimeout: () {});
        if (_updateGate != null && !ytdlpUpdating) break;
      }
      _ytdlpActive++;
      final YtdlpResult res;
      try {
        res = await native.ytdlpRun(id: id, url: url, args: List.of(args), stream: stream);
      } finally {
        _ytdlpActive--;
      }
      if (res.ok || res.canceled || attempt >= 1 || !isEngineCrash(res.err)) return res;
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  Future<bool> pickCookies() async {
    final p = await native.pickCookies();
    if (p == null || p.isEmpty) return false;
    settings.cookieFile = p;
    await saveSettings();
    return true;
  }

  Future<void> clearCookies() async {
    settings.cookieFile = '';
    await saveSettings();
  }

  String? get _cookies => settings.cookieFile.isEmpty || !File(settings.cookieFile).existsSync() ? null : settings.cookieFile;

  /// Proxy string for yt-dlp for the current route ('' = direct).
  Future<String> _ytdlpProxy() async {
    final r = route;
    switch (r.mode) {
      case RouteMode.direct:
      case RouteMode.auto:
        return '';
      case RouteMode.tor:
        if (await socks5Alive(torSocksPort)) return 'socks5h://127.0.0.1:$torSocksPort';
        return 'http://$torHttpProxy';
      case RouteMode.custom:
        final p = r.proxy;
        return p == null ? '' : 'http://$p';
    }
  }

  /// May yt-dlp retry on Direct after [err]? Never when the user picked "Tor only".
  bool _mayRetryDirect(String proxy, String err) {
    if (proxy.isEmpty || settings.route == RouteMode.tor) return false;
    if (settings.route == RouteMode.auto && isBotCheck(err)) return true; // YouTube blocks Tor exits
    return settings.smartFallback && isYtdlpNetworkError(err);
  }

  Future<bool> _ytdlpAvailable() async {
    if (ytdlpReady) return true;
    if (_ytdlpInit == null) return false;
    try {
      return await _ytdlpInit!.timeout(const Duration(seconds: 90));
    } catch (_) {
      return false;
    }
  }

  Future<MediaInfo> _ytdlpAnalyze(String url, bool playlist) async {
    final proxy = await _ytdlpProxy();
    var res = await _ytdlp(url: url, args: infoArgs(proxy: proxy, cookieFile: _cookies, playlist: playlist));
    if (!res.ok && _mayRetryDirect(proxy, res.err)) {
      res = await _ytdlp(url: url, args: infoArgs(cookieFile: _cookies, playlist: playlist));
    }
    if (!res.ok) {
      // X hides some videos from logged-out users -> ask FxTwitter for the direct file
      final x = await _xFallback(url);
      if (x != null) return x;
      throw UserFacingException(ytdlpError(res.err));
    }
    return infoFromJson(url, res.out);
  }

  /// Tests can replace the FxTwitter request.
  Future<String?> Function(String url)? xFetchOverride;

  Future<String?> _getText(String url) async {
    final c = route.client();
    try {
      final req = await c.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 20));
      req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (Linux; Android 14) NexGrab/3.2');
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      return await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 20));
    } finally {
      c.close(force: true);
    }
  }

  /// FxTwitter lookup for X / Twitter links (same network route as everything else).
  Future<MediaInfo?> _xFallback(String url) async {
    final id = xStatusId(url);
    if (id == null) return null;
    try {
      final get = xFetchOverride ?? _getText;
      final fx = await get(fxApiUrl(id)).catchError((_) => null);
      final fromFx = fx == null ? null : infoFromFx(url, fx);
      if (fromFx != null) return fromFx;
      final vx = await get(vxApiUrl(id)).catchError((_) => null);
      return vx == null ? null : infoFromVx(url, vx);
    } catch (_) {
      return null;
    }
  }

  /// Analyze a link. yt-dlp (1000+ sites) first; the built-in engine is the backup
  /// for YouTube, direct files and simple pages.
  Future<MediaInfo> analyze(String input, {bool playlist = false}) async {
    await refreshTor();
    final url = extractUrl(input);
    if (url == null) throw UserFacingException('Sahi link paste karein (https:// se shuru hone wala).');
    if (await _ytdlpAvailable()) {
      try {
        return await _ytdlpAnalyze(url, playlist);
      } catch (e) {
        if (playlist) rethrow;
        try {
          return await _builtinAnalyze(input);
        } catch (_) {
          throw e; // the yt-dlp message is the useful one
        }
      }
    }
    return _builtinAnalyze(input);
  }

  Future<MediaInfo> _builtinAnalyze(String input) async {
    try {
      return await _resolver().resolve(input);
    } catch (e) {
      if (settings.smartFallback && route.mode != RouteMode.direct && settings.route != RouteMode.tor && isNetworkError(e)) {
        return _resolver(NetRoute(RouteMode.direct)).resolve(input);
      }
      rethrow;
    }
  }

  /// Picks the option matching the "Default quality" setting.
  MediaOption pickDefault(MediaInfo info) {
    final opts = info.options;
    final q = settings.defaultQuality;
    if (q.startsWith('Best') && opts.first.isYtdlp) return opts.first;
    if (q.startsWith('Audio')) {
      return opts.firstWhere((o) => o.isAudio, orElse: () => opts.first);
    }
    final videos = opts.where((o) => o.height != null && !o.isAudio).toList()
      ..sort((a, b) {
        final h = b.height!.compareTo(a.height!);
        if (h != 0) return h;
        return (a.kind == OptionKind.merge ? 0 : 1).compareTo(b.kind == OptionKind.merge ? 0 : 1);
      });
    if (videos.isEmpty) return opts.first;
    if (q.startsWith('Best')) return videos.first;
    final want = int.tryParse(RegExp(r'\d+').firstMatch(q)?.group(0) ?? '') ?? 1080;
    return videos.firstWhere((o) => o.height! <= want, orElse: () => videos.last);
  }

  // ------------------------------------------------------------------ queue operations

  DownloadTask enqueue(MediaInfo info, MediaOption option) {
    final base = sanitizeFileName(info.title);
    final String name;
    if (option.kind == OptionKind.file) {
      name = extensionOf(base).isEmpty && option.ext.isNotEmpty ? '$base.${option.ext}' : base;
    } else {
      final tag = option.isAudio ? 'Audio' : option.label.replaceAll(' fast', '');
      name = '$base ($tag).${option.ext}';
    }
    final task = DownloadTask(
      id: '${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(9999)}',
      sourceUrl: info.sourceUrl,
      title: info.title,
      site: info.site,
      thumbnail: info.thumbnail,
      videoId: info.videoId,
      option: option,
      fileName: name,
    );
    task.total = option.sizeBytes;
    tasks.insert(0, task);
    _saveQueue();
    _notify();
    _pump();
    return task;
  }

  void pause(String id) {
    final t = _find(id);
    if (t == null) return;
    final token = _tokens[id];
    if (token != null) {
      token.pause();
      if (t.option.isYtdlp) unawaited(native.ytdlpCancel(id).catchError((_) {}));
    } else if (t.status == TaskStatus.queued) {
      t.status = TaskStatus.paused;
      _saveQueue();
      _notify();
    }
  }

  void resume(String id) {
    final t = _find(id);
    if (t == null || _tokens.containsKey(id)) return;
    if (t.status == TaskStatus.paused || t.status == TaskStatus.failed || t.status == TaskStatus.canceled) {
      t.status = TaskStatus.queued;
      t.error = null;
      _saveQueue();
      _notify();
      _pump();
    }
  }

  void cancel(String id) {
    final t = _find(id);
    if (t == null) return;
    final token = _tokens[id];
    if (token != null) {
      token.cancel();
      if (t.option.isYtdlp) unawaited(native.ytdlpCancel(id).catchError((_) {}));
    } else if (!t.status.isFinished) {
      t.status = TaskStatus.canceled;
      t.received = 0;
      _deleteWork(t.id);
      _saveQueue();
      _notify();
    }
  }

  void remove(String id) {
    final t = _find(id);
    if (t == null || _tokens.containsKey(id)) return;
    tasks.remove(t);
    if (t.status != TaskStatus.done) _deleteWork(t.id);
    _saveQueue();
    _notify();
  }

  void clearFinished() {
    tasks.removeWhere((t) => t.status == TaskStatus.done || t.status == TaskStatus.canceled);
    _saveQueue();
    _notify();
  }

  void removeHistory(String id) {
    history.removeWhere((h) => h.id == id);
    _saveHistory();
    _notify();
  }

  void clearHistory() {
    history.clear();
    _saveHistory();
    _notify();
  }

  Future<void> saveSettings() async {
    await refreshTor();
    await _writeJson('settings.json', settings.toJson());
    _notify();
    _pump();
  }

  DownloadTask? _find(String id) {
    for (final t in tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  // ------------------------------------------------------------------ worker

  void _pump() {
    if (!_ready) return;
    var running = _tokens.length;
    for (final t in tasks.reversed.toList()) {
      if (running >= settings.maxParallel) break;
      if (t.status == TaskStatus.queued && !_tokens.containsKey(t.id)) {
        running++;
        unawaited(_run(t));
      }
    }
    _updateAwake();
  }

  void _updateAwake() {
    final want = _tokens.isNotEmpty;
    if (want != _awake) {
      _awake = want;
      native.keepAwake(want).catchError((_) {});
    }
  }

  Future<void> _run(DownloadTask task) async {
    final token = CancelToken();
    _tokens[task.id] = token;
    task.status = TaskStatus.downloading;
    task.error = null;
    task.speed = 0;
    _notify();

    final dir = Directory('${_work.path}/${task.id}');
    try {
      await refreshTor();
      await dir.create(recursive: true);
      if (task.option.isYtdlp) {
        await _runYtdlp(task, token, dir);
        return;
      }
      final parts = task.option.parts;
      final files = [for (var i = 0; i < parts.length; i++) File('${dir.path}/part$i')];

      var have = 0;
      for (final f in files) {
        if (await f.exists()) have += await f.length();
      }
      task.received = have;
      _lastBytes[task.id] = have;
      void updateTotal() {
        task.total = parts.every((p) => p.size > 0) ? parts.fold(0, (a, p) => a + p.size) : 0;
      }

      updateTotal();
      _saveQueue();

      for (var i = 0; i < parts.length; i++) {
        final part = parts[i];
        final vid = task.videoId;
        await fetchPart(
          part: part,
          out: files[i],
          route: _routeFor,
          token: token,
          onBytes: (d) {
            task.received += d;
            _dirty = true;
          },
          onTotal: (_) => updateTotal(),
          refresh: vid == null ? null : () => _resolver().refreshYouTubePart(vid, part),
        );
      }
      token.check();

      var finalPath = files.first.path;
      if (task.option.needsMerge) {
        task.status = TaskStatus.merging;
        task.speed = 0;
        _notify();
        final out = '${dir.path}/merged.${task.option.ext}';
        await native.mux(files[0].path, files[1].path, out, webm: task.option.ext == 'webm');
        finalPath = out;
      }
      token.check();

      task.status = TaskStatus.saving;
      _notify();
      if (!await native.ensureStoragePermission()) {
        throw UserFacingException('Storage permission nahi mili. Settings se allow karke Retry dabayein.');
      }
      final size = await File(finalPath).length();
      final saved = await native.saveToDownloads(finalPath, task.fileName, task.option.mime, settings.folder);
      task.savedUri = saved.uri;
      task.savedPath = saved.path;
      task.fileName = saved.name;
      task.received = size;
      task.total = size;
      task.status = TaskStatus.done;
      task.finished = DateTime.now();
      history.insert(
        0,
        HistoryEntry(
          id: task.id,
          title: task.title,
          site: task.site,
          sourceUrl: task.sourceUrl,
          fileName: saved.name,
          uri: saved.uri,
          path: saved.path,
          mime: task.option.mime,
          size: size,
          quality: task.option.label,
          finished: task.finished!,
          thumbnail: task.thumbnail,
        ),
      );
      if (history.length > 500) history.removeRange(500, history.length);
      _saveHistory();
      await _deleteWork(task.id);
    } on PausedException {
      task.status = TaskStatus.paused;
    } on CanceledException {
      task.status = TaskStatus.canceled;
      task.received = 0;
      await _deleteWork(task.id);
    } catch (e) {
      if (token.isCanceled) {
        task.status = TaskStatus.canceled;
        task.received = 0;
        await _deleteWork(task.id);
      } else if (token.isPaused) {
        task.status = TaskStatus.paused;
      } else {
        task.status = TaskStatus.failed;
        task.error = friendlyError(e);
      }
    } finally {
      _tokens.remove(task.id);
      _lastBytes.remove(task.id);
      task.speed = 0;
      _saveQueue();
      _notify();
      _pump();
    }
  }

  /// Half-downloaded pieces from a refused attempt must not be "continued" by the next one.
  void _dropPartials(Directory dir) {
    try {
      for (final f in dir.listSync().whereType<File>()) {
        if (f.path.endsWith('.part') || f.path.endsWith('.ytdl') || RegExp(r'\.part-Frag\d+').hasMatch(f.path)) {
          f.deleteSync();
        }
      }
    } catch (_) {}
  }

  Future<void> _runYtdlp(DownloadTask task, CancelToken token, Directory dir) async {
    if (!await _ytdlpAvailable()) {
      throw UserFacingException('Download engine shuru nahi ho saka. $ytdlpInitError');
    }
    task.total = task.option.estSize;
    final streamedFiles = <String>{};
    final sub = native.ytdlpLines.where((l) => l.id == task.id).listen((l) {
      // File paths also arrive live (stdout can be lost when yt-dlp exits with an error)
      streamedFiles.addAll(parseFiles(l.line));
      final p = parseProgress(l.line);
      if (p != null) {
        task.status = TaskStatus.downloading;
        task.stage = '';
        task.received = p.downloaded;
        if (p.total > 0) task.total = p.total;
        task.speed = p.speed;
        if (p.index != null && p.count != null) task.item = '${p.index}/${p.count}';
        _dirty = true;
        return;
      }
      final st = parseStage(l.line);
      if (st != null) {
        task.status = TaskStatus.merging;
        task.stage = st;
        task.speed = 0;
        _notify();
      }
    });
    try {
      var proxy = await _ytdlpProxy();
      List<String> args(String px, [List<String> extra = const []]) =>
          downloadArgs(option: task.option, dir: dir.path, proxy: px, cookieFile: _cookies, extra: extra,
              fixedName: task.sourceUrl.contains('video.twimg.com') ? task.title : null);
      var res = await _ytdlp(id: task.id, url: task.sourceUrl, args: args(proxy), stream: true);
      token.check();
      if (!res.ok && !res.canceled && _mayRetryDirect(proxy, res.err)) {
        proxy = '';
        res = await _ytdlp(id: task.id, url: task.sourceUrl, args: args(''), stream: true);
        token.check();
      }
      // YouTube 403 on the media files: try other YouTube player clients, then a fresh yt-dlp.
      if (!res.ok && !res.canceled && isYoutubeUrl(task.sourceUrl) && isForbiddenError(res.err)) {
        _dropPartials(dir);
        task.stage = 'YouTube ne roka - doosre tareeqe se try...';
        _notify();
        res = await _ytdlp(id: task.id, url: task.sourceUrl, args: args(proxy, youtubeRetryArgs), stream: true);
        token.check();
        final age = DateTime.now().millisecondsSinceEpoch - settings.lastYtdlpUpdate;
        if (!res.ok && !res.canceled && isForbiddenError(res.err) && age > const Duration(hours: 6).inMilliseconds) {
          task.stage = 'Engine update ho raha hai...';
          _notify();
          try {
            await updateYtdlp();
          } catch (_) {}
          _dropPartials(dir);
          res = await _ytdlp(id: task.id, url: task.sourceUrl, args: args(proxy), stream: true);
          token.check();
        }
        task.stage = '';
      }
      if (res.canceled) throw CanceledException();
      final files = {...streamedFiles, ...parseFiles(res.out)}.where((f) => File(f).existsSync()).toList();
      if (files.isEmpty) {
        throw UserFacingException(res.ok ? 'Download hua lekin file nahi mili.' : ytdlpError(res.err));
      }

      task.status = TaskStatus.saving;
      task.stage = '';
      task.speed = 0;
      _notify();
      if (!await native.ensureStoragePermission()) {
        throw UserFacingException('Storage permission nahi mili. Settings se allow karke Retry dabayein.');
      }
      SavedFile? first;
      var size = 0;
      for (final f in files) {
        token.check();
        final name = f.split('/').last;
        final saved = await native.saveToDownloads(f, name, mimeForExt(extensionOf(name)), settings.folder);
        first ??= saved;
        size += await File(f).length();
      }
      task.savedUri = first!.uri;
      task.savedPath = files.length > 1 ? 'Download/${settings.folder}  (${files.length} files)' : first.path;
      task.fileName = files.length > 1 ? '${task.title} (${files.length} files)' : first.name;
      task.received = size;
      task.total = size;
      task.status = TaskStatus.done;
      task.finished = DateTime.now();
      history.insert(
        0,
        HistoryEntry(
          id: task.id,
          title: task.title,
          site: task.site,
          sourceUrl: task.sourceUrl,
          fileName: task.fileName,
          uri: first.uri,
          path: task.savedPath!,
          mime: mimeForExt(extensionOf(first.name)),
          size: size,
          quality: task.option.label,
          finished: task.finished!,
          thumbnail: task.thumbnail,
        ),
      );
      if (history.length > 500) history.removeRange(500, history.length);
      _saveHistory();
      await _deleteWork(task.id);
    } finally {
      await sub.cancel();
    }
  }

  void _tick() {
    // Re-check Tor every ~3 s so turning Orbot on/off is picked up automatically.
    if (++_tickCount % 6 == 0) unawaited(refreshTor());
    var any = false;
    for (final t in tasks) {
      if (t.status != TaskStatus.downloading) continue;
      any = true;
      if (t.option.isYtdlp) continue; // speed comes from yt-dlp itself
      final last = _lastBytes[t.id] ?? t.received;
      final perSec = max(0, t.received - last) * 2.0;
      t.speed = t.speed == 0 ? perSec : t.speed * 0.7 + perSec * 0.3;
      _lastBytes[t.id] = t.received;
    }
    if (any || _dirty) {
      _dirty = false;
      _notify();
    }
  }

  // ------------------------------------------------------------------ persistence

  Future<void> _deleteWork(String id) async {
    try {
      final d = Directory('${_work.path}/$id');
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }

  void _saveQueue() {
    final list = tasks.where((t) => t.status != TaskStatus.done).map((t) => t.toJson()).toList();
    unawaited(_writeJson('queue.json', list));
  }

  void _saveHistory() {
    unawaited(_writeJson('history.json', history.map((h) => h.toJson()).toList()));
  }

  Future<Object?> _readJson(String name) async {
    try {
      final f = File('${_data.path}/$name');
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeChain = Future<void>.value();

  Future<void> _writeJson(String name, Object data) {
    // Serialise writes so two saves never interleave on the same file.
    _writeChain = _writeChain.then((_) async {
      try {
        final f = File('${_data.path}/$name.tmp');
        await f.writeAsString(jsonEncode(data), flush: true);
        await f.rename('${_data.path}/$name');
      } catch (_) {}
    });
    return _writeChain;
  }
}
