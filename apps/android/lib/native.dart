import 'dart:async';

import 'package:flutter/services.dart';

import 'core/manager.dart';
import 'core/ytdlp.dart';

/// Android side lives in android/app/src/main/kotlin/.../MainActivity.kt
class AndroidNative implements NativeBridge {
  static const _ch = MethodChannel('rsk/native');

  int _sdk = 0;
  String _work = '';
  String _data = '';
  final _shared = StreamController<String>.broadcast();
  final _lines = StreamController<YtdlpLine>.broadcast();

  /// Links shared into the app while it is already open.
  Stream<String> get sharedLinks => _shared.stream;

  Future<void> init() async {
    final info = await _ch.invokeMapMethod<String, dynamic>('info');
    _sdk = (info?['sdk'] as num?)?.toInt() ?? 0;
    _work = info?['work'] as String? ?? '';
    _data = info?['data'] as String? ?? '';
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'shared' && call.arguments is String) {
        _shared.add(call.arguments as String);
      } else if (call.method == 'ytdlpLine' && call.arguments is Map) {
        final m = (call.arguments as Map).cast<String, dynamic>();
        _lines.add(YtdlpLine(m['id'] as String? ?? '', m['line'] as String? ?? ''));
      }
      return null;
    });
  }

  /// Link the app was opened with via "Share".
  Future<String?> takeShared() => _ch.invokeMethod<String>('takeShared');

  @override
  int get sdkInt => _sdk;

  @override
  Future<String> workDir() async => _work;

  @override
  Future<String> dataDir() async => _data;

  @override
  Future<bool> ensureStoragePermission() async =>
      await _ch.invokeMethod<bool>('ensureStoragePermission') ?? false;

  @override
  Future<void> keepAwake(bool on) => _ch.invokeMethod<void>('keepAwake', {'on': on});

  @override
  Future<void> mux(String videoPath, String audioPath, String outPath, {required bool webm}) =>
      _call('mux', {'video': videoPath, 'audio': audioPath, 'out': outPath, 'webm': webm});

  @override
  Future<void> open(String uri, String mime) => _call('open', {'uri': uri, 'mime': mime});

  @override
  Future<SavedFile> saveToDownloads(String path, String name, String mime, String folder) async {
    final Map<String, dynamic>? r;
    try {
      r = await _ch.invokeMapMethod<String, dynamic>(
        'saveToDownloads',
        {'path': path, 'name': name, 'mime': mime, 'folder': folder},
      );
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    }
    if (r == null) throw StateError('Save failed');
    return SavedFile(uri: r['uri'] as String, path: r['path'] as String, name: r['name'] as String);
  }

  @override
  Stream<YtdlpLine> get ytdlpLines => _lines.stream;

  @override
  Future<String> ytdlpInit() async {
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('ytdlpInit');
      return r?['version'] as String? ?? '';
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    }
  }

  @override
  Future<YtdlpResult> ytdlpRun({String? id, required String url, required List<String> args, bool stream = false}) async {
    final r = await _ch.invokeMapMethod<String, dynamic>(
      'ytdlpRun',
      {'id': id, 'url': url, 'args': args, 'stream': stream},
    );
    return YtdlpResult(
      (r?['code'] as num?)?.toInt() ?? 1,
      r?['out'] as String? ?? '',
      r?['err'] as String? ?? 'no response',
    );
  }

  @override
  Future<void> ytdlpCancel(String id) => _ch.invokeMethod<bool>('ytdlpCancel', {'id': id});

  @override
  Future<String> ytdlpUpdate() async {
    try {
      final r = await _ch.invokeMapMethod<String, dynamic>('ytdlpUpdate');
      return r?['version'] as String? ?? '';
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    }
  }

  @override
  Future<String?> pickCookies() async {
    try {
      return await _ch.invokeMethod<String>('pickCookies');
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    }
  }

  Future<void> _call(String method, Map<String, Object?> args) async {
    try {
      await _ch.invokeMethod<void>(method, args);
    } on PlatformException catch (e) {
      throw StateError(e.message ?? e.code);
    }
  }
}
