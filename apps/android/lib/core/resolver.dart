import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/io_client.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'models.dart';
import 'net.dart';

/// Pulls the first http(s) link out of whatever the user pasted / shared
/// ("Watch this! https://youtu.be/xyz?si=..." -> "https://youtu.be/xyz?si=...").
String? extractUrl(String input) {
  final m = RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false).firstMatch(input);
  if (m != null) return m.group(0)!.replaceAll(RegExp(r'[).,;!]+$'), '');
  final t = input.trim();
  if (RegExp(r'^[\w-]+(\.[\w-]+)+(/\S*)?$').hasMatch(t)) return 'https://$t';
  return null;
}

/// YouTube video id from watch / youtu.be / shorts / live / embed / music links.
String? youTubeId(String url) {
  final u = Uri.tryParse(url);
  if (u == null) return null;
  final host = u.host.toLowerCase().replaceFirst('www.', '').replaceFirst('m.', '');
  final idRe = RegExp(r'^[A-Za-z0-9_-]{11}$');
  String? id;
  if (host == 'youtu.be') {
    id = u.pathSegments.isNotEmpty ? u.pathSegments.first : null;
  } else if (host == 'youtube.com' ||
      host == 'music.youtube.com' ||
      host == 'youtube-nocookie.com' ||
      host.endsWith('.youtube.com')) {
    final seg = u.pathSegments;
    if (u.queryParameters['v'] != null) {
      id = u.queryParameters['v'];
    } else if (seg.length >= 2 && const ['shorts', 'live', 'embed', 'v', 'e'].contains(seg[0])) {
      id = seg[1];
    }
  }
  return (id != null && idRe.hasMatch(id)) ? id : null;
}

class Resolver {
  Resolver(this.route, {this.webmMerge = true});

  final NetRoute route;

  /// Android's MediaMuxer can write WebM (VP9 + Opus) reliably from Android 10 on.
  final bool webmMerge;

  Future<MediaInfo> resolve(String input) async {
    final url = extractUrl(input);
    if (url == null) {
      throw UserFacingException('Sahi link paste karein (https:// se shuru hone wala).');
    }
    final id = youTubeId(url);
    if (id != null) return _youtube(url, id);
    final u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) throw UserFacingException('Link samajh nahi aaya.');
    return _generic(u);
  }

  // ---------------------------------------------------------------- YouTube

  YoutubeExplode _yt() => YoutubeExplode(httpClient: YoutubeHttpClient(IOClient(route.client())));

  static Future<StreamManifest> _manifest(YoutubeExplode yt, String id) async {
    try {
      return await yt.videos.streams.getManifest(id);
    } catch (_) {
      // Different player clients get blocked at different times; try the others.
      return yt.videos.streams.getManifest(
        id,
        ytClients: [YoutubeApiClient.ios, YoutubeApiClient.androidVr, YoutubeApiClient.tv],
      );
    }
  }

  Future<MediaInfo> _youtube(String url, String id) async {
    final yt = _yt();
    try {
      Video? video;
      try {
        video = await yt.videos.get(id).timeout(const Duration(seconds: 30));
      } catch (_) {
        video = null; // metadata is optional, streams are what matter
      }
      final StreamManifest manifest;
      try {
        manifest = await _manifest(yt, id).timeout(const Duration(seconds: 45));
      } on VideoRequiresPurchaseException {
        throw UserFacingException('Ye paid video hai, download nahi ho sakti.');
      } on VideoUnavailableException {
        throw UserFacingException('Video available nahi (private, deleted ya region-blocked).');
      } on VideoUnplayableException catch (e) {
        throw UserFacingException('Ye video play/download nahi ho sakti: ${e.message}');
      }
      final options = buildYouTubeOptions(manifest, sdkSupportsWebm: webmMerge);
      if (options.isEmpty) {
        throw UserFacingException('Is video ke liye koi downloadable stream nahi mili.');
      }
      return MediaInfo(
        sourceUrl: url,
        title: video?.title ?? 'YouTube video $id',
        author: video?.author,
        duration: video?.duration,
        thumbnail: 'https://i.ytimg.com/vi/$id/hqdefault.jpg',
        site: 'YouTube',
        videoId: id,
        options: options,
      );
    } on UserFacingException {
      rethrow;
    } catch (e) {
      if (isNetworkError(e)) rethrow;
      throw UserFacingException('YouTube se video info nahi mili: ${friendlyError(e)}');
    } finally {
      yt.close();
    }
  }

  static bool _isDefaultTrack(AudioStreamInfo a) =>
      a.audioTrack == null || a.audioTrack!.audioIsDefault;

  static SourcePart _ytPart(StreamInfo s, String role) => SourcePart(
        url: s.url,
        size: s.size.totalBytes,
        role: role,
        headers: YoutubeHttpClient.defaultHeaders,
        rangeByQuery: s.url.queryParameters['c'] != 'ANDROID',
        ytTag: s.tag,
      );

  static String _mb(int b) => b <= 0 ? '' : ' · ${(b / 1048576).toStringAsFixed(1)} MB';

  /// Turns the stream manifest into user-facing choices:
  /// - up to 1080p: H.264 MP4 video + AAC audio, merged on the phone (plays everywhere)
  /// - above 1080p: VP9 WebM video + Opus audio, merged on the phone
  /// - 360p muxed stream (no merge needed)
  /// - audio only (M4A / AAC)
  static List<MediaOption> buildYouTubeOptions(StreamManifest m, {required bool sdkSupportsWebm}) {
    final options = <MediaOption>[];

    List<AudioOnlyStreamInfo> audios(String container) {
      final all = m.audioOnly.where((a) => a.container.name == container).toList()
        ..sort((a, b) => b.bitrate.compareTo(a.bitrate));
      final def = all.where(_isDefaultTrack).toList();
      return def.isNotEmpty ? def : all;
    }

    final m4a = audios('mp4');
    final webmAudio = audios('webm');
    final bestM4a = m4a.isNotEmpty ? m4a.first : null;
    final bestOpus = webmAudio.isNotEmpty ? webmAudio.first : null;

    // Group video-only streams by height, pick the best compatible stream per height.
    final byHeight = <int, List<VideoOnlyStreamInfo>>{};
    for (final v in m.videoOnly) {
      byHeight.putIfAbsent(v.videoResolution.height, () => []).add(v);
    }
    final heights = byHeight.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final h in heights) {
      if (h < 144) continue;
      final list = byHeight[h]!
        ..sort((a, b) {
          final f = b.framerate.framesPerSecond.compareTo(a.framerate.framesPerSecond);
          return f != 0 ? f : b.bitrate.compareTo(a.bitrate);
        });
      final avc = list.where((v) => v.container.name == 'mp4' && v.videoCodec.startsWith('avc1'));
      final vp9 = list.where((v) => v.container.name == 'webm' && v.videoCodec.startsWith('vp'));
      if (h <= 1080 && avc.isNotEmpty && bestM4a != null) {
        final v = avc.first;
        options.add(MediaOption(
          id: 'yt-v${v.tag}-a${bestM4a.tag}',
          label: v.qualityLabel,
          detail: 'MP4 · H.264${_mb(v.size.totalBytes + bestM4a.size.totalBytes)}',
          kind: OptionKind.merge,
          ext: 'mp4',
          mime: 'video/mp4',
          height: h,
          parts: [_ytPart(v, 'video'), _ytPart(bestM4a, 'audio')],
        ));
      } else if (sdkSupportsWebm && vp9.isNotEmpty && bestOpus != null) {
        final v = vp9.first;
        options.add(MediaOption(
          id: 'yt-v${v.tag}-a${bestOpus.tag}',
          label: v.qualityLabel,
          detail: 'WEBM · VP9${_mb(v.size.totalBytes + bestOpus.size.totalBytes)}',
          kind: OptionKind.merge,
          ext: 'webm',
          mime: 'video/webm',
          height: h,
          parts: [_ytPart(v, 'video'), _ytPart(bestOpus, 'audio')],
        ));
      }
    }

    // Muxed (video+audio already together) – fastest, usually 360p.
    final muxed = m.muxed.toList()
      ..sort((a, b) => b.videoResolution.height.compareTo(a.videoResolution.height));
    for (final s in muxed.where((s) => s.container.name == 'mp4').take(1)) {
      options.add(MediaOption(
        id: 'yt-m${s.tag}',
        label: '${s.qualityLabel} fast',
        detail: 'MP4 · no merge${_mb(s.size.totalBytes)}',
        kind: OptionKind.muxed,
        ext: 'mp4',
        mime: 'video/mp4',
        height: s.videoResolution.height,
        parts: [_ytPart(s, 'file')],
      ));
    }

    if (bestM4a != null) {
      options.add(MediaOption(
        id: 'yt-a${bestM4a.tag}',
        label: 'Audio',
        detail: 'M4A · ${bestM4a.bitrate.kiloBitsPerSecond.round()} kbps${_mb(bestM4a.size.totalBytes)}',
        kind: OptionKind.audio,
        ext: 'm4a',
        mime: 'audio/mp4',
        parts: [_ytPart(bestM4a, 'audio')],
      ));
    }
    return options;
  }

  /// Gets a fresh URL for an expired YouTube stream (same itag).
  Future<bool> refreshYouTubePart(String videoId, SourcePart part) async {
    if (part.ytTag == null) return false;
    final yt = _yt();
    try {
      final m = await _manifest(yt, videoId).timeout(const Duration(seconds: 45));
      for (final s in m.streams) {
        if (s.tag == part.ytTag) {
          part.url = s.url;
          part.rangeByQuery = s.url.queryParameters['c'] != 'ANDROID';
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    } finally {
      yt.close();
    }
  }

  // ---------------------------------------------------------------- Direct links / web pages

  Future<MediaInfo> _generic(Uri uri) async {
    final client = route.client();
    try {
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 25));
      req.headers.set('user-agent', browserUserAgent);
      req.headers.set('accept-encoding', 'identity');
      req.followRedirects = true;
      req.maxRedirects = 10;
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode >= 400) throw HttpStatusException(res.statusCode, uri);
      final finalUri = _finalUri(uri, res);
      final mime = res.headers.contentType?.mimeType.toLowerCase() ?? '';

      if (mime.contains('html')) {
        final html = await _readText(res, 3 * 1024 * 1024);
        return await _scanPage(finalUri, html);
      }
      // It is a file: we only needed the headers.
      final name = fileNameFrom(
        res.headers.value('content-disposition'),
        finalUri,
        mime,
      );
      final size = res.contentLength > 0 ? res.contentLength : 0;
      final ext = extensionOf(name);
      final m = mime.isEmpty || mime == 'application/octet-stream' ? mimeForExt(ext) : mime;
      return MediaInfo(
        sourceUrl: uri.toString(),
        title: name,
        site: finalUri.host,
        options: [
          MediaOption(
            id: 'file-0',
            label: 'Original file',
            detail: '${ext.isEmpty ? 'FILE' : ext.toUpperCase()}${_mb(size)}',
            kind: OptionKind.file,
            ext: ext,
            mime: m,
            parts: [SourcePart(url: finalUri, size: size, role: 'file')],
          ),
        ],
      );
    } finally {
      client.close(force: true);
    }
  }

  static Uri _finalUri(Uri start, HttpClientResponse res) {
    var u = start;
    for (final r in res.redirects) {
      u = u.resolveUri(r.location);
    }
    return u;
  }

  static Future<String> _readText(HttpClientResponse res, int limit) async {
    final bytes = <int>[];
    await for (final chunk in res.timeout(const Duration(seconds: 30))) {
      bytes.addAll(chunk);
      if (bytes.length > limit) break;
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static const _mediaExt = ['mp4', 'm4v', 'webm', 'mov', 'mkv', 'mp3', 'm4a', 'aac', 'ogg', 'wav', 'flac'];

  /// Finds embedded media on an ordinary web page (og:video, <video>, <source>, JSON contentUrl, raw .mp4 links).
  Future<MediaInfo> _scanPage(Uri page, String html) async {
    final found = findMediaLinks(page, html);
    if (found.isEmpty) {
      throw UserFacingException(
        'Is page par koi direct video/audio file nahi mili.\n'
        'Supported: YouTube links, direct file links (.mp4, .mp3, .zip, .apk ...) '
        'aur woh pages jin mein seedha MP4 embedded ho.',
      );
    }
    final title = pageTitle(html) ?? page.host;
    final options = <MediaOption>[];
    var i = 0;
    for (final link in found.take(8)) {
      final size = await _contentLength(link);
      final name = fileNameFrom(null, link, '');
      final ext = extensionOf(name);
      options.add(MediaOption(
        id: 'file-$i',
        label: found.length == 1 ? 'Video file' : 'Media ${i + 1}',
        detail: '${ext.toUpperCase()}${_mb(size)} · ${link.host}',
        kind: OptionKind.file,
        ext: ext,
        mime: mimeForExt(ext),
        parts: [SourcePart(url: link, size: size, role: 'file', headers: {'referer': page.toString()})],
      ));
      i++;
    }
    return MediaInfo(
      sourceUrl: page.toString(),
      title: title,
      site: page.host,
      options: options,
      thumbnail: metaContent(html, const ['og:image', 'twitter:image']),
    );
  }

  Future<int> _contentLength(Uri u) async {
    final c = route.client();
    try {
      final req = await c.headUrl(u).timeout(const Duration(seconds: 10));
      req.headers.set('user-agent', browserUserAgent);
      final res = await req.close().timeout(const Duration(seconds: 10));
      await res.drain<void>();
      return res.statusCode < 400 && res.contentLength > 0 ? res.contentLength : 0;
    } catch (_) {
      return 0;
    } finally {
      c.close(force: true);
    }
  }

  static String _unescape(String s) => s
      .replaceAll(r'\/', '/')
      .replaceAll(r'&', '&')
      .replaceAll(r'/', '/')
      .replaceAll('&amp;', '&');

  static String? metaContent(String html, List<String> keys) {
    for (final k in keys) {
      final a = RegExp(
        '<meta[^>]+(?:property|name)=["\']${RegExp.escape(k)}["\'][^>]*content=["\']([^"\']+)["\']',
        caseSensitive: false,
      ).firstMatch(html);
      if (a != null) return _unescape(a.group(1)!);
      final b = RegExp(
        '<meta[^>]+content=["\']([^"\']+)["\'][^>]*(?:property|name)=["\']${RegExp.escape(k)}["\']',
        caseSensitive: false,
      ).firstMatch(html);
      if (b != null) return _unescape(b.group(1)!);
    }
    return null;
  }

  static String? pageTitle(String html) {
    final og = metaContent(html, const ['og:title', 'twitter:title']);
    if (og != null && og.trim().isNotEmpty) return og.trim();
    final t = RegExp(r'<title[^>]*>([^<]{1,300})</title>', caseSensitive: false).firstMatch(html);
    final s = t?.group(1)?.trim();
    return (s == null || s.isEmpty) ? null : s;
  }

  static List<Uri> findMediaLinks(Uri page, String html) {
    final out = <String>{};
    void add(String? raw) {
      if (raw == null) return;
      final s = _unescape(raw.trim());
      if (s.isEmpty || s.startsWith('blob:') || s.startsWith('data:')) return;
      final u = Uri.tryParse(s);
      if (u == null) return;
      final abs = page.resolveUri(u);
      if (!abs.isScheme('http') && !abs.isScheme('https')) return;
      if (abs.path.toLowerCase().endsWith('.m3u8')) return; // HLS not supported
      out.add(abs.toString());
    }

    add(metaContent(html, const [
      'og:video:secure_url',
      'og:video:url',
      'og:video',
      'twitter:player:stream',
      'og:audio',
    ]));
    for (final m in RegExp(r'''<(?:video|source|audio)\b[^>]*?\bsrc=["']([^"']+)["']''', caseSensitive: false)
        .allMatches(html)) {
      add(m.group(1));
    }
    for (final m in RegExp(r'''"contentUrl"\s*:\s*"([^"]+)"''').allMatches(html)) {
      add(m.group(1));
    }
    final extAlt = _mediaExt.join('|');
    for (final m in RegExp(
      'https?:(?:\\\\?/){2}[^\\s"\'<>]+?\\.(?:$extAlt)(?:\\?[^\\s"\'<>]*)?(?=["\'<>\\s]|\$)',
      caseSensitive: false,
    ).allMatches(html)) {
      add(m.group(0));
    }
    return out.map(Uri.parse).toList();
  }
}

// ---------------------------------------------------------------- file name helpers

String sanitizeFileName(String s) {
  var r = s
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  r = r.replaceAll(RegExp(r'^\.+'), '');
  if (r.length > 120) r = r.substring(0, 120).trim();
  return r.isEmpty ? 'download' : r;
}

String extensionOf(String name) {
  final i = name.lastIndexOf('.');
  if (i <= 0 || i == name.length - 1) return '';
  final e = name.substring(i + 1).toLowerCase();
  return RegExp(r'^[a-z0-9]{1,5}$').hasMatch(e) ? e : '';
}

String fileNameFrom(String? disposition, Uri url, String mime) {
  String? name;
  if (disposition != null) {
    final star = RegExp(r"filename\*\s*=\s*(?:UTF-8|utf-8)?''([^;]+)", caseSensitive: false).firstMatch(disposition);
    if (star != null) {
      name = Uri.decodeComponent(star.group(1)!.trim().replaceAll('"', ''));
    } else {
      final plain = RegExp(r'''filename\s*=\s*"?([^";]+)"?''', caseSensitive: false).firstMatch(disposition);
      name = plain?.group(1)?.trim();
    }
  }
  if (name == null || name.isEmpty) {
    final segs = url.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs.isNotEmpty) {
      try {
        name = Uri.decodeComponent(segs.last);
      } catch (_) {
        name = segs.last;
      }
    }
  }
  name = sanitizeFileName(name ?? 'download');
  if (extensionOf(name).isEmpty) {
    final e = extForMime(mime);
    if (e.isNotEmpty) name = '$name.$e';
  }
  return name;
}

const _mimeByExt = {
  'mp4': 'video/mp4',
  'm4v': 'video/mp4',
  'webm': 'video/webm',
  'mkv': 'video/x-matroska',
  'mov': 'video/quicktime',
  '3gp': 'video/3gpp',
  'mp3': 'audio/mpeg',
  'm4a': 'audio/mp4',
  'aac': 'audio/aac',
  'ogg': 'audio/ogg',
  'opus': 'audio/ogg',
  'wav': 'audio/wav',
  'flac': 'audio/flac',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'pdf': 'application/pdf',
  'zip': 'application/zip',
  'rar': 'application/vnd.rar',
  '7z': 'application/x-7z-compressed',
  'apk': 'application/vnd.android.package-archive',
  'txt': 'text/plain',
  'doc': 'application/msword',
  'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
};

String mimeForExt(String ext) => _mimeByExt[ext.toLowerCase()] ?? 'application/octet-stream';

String extForMime(String mime) {
  for (final e in _mimeByExt.entries) {
    if (e.value == mime) return e.key;
  }
  return '';
}
