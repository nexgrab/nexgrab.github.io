import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'models.dart';
import 'net.dart';

class PausedException implements Exception {
  @override
  String toString() => 'Paused';
}

/// Lets the UI pause / cancel a running transfer instantly (closes the socket).
class CancelToken {
  bool _canceled = false;
  bool _paused = false;
  HttpClient? _client;

  bool get stopped => _canceled || _paused;
  bool get isCanceled => _canceled;
  bool get isPaused => _paused;

  void cancel() {
    _canceled = true;
    _client?.close(force: true);
  }

  void pause() {
    _paused = true;
    _client?.close(force: true);
  }

  void check() {
    if (_canceled) throw CanceledException();
    if (_paused) throw PausedException();
  }

  Future<void> sleep(Duration d) async {
    final end = DateTime.now().add(d);
    while (DateTime.now().isBefore(end)) {
      check();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    check();
  }
}

/// Chooses the network route for a given attempt (lets "smart fallback" switch to Direct).
typedef RoutePicker = NetRoute Function(int failedAttempts);

/// Downloads [part] into [out], resuming from whatever is already on disk.
///
/// * Known size  -> fetched in ranged chunks (YouTube throttles big single requests).
/// * Unknown size -> single streaming request, resumed with an open Range if possible.
/// * Network errors are retried with backoff; progress already written is kept.
Future<void> fetchPart({
  required SourcePart part,
  required File out,
  required RoutePicker route,
  required CancelToken token,
  required void Function(int deltaBytes) onBytes,
  void Function(int totalBytes)? onTotal,
  Future<bool> Function()? refresh,
  int chunkSize = 10 * 1024 * 1024,
  int maxRetries = 6,
}) async {
  var have = await out.exists() ? await out.length() : 0;
  if (part.size > 0 && have > part.size) {
    await out.delete();
    have = 0;
  }
  var errors = 0;
  var refreshes = 0;

  while (true) {
    token.check();
    if (part.size > 0 && have >= part.size) return;

    final client = route(errors).client();
    token._client = client;
    try {
      final from = have;
      final int? to = part.size > 0 ? min(from + chunkSize, part.size) - 1 : null;

      var uri = part.url;
      final headers = <String, String>{
        'user-agent': browserUserAgent,
        'accept': '*/*',
        ...part.headers,
        'accept-encoding': 'identity',
      };
      var rangeSent = false;
      if (part.rangeByQuery) {
        if (to != null) {
          uri = uri.replace(queryParameters: {...uri.queryParameters, 'range': '$from-$to'});
          rangeSent = true;
        }
      } else if (from > 0 || to != null) {
        headers['range'] = 'bytes=$from-${to ?? ''}';
        rangeSent = true;
      }

      final req = await client.getUrl(uri).timeout(const Duration(seconds: 25));
      req.followRedirects = true;
      req.maxRedirects = 10;
      headers.forEach(req.headers.set);
      final res = await req.close().timeout(const Duration(seconds: 30));
      final code = res.statusCode;

      if (code == 416 && part.size == 0 && have > 0) {
        // We already have the whole file.
        await res.drain<void>().catchError((_) {});
        part.size = have;
        onTotal?.call(have);
        return;
      }
      if ((code == 403 || code == 410) && refresh != null && refreshes < 2) {
        await res.drain<void>().catchError((_) {});
        refreshes++;
        if (await refresh()) continue;
        throw HttpStatusException(code, uri);
      }
      if (code >= 400) {
        await res.drain<void>().catchError((_) {});
        throw HttpStatusException(code, uri);
      }

      var append = true;
      if (code == 206 || (part.rangeByQuery && rangeSent)) {
        if (part.size == 0) {
          final cr = res.headers.value(HttpHeaders.contentRangeHeader);
          final total = int.tryParse(cr?.split('/').last.trim() ?? '');
          if (total != null && total > 0) {
            part.size = total;
            onTotal?.call(total);
          }
        }
      } else {
        // 200 with full body: server ignored our Range -> start over.
        if (from > 0) {
          onBytes(-have);
          have = 0;
        }
        append = false;
        if (part.size == 0 && res.contentLength > 0) {
          part.size = res.contentLength;
          onTotal?.call(part.size);
        }
      }

      final expected = res.contentLength;
      final sink = out.openWrite(mode: append ? FileMode.append : FileMode.write);
      var got = 0;
      try {
        await for (final data in res.timeout(const Duration(seconds: 30))) {
          if (token.stopped) break;
          sink.add(data);
          got += data.length;
          have += data.length;
          onBytes(data.length);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      token.check();
      if (got > 0) errors = 0;

      if (part.size > 0) {
        if (have >= part.size) return;
        if (got == 0) throw const HttpException('Server ne khali response bheja');
        continue; // next chunk
      }
      if (expected >= 0 && got < expected) {
        throw const HttpException('Connection beech mein toot gaya');
      }
      part.size = have;
      onTotal?.call(have);
      return;
    } on CanceledException {
      rethrow;
    } on PausedException {
      rethrow;
    } catch (e) {
      if (token.stopped) token.check();
      final retryable = e is! HttpStatusException || e.code == 429 || e.code >= 500;
      errors++;
      if (!retryable || errors > maxRetries) rethrow;
      await token.sleep(Duration(seconds: min(1 << errors, 20)));
    } finally {
      token._client = null;
      client.close(force: true);
    }
  }
}
