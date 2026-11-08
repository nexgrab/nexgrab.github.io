// Core data models. No Flutter imports here so the engine can be tested on the Dart VM.

enum TaskStatus {
  queued,
  resolving,
  downloading,
  merging,
  saving,
  paused,
  done,
  failed,
  canceled,
}

extension TaskStatusX on TaskStatus {
  bool get isActive =>
      this == TaskStatus.resolving ||
      this == TaskStatus.downloading ||
      this == TaskStatus.merging ||
      this == TaskStatus.saving;

  bool get isFinished =>
      this == TaskStatus.done ||
      this == TaskStatus.failed ||
      this == TaskStatus.canceled;

  String get label => switch (this) {
        TaskStatus.queued => 'Queued',
        TaskStatus.resolving => 'Preparing',
        TaskStatus.downloading => 'Downloading',
        TaskStatus.merging => 'Merging video + audio',
        TaskStatus.saving => 'Saving to Downloads',
        TaskStatus.paused => 'Paused',
        TaskStatus.done => 'Completed',
        TaskStatus.failed => 'Failed',
        TaskStatus.canceled => 'Canceled',
      };
}

enum OptionKind { file, muxed, merge, audio, ytdlp }

/// One downloadable byte source (a file, or the video / audio half of a YouTube stream).
class SourcePart {
  SourcePart({
    required this.url,
    required this.size,
    required this.role,
    this.headers = const {},
    this.rangeByQuery = false,
    this.ytTag,
  });

  Uri url;
  int size; // 0 = unknown
  final String role; // file | video | audio
  final Map<String, String> headers;

  /// YouTube (non-ANDROID clients) wants `&range=a-b` instead of a Range header.
  bool rangeByQuery;
  final int? ytTag;

  Map<String, dynamic> toJson() => {
        'url': url.toString(),
        'size': size,
        'role': role,
        'headers': headers,
        'rangeByQuery': rangeByQuery,
        'ytTag': ytTag,
      };

  factory SourcePart.fromJson(Map<String, dynamic> j) => SourcePart(
        url: Uri.parse(j['url'] as String),
        size: (j['size'] as num?)?.toInt() ?? 0,
        role: j['role'] as String? ?? 'file',
        headers: (j['headers'] as Map?)?.cast<String, String>() ?? const {},
        rangeByQuery: j['rangeByQuery'] as bool? ?? false,
        ytTag: (j['ytTag'] as num?)?.toInt(),
      );
}

class MediaOption {
  MediaOption({
    required this.id,
    required this.label,
    required this.detail,
    required this.kind,
    required this.ext,
    required this.mime,
    required this.parts,
    this.height,
    this.format,
    this.mode = 'video',
    this.playlist = false,
    this.estSize = 0,
  });

  final String id;
  final String label; // "1080p60"
  final String detail; // "MP4 · H.264"
  final OptionKind kind;
  final String ext; // mp4 / webm / m4a / ...
  final String mime;
  final List<SourcePart> parts;
  final int? height;

  /// yt-dlp engine: format selector, mode (video / mp3 / m4a / file), whole playlist?
  final String? format;
  final String mode;
  final bool playlist;
  final int estSize;

  bool get isYtdlp => kind == OptionKind.ytdlp;
  int get sizeBytes => isYtdlp ? estSize : parts.fold(0, (a, p) => a + p.size);
  bool get isAudio => kind == OptionKind.audio || mode == 'mp3' || mode == 'm4a';
  bool get needsMerge => kind == OptionKind.merge;

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'detail': detail,
        'kind': kind.name,
        'ext': ext,
        'mime': mime,
        'height': height,
        'parts': parts.map((e) => e.toJson()).toList(),
        'format': format,
        'mode': mode,
        'playlist': playlist,
        'estSize': estSize,
      };

  factory MediaOption.fromJson(Map<String, dynamic> j) => MediaOption(
        id: j['id'] as String,
        label: j['label'] as String,
        detail: j['detail'] as String? ?? '',
        kind: OptionKind.values.byName(j['kind'] as String),
        ext: j['ext'] as String,
        mime: j['mime'] as String,
        height: (j['height'] as num?)?.toInt(),
        format: j['format'] as String?,
        mode: j['mode'] as String? ?? 'video',
        playlist: j['playlist'] as bool? ?? false,
        estSize: (j['estSize'] as num?)?.toInt() ?? 0,
        parts: (j['parts'] as List)
            .map((e) => SourcePart.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
      );
}

class MediaInfo {
  MediaInfo({
    required this.sourceUrl,
    required this.title,
    required this.site,
    required this.options,
    this.author,
    this.thumbnail,
    this.duration,
    this.videoId,
    this.isPlaylist = false,
    this.count = 1,
    this.viaYtdlp = false,
  });

  final bool isPlaylist;
  final int count;
  final bool viaYtdlp;
  final String sourceUrl;
  final String title;
  final String site;
  final String? author;
  final String? thumbnail;
  final Duration? duration;
  final String? videoId; // YouTube id, used to refresh expired links
  final List<MediaOption> options;
}

class DownloadTask {
  DownloadTask({
    required this.id,
    required this.sourceUrl,
    required this.title,
    required this.site,
    required this.option,
    required this.fileName,
    this.thumbnail,
    this.videoId,
    this.status = TaskStatus.queued,
    DateTime? created,
  }) : created = created ?? DateTime.now();

  final String id;
  final String sourceUrl;
  String title;
  final String site;
  final String? thumbnail;
  final String? videoId;
  MediaOption option;
  String fileName;
  TaskStatus status;
  final DateTime created;

  // live progress
  String stage = ''; // "Merging video + audio", "Converting to MP3"...
  String item = ''; // "3/20" for playlists
  int received = 0;
  int total = 0;
  double speed = 0; // bytes/sec
  String? error;
  String? savedUri;
  String? savedPath;
  DateTime? finished;

  double? get progress => total > 0 ? (received / total).clamp(0.0, 1.0) : null;

  Duration? get eta {
    if (speed < 1 || total <= 0 || received >= total) return null;
    return Duration(seconds: ((total - received) / speed).round());
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'sourceUrl': sourceUrl,
        'title': title,
        'site': site,
        'thumbnail': thumbnail,
        'videoId': videoId,
        'option': option.toJson(),
        'fileName': fileName,
        'status': status.name,
        'created': created.toIso8601String(),
        'received': received,
        'total': total,
        'error': error,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> j) {
    final t = DownloadTask(
      id: j['id'] as String,
      sourceUrl: j['sourceUrl'] as String,
      title: j['title'] as String,
      site: j['site'] as String? ?? '',
      thumbnail: j['thumbnail'] as String?,
      videoId: j['videoId'] as String?,
      option: MediaOption.fromJson((j['option'] as Map).cast<String, dynamic>()),
      fileName: j['fileName'] as String,
      status: TaskStatus.values.byName(j['status'] as String),
      created: DateTime.tryParse(j['created'] as String? ?? ''),
    );
    t.received = (j['received'] as num?)?.toInt() ?? 0;
    t.total = (j['total'] as num?)?.toInt() ?? 0;
    t.error = j['error'] as String?;
    return t;
  }
}

class HistoryEntry {
  HistoryEntry({
    required this.id,
    required this.title,
    required this.site,
    required this.sourceUrl,
    required this.fileName,
    required this.uri,
    required this.path,
    required this.mime,
    required this.size,
    required this.quality,
    required this.finished,
    this.thumbnail,
  });

  final String id;
  final String title;
  final String site;
  final String sourceUrl;
  final String fileName;
  final String uri;
  final String path;
  final String mime;
  final int size;
  final String quality;
  final DateTime finished;
  final String? thumbnail;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'site': site,
        'sourceUrl': sourceUrl,
        'fileName': fileName,
        'uri': uri,
        'path': path,
        'mime': mime,
        'size': size,
        'quality': quality,
        'finished': finished.toIso8601String(),
        'thumbnail': thumbnail,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> j) => HistoryEntry(
        id: j['id'] as String,
        title: j['title'] as String,
        site: j['site'] as String? ?? '',
        sourceUrl: j['sourceUrl'] as String? ?? '',
        fileName: j['fileName'] as String,
        uri: j['uri'] as String,
        path: j['path'] as String? ?? '',
        mime: j['mime'] as String? ?? 'application/octet-stream',
        size: (j['size'] as num?)?.toInt() ?? 0,
        quality: j['quality'] as String? ?? '',
        finished: DateTime.tryParse(j['finished'] as String? ?? '') ?? DateTime.now(),
        thumbnail: j['thumbnail'] as String?,
      );
}

enum RouteMode { auto, direct, tor, custom }

class AppSettings {
  RouteMode route = RouteMode.auto;
  String customProxy = '';
  bool smartFallback = true;
  String defaultQuality = 'Best available';
  bool askQuality = true;
  int maxParallel = 2;
  String folder = 'NexGrab';
  String cookieFile = '';
  int lastYtdlpUpdate = 0; // ms since epoch

  static const qualities = [
    'Best available',
    '2160p / 4K',
    '1440p / 2K',
    '1080p',
    '720p',
    '480p',
    '360p',
    'Audio only',
  ];

  Map<String, dynamic> toJson() => {
        'route': route.name,
        'customProxy': customProxy,
        'smartFallback': smartFallback,
        'defaultQuality': defaultQuality,
        'askQuality': askQuality,
        'maxParallel': maxParallel,
        'folder': folder,
        'cookieFile': cookieFile,
        'lastYtdlpUpdate': lastYtdlpUpdate,
      };

  void load(Map<String, dynamic> j) {
    route = RouteMode.values.asNameMap()[j['route']] ?? RouteMode.auto;
    customProxy = j['customProxy'] as String? ?? '';
    smartFallback = j['smartFallback'] as bool? ?? true;
    final q = j['defaultQuality'] as String?;
    defaultQuality = qualities.contains(q) ? q! : 'Best available';
    askQuality = j['askQuality'] as bool? ?? true;
    maxParallel = ((j['maxParallel'] as num?)?.toInt() ?? 2).clamp(1, 3);
    final f = (j['folder'] as String?)?.trim();
    folder = (f == null || f.isEmpty) ? 'NexGrab' : f;
    cookieFile = j['cookieFile'] as String? ?? '';
    lastYtdlpUpdate = (j['lastYtdlpUpdate'] as num?)?.toInt() ?? 0;
  }
}

class UserFacingException implements Exception {
  UserFacingException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CanceledException implements Exception {
  @override
  String toString() => 'Canceled';
}
