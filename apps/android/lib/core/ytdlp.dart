// yt-dlp engine helpers (pure Dart, no Flutter): builds command lines, parses the
// JSON info into quality choices, parses progress lines and turns errors into
// short messages. The process itself runs in Kotlin (youtubedl-android library).

import 'dart:convert';

import 'models.dart';

class YtdlpResult {
  YtdlpResult(this.code, this.out, this.err);
  final int code; // 0 ok, 1 error, -2 canceled
  final String out;
  final String err;
  bool get ok => code == 0;
  bool get canceled => code == -2;
}

const _progressTemplate = 'download:RSKP %(progress.downloaded_bytes)s|%(progress.total_bytes)s|'
    '%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s|'
    '%(info.playlist_index)s|%(info.n_entries)s';
const _ppTemplate = 'postprocess:RSKPP %(progress.postprocessor)s';

List<String> commonArgs({String proxy = '', String? cookieFile}) => [
      '--no-warnings',
      '--socket-timeout', '30',
      '--retries', '10',
      '--extractor-retries', '3',
      if (proxy.isNotEmpty) ...['--proxy', proxy],
      if (cookieFile != null && cookieFile.isNotEmpty) ...['--cookies', cookieFile],
    ];

List<String> infoArgs({String proxy = '', String? cookieFile, bool playlist = false}) => [
      '-J',
      playlist ? '--flat-playlist' : '--no-playlist',
      ...commonArgs(proxy: proxy, cookieFile: cookieFile),
    ];

List<String> downloadArgs({
  required MediaOption option,
  required String dir,
  String proxy = '',
  String? cookieFile,
  String? fixedName,
  List<String> extra = const [],
}) {
  final playlist = option.playlist;
  final safe = fixedName == null ? '' : safeFileName(fixedName);
  final tmpl = safe.isNotEmpty
      ? '$dir/$safe [X].%(ext)s'
      : playlist
          ? '$dir/%(playlist_index|0)03d - %(title).120B [%(id)s].%(ext)s'
          : '$dir/%(title).150B [%(id)s].%(ext)s';
  return [
    '-f', option.format ?? 'b/best',
    '-o', tmpl,
    playlist ? '--yes-playlist' : '--no-playlist',
    if (playlist) ...['--ignore-errors'],
    '-c',
    '--no-mtime',
    '--newline',
    '--progress',
    '--progress-template', _progressTemplate,
    '--progress-template', _ppTemplate,
    '--print', 'after_move:RSKFILE %(filepath)s',
    '--fragment-retries', '10',
    '--concurrent-fragments', '4',
    if (option.mode == 'mp3') ...['-x', '--audio-format', 'mp3', '--audio-quality', '192K'],
    if (option.mode == 'video') ...['--merge-output-format', 'mp4/mkv'],
    ...extra,
    ...commonArgs(proxy: proxy, cookieFile: cookieFile),
  ];
}

/// YouTube refuses some stream URLs (HTTP 403) unless a special token is sent. These player
/// clients usually work without one - used for an automatic second try.
const List<String> youtubeRetryArgs = ['--extractor-args', 'youtube:player_client=android_vr,tv,web_safari'];

bool isYoutubeUrl(String url) =>
    RegExp(r'https?://([\w-]+\.)?(youtube\.com|youtu\.be|youtube-nocookie\.com)/', caseSensitive: false).hasMatch(url);

bool isForbiddenError(String err) => err.toLowerCase().contains('http error 403');

/// One parsed "RSKP ..." progress line.
class YtProgress {
  YtProgress(this.downloaded, this.total, this.speed, this.eta, this.index, this.count);
  final int downloaded;
  final int total;
  final double speed;
  final int? eta;
  final int? index;
  final int? count;
}

num? _num(String s) {
  final t = s.trim();
  if (t.isEmpty || t == 'NA' || t == 'None') return null;
  return num.tryParse(t);
}

YtProgress? parseProgress(String line) {
  final i = line.indexOf('RSKP ');
  if (i < 0) return null;
  final f = line.substring(i + 5).split('|');
  if (f.length < 5) return null;
  final done = _num(f[0])?.toInt() ?? 0;
  final total = (_num(f[1]) ?? _num(f[2]))?.toInt() ?? 0;
  return YtProgress(
    done,
    total,
    _num(f[3])?.toDouble() ?? 0,
    _num(f[4])?.toInt(),
    f.length > 5 ? _num(f[5])?.toInt() : null,
    f.length > 6 ? _num(f[6])?.toInt() : null,
  );
}

/// "RSKPP Merger" -> human stage text, else null.
String? parseStage(String line) {
  final i = line.indexOf('RSKPP ');
  if (i < 0) return null;
  final pp = line.substring(i + 6).trim();
  if (pp.contains('Merger')) return 'Merging video + audio';
  if (pp.contains('ExtractAudio')) return 'Converting to MP3';
  if (pp.contains('MoveFiles')) return null;
  return pp.isEmpty ? null : 'Processing ($pp)';
}

List<String> parseFiles(String out) => const LineSplitter()
    .convert(out)
    .where((l) => l.startsWith('RSKFILE '))
    .map((l) => l.substring(8).trim())
    .where((l) => l.isNotEmpty)
    .toSet()
    .toList();

int _size(Map f) => ((f['filesize'] ?? f['filesize_approx'] ?? 0) as num).toInt();

String _mb(int b) => b <= 0 ? '' : ' · ${(b / 1048576).toStringAsFixed(1)} MB';

/// yt-dlp JSON (-J) -> MediaInfo with quality options (same logic as the PC app).
MediaInfo infoFromJson(String sourceUrl, String jsonText) {
  final start = jsonText.indexOf('{');
  if (start < 0) throw const FormatException('yt-dlp ne info nahi di');
  final info = jsonDecode(jsonText.substring(start)) as Map<String, dynamic>;
  final type = info['_type'] as String? ?? 'video';
  final isPlaylist = type == 'playlist' || type == 'multi_video';
  final title = (info['title'] as String?)?.trim();
  final site = (info['webpage_url_domain'] as String?) ??
      (info['extractor_key'] as String?) ??
      Uri.tryParse(sourceUrl)?.host ??
      '';
  String? thumb = info['thumbnail'] as String?;
  final thumbs = info['thumbnails'];
  if (thumb == null && thumbs is List && thumbs.isNotEmpty) {
    thumb = (thumbs.last as Map)['url'] as String?;
  }

  if (isPlaylist) {
    final entries = (info['entries'] as List?)?.whereType<Map>().toList() ?? const [];
    MediaOption pl(String id, String label, String detail, String fmt, String mode, {int? h}) => MediaOption(
          id: id,
          label: label,
          detail: detail,
          kind: OptionKind.ytdlp,
          ext: mode == 'mp3' ? 'mp3' : (mode == 'm4a' ? 'm4a' : 'mp4'),
          mime: mode == 'video' ? 'video/mp4' : 'audio/mp4',
          parts: const [],
          height: h,
          format: fmt,
          mode: mode,
          playlist: true,
        );
    return MediaInfo(
      sourceUrl: sourceUrl,
      title: title ?? 'Playlist',
      site: site,
      thumbnail: thumb,
      author: info['uploader'] as String? ?? info['channel'] as String?,
      isPlaylist: true,
      count: entries.length,
      viaYtdlp: true,
      options: [
        pl('pl-best', 'Best quality', 'Poori playlist · MP4', 'bv*+ba/b', 'video'),
        for (final h in const [1080, 720, 480, 360])
          pl('pl-$h', 'Up to ${h}p', 'Poori playlist', 'bv*[height<=$h]+ba/b[height<=$h]/b', 'video', h: h),
        pl('pl-mp3', 'Audio MP3', 'Poori playlist · 192 kbps', 'ba/b', 'mp3'),
        pl('pl-m4a', 'Audio M4A', 'Poori playlist · original', 'ba[ext=m4a]/ba/b', 'm4a'),
      ],
    );
  }

  final formats = (info['formats'] as List?)?.whereType<Map>().toList() ?? const [];
  // yt-dlp: "none" = stream absent, null = unknown (treat as present)
  final audio = formats.where((f) => f['vcodec'] == 'none' && f['acodec'] != null && f['acodec'] != 'none').toList()
    ..sort((a, b) => ((b['abr'] ?? b['tbr'] ?? 0) as num).compareTo((a['abr'] ?? a['tbr'] ?? 0) as num));
  final bestAudio = audio.isNotEmpty ? audio.first : null;
  final audioSize = bestAudio == null ? 0 : _size(bestAudio);

  final byHeight = <int, Map>{};
  final scoreOf = <int, List<num>>{};
  for (final f in formats) {
    if (f['vcodec'] == 'none' || f['height'] == null) continue;
    if ((f['protocol'] as String? ?? '').startsWith('mhtml')) continue;
    final h = (f['height'] as num).toInt();
    final hasAudio = f['acodec'] != 'none';
    final score = <num>[(f['fps'] ?? 0) as num, f['ext'] == 'mp4' ? 1 : 0, (f['tbr'] ?? 0) as num, hasAudio ? 1 : 0];
    final old = scoreOf[h];
    if (old == null || _cmp(score, old) > 0) {
      byHeight[h] = f;
      scoreOf[h] = score;
    }
  }

  MediaOption opt(String id, String label, String detail, String fmt, String mode, {int? h, int size = 0}) => MediaOption(
        id: id,
        label: label,
        detail: detail,
        kind: OptionKind.ytdlp,
        ext: mode == 'mp3' ? 'mp3' : (mode == 'm4a' ? 'm4a' : 'mp4'),
        mime: mode == 'video' ? 'video/mp4' : (mode == 'mp3' ? 'audio/mpeg' : 'audio/mp4'),
        parts: const [],
        height: h,
        format: fmt,
        mode: mode,
        estSize: size,
      );

  final options = <MediaOption>[];
  if (formats.isEmpty || (byHeight.isEmpty && audio.isEmpty)) {
    options.add(opt('yd-file', 'Original file', '${(info['ext'] ?? 'file').toString().toUpperCase()}${_mb(_size(info))}',
        'b/best', 'file', size: _size(info)));
  } else {
    options.add(opt('yd-best', 'Best quality', 'Auto · MP4', 'bv*+ba/b', 'video'));
    final heights = byHeight.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final h in heights) {
      final f = byHeight[h]!;
      final hasAudio = f['acodec'] != 'none';
      final fps = ((f['fps'] ?? 0) as num).toInt();
      final id = f['format_id'].toString();
      final size = hasAudio ? _size(f) : (_size(f) > 0 ? _size(f) + audioSize : 0);
      options.add(opt(
        'yd-$id',
        '${h}p${fps > 30 ? fps : ''}',
        'MP4${_mb(size)}',
        hasAudio ? '$id/b[height<=$h]/b' : '$id+ba/bv*[height<=$h]+ba/b[height<=$h]/b',
        'video',
        h: h,
        size: size,
      ));
    }
    if (bestAudio != null) {
      options.add(opt('yd-mp3', 'Audio MP3', '192 kbps${_mb(audioSize)}', 'ba/b', 'mp3', size: audioSize));
      options.add(opt('yd-m4a', 'Audio M4A', 'Original quality${_mb(audioSize)}', 'ba[ext=m4a]/ba/b', 'm4a', size: audioSize));
    }
  }

  final dur = info['duration'];
  return MediaInfo(
    sourceUrl: sourceUrl,
    title: title == null || title.isEmpty ? (info['id']?.toString() ?? 'Video') : title,
    site: site,
    author: info['uploader'] as String? ?? info['channel'] as String?,
    duration: dur is num ? Duration(seconds: dur.round()) : null,
    thumbnail: thumb,
    viaYtdlp: true,
    options: options,
  );
}

int _cmp(List<num> a, List<num> b) {
  for (var i = 0; i < a.length; i++) {
    final c = a[i].compareTo(b[i]);
    if (c != 0) return c;
  }
  return 0;
}

bool isBotCheck(String s) {
  final m = s.toLowerCase();
  return m.contains('sign in to confirm') || (m.contains('confirm you') && m.contains('bot'));
}

bool isYtdlpNetworkError(String s) {
  final m = s.toLowerCase();
  if (m.contains('http error')) return false;
  return const [
    'failed to resolve', 'temporary failure in name resolution', 'name or service not known',
    'connection refused', 'timed out', 'network is unreachable', 'unable to connect',
    'connection reset', 'socks', 'proxy', 'remote end closed',
  ].any(m.contains);
}

/// Short Roman-Urdu message for a yt-dlp failure.
/// Python itself crashed (e.g. yt-dlp file being replaced) - safe to retry once.
bool isEngineCrash(String err) => err.contains('Traceback (most recent call last)');

String ytdlpError(String err) {
  final raw = err.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '').trim();
  if (isEngineCrash(raw) && !raw.contains('ERROR:')) {
    final last = raw.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).last;
    return 'Engine error. App band karke dobara kholein, phir Settings → Engine → Update dabayein.\n\n$last';
  }
  final lines = raw.split('\n').where((l) => l.contains('ERROR')).toList();
  final main = (lines.isNotEmpty ? lines.last : raw).replaceAll('ERROR: ', '').trim();
  final m = main.toLowerCase();
  if (isBotCheck(m)) {
    return "YouTube ne 'not a bot' check maanga. TOR switch OFF karke dobara try karein. "
        'Phir bhi aaye to Settings → Cookies file (cookies.txt) set karein.';
  }
  if (m.contains('login required') || m.contains('rate-limit reached') || m.contains('requested content is not available') ||
      m.contains('use --cookies')) {
    return 'Is site ne login maanga. Settings → Cookies file (cookies.txt) set karke dobara try karein.\n\n$main';
  }
  if (m.contains('[twitter]') && (m.contains('no video') || m.contains('nsfw') || m.contains('sensitive'))) {
    return 'X ne is post ki video nahi di, aur FxTwitter / VxTwitter se bhi nahi mili. Ya to post mein sirf photo / '
        'text hai, ya X ne ise poori tarah band kar rakha hai. Settings → Cookies mein apni X ki cookies.txt daal kar try karein.';
  }
  if (m.contains('no video could be found') || m.contains('there is no video in this post') ||
      m.contains('no video formats found')) {
    return 'Is post mein video nahi mili (sirf photo / text ho sakti hai). Video wali post ka link dein.';
  }
  if (m.contains('unsupported url')) return 'Ye link supported nahi hai.\n\n$main';
  if (m.contains('private') || m.contains('video unavailable') || m.contains('has been removed')) {
    return 'Video private / delete / region-blocked hai.\n\n$main';
  }
  if (m.contains('http error 404')) return 'Link par file nahi mili (404).';
  if (m.contains('http error 403')) {
    return 'Server ne access deny kiya (403). App ne doosre tareeqon se bhi try kiya. Thori der baad Retry karein, '
        'ya TOR switch badal kar dekhein.\n\n${main.length > 160 ? main.substring(0, 160) : main}';
  }
  if (m.contains('http error 429')) return 'Bohat zyada requests (429). Thori der baad ya TOR switch ON karke try karein.';
  if (isYtdlpNetworkError(m)) return 'Network error: connection nahi bana. Internet / Orbot check karein.\n\n$main';
  if (main.isEmpty) return 'Download fail ho gaya.';
  return main.length > 400 ? '${main.substring(0, 400)}…' : main;
}


// ---------------------------------------------------------------------------- X / Twitter fallback
// X hides many videos (e.g. "sensitive" posts) from logged-out visitors, so yt-dlp finds nothing.
// FxTwitter's public API returns the direct video.twimg.com files for those posts.
final RegExp xStatusRe = RegExp(
    r'https?://(?:www\.|mobile\.)?(?:x|twitter|fxtwitter|vxtwitter|fixupx|fixvx)\.com/'
    r'(?:i/web/status/|i/status/|[^/?#]+/status(?:es)?/)(\d+)',
    caseSensitive: false);

String? xStatusId(String url) => xStatusRe.firstMatch(url)?.group(1);

String fxApiUrl(String id) => 'https://api.fxtwitter.com/status/$id';

/// Backup service when FxTwitter has nothing.
String vxApiUrl(String id) => 'https://api.vxtwitter.com/Twitter/status/$id';

/// Builds the media card from an api.vxtwitter.com answer, or null when it has no video.
MediaInfo? infoFromVx(String url, String body) {
  Map<String, dynamic> j;
  try {
    j = (jsonDecode(body) as Map).cast<String, dynamic>();
  } catch (_) {
    return null;
  }
  final media = ((j['media_extended'] as List?) ?? const []).whereType<Map>()
      .where((m) => (m['type'] == 'video' || m['type'] == 'gif') && m['url'] is String).toList();
  if (media.isEmpty) return null;
  final m = media.first;
  final size = (m['size'] as Map?) ?? const {};
  // re-use the FxTwitter builder with the same field names
  return infoFromFx(url, jsonEncode({
    'tweet': {
      'text': j['text'] ?? '',
      'author': {'screen_name': j['user_screen_name'] ?? ''},
      'media': {
        'videos': [
          {
            'url': m['url'],
            'thumbnail_url': m['thumbnail_url'],
            'width': size['width'] ?? 0,
            'height': size['height'] ?? 0,
            'duration': ((m['duration_millis'] ?? 0) as num) / 1000,
            'variants': [
              {'bitrate': 1, 'content_type': 'video/mp4', 'url': m['url']}
            ],
          }
        ]
      }
    }
  }));
}

/// File-name safe text (also safe inside a yt-dlp output template).
String safeFileName(String s) {
  final t = s.replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t%]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > 80 ? t.substring(0, 80).trim() : t;
}

/// Builds the media card from an api.fxtwitter.com answer, or null when it has no video.
MediaInfo? infoFromFx(String url, String body) {
  Map<String, dynamic> j;
  try {
    j = (jsonDecode(body) as Map).cast<String, dynamic>();
  } catch (_) {
    return null;
  }
  final tw = (j['tweet'] as Map?)?.cast<String, dynamic>();
  final videos = ((tw?['media'] as Map?)?['videos'] as List?)?.whereType<Map>().toList() ?? const [];
  for (final v in videos) {
    final mp4 = ((v['variants'] as List?) ?? const [])
        .whereType<Map>()
        .where((x) => x['content_type'] == 'video/mp4' && x['url'] is String)
        .toList()
      ..sort((a, b) => ((b['bitrate'] ?? 0) as num).compareTo((a['bitrate'] ?? 0) as num));
    final best = mp4.isNotEmpty ? mp4.first['url'] as String : v['url'] as String?;
    if (best == null || best.isEmpty) continue;
    final w = ((v['width'] ?? 0) as num).toInt();
    final h = ((v['height'] ?? 0) as num).toInt();
    final res = (w > 0 && h > 0) ? (w < h ? w : h) : 0;
    final text = ((tw?['text'] as String?) ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    final author = ((tw?['author'] as Map?)?['screen_name'] as String?) ?? '';
    final dur = ((v['duration'] ?? 0) as num).toDouble();
    MediaOption opt(String id, String label, String detail, String mode) => MediaOption(
          id: id, label: label, detail: detail, kind: OptionKind.ytdlp,
          ext: mode == 'mp3' ? 'mp3' : 'mp4', mime: mode == 'mp3' ? 'audio/mpeg' : 'video/mp4',
          parts: const [], height: mode == 'mp3' ? null : (res > 0 ? res : null), format: 'b/best', mode: mode);
    return MediaInfo(
      sourceUrl: best,
      title: text.isEmpty ? 'X video' : (text.length > 90 ? text.substring(0, 90) : text),
      site: 'X',
      author: author.isEmpty ? null : '@$author',
      thumbnail: (v['thumbnail_url'] as String?)?.startsWith('https://') == true ? v['thumbnail_url'] as String : null,
      duration: dur > 0 ? Duration(milliseconds: (dur * 1000).round()) : null,
      viaYtdlp: true,
      options: [
        opt('x-best', 'Best quality', res > 0 ? '${res}p · MP4' : 'MP4', 'file'),
        opt('x-mp3', 'Audio MP3', '192 kbps', 'mp3'),
      ],
    );
  }
  return null;
}
