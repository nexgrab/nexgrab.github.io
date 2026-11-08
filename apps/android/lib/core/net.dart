import 'dart:async';
import 'dart:io';

import 'models.dart';

const browserUserAgent =
    'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Mobile Safari/537.36';

/// Orbot (Tor for Android) always exposes an HTTP proxy here while it is running.
const torHttpPort = 8118;
const torHttpProxy = '127.0.0.1:$torHttpPort';

/// Orbot's SOCKS port (used by the yt-dlp engine; DNS also goes through Tor with socks5h).
const torSocksPort = 9050;

/// True only if a real SOCKS5 server answers on [port].
Future<bool> socks5Alive(int port, {Duration timeout = const Duration(milliseconds: 700)}) async {
  Socket? s;
  try {
    s = await Socket.connect('127.0.0.1', port, timeout: timeout);
    s.add(const [5, 1, 0]);
    final reply = await s.first.timeout(timeout);
    return reply.length >= 2 && reply[0] == 5 && reply[1] == 0;
  } catch (_) {
    return false;
  } finally {
    s?.destroy();
  }
}

Future<bool> _portOpen(int port, Duration timeout) async {
  try {
    final s = await Socket.connect('127.0.0.1', port, timeout: timeout);
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// True when Orbot / Tor is running on this phone (its SOCKS or HTTP proxy answers).
Future<bool> torRunning({Duration timeout = const Duration(milliseconds: 700)}) async {
  if (await socks5Alive(torSocksPort, timeout: timeout)) return true;
  return _portOpen(torHttpPort, timeout);
}

/// Builds HttpClients for the selected network route (Direct / Tor / Custom proxy).
class NetRoute {
  NetRoute(this.mode, [this.custom = '']);

  final RouteMode mode;
  final String custom;

  static NetRoute fromSettings(AppSettings s) => NetRoute(s.route, s.customProxy);

  /// host:port of the proxy, or null for direct.
  String? get proxy {
    switch (mode) {
      case RouteMode.auto:
      case RouteMode.direct:
        return null;
      case RouteMode.tor:
        return torHttpProxy;
      case RouteMode.custom:
        return normalizeProxy(custom);
    }
  }

  String get label => switch (mode) {
        RouteMode.auto => 'Auto',
        RouteMode.direct => 'Direct',
        RouteMode.tor => 'Tor / Orbot ($torHttpProxy)',
        RouteMode.custom => 'Custom proxy (${proxy ?? 'not set'})',
      };

  HttpClient client() {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..idleTimeout = const Duration(seconds: 15)
      ..userAgent = browserUserAgent
      ..autoUncompress = false;
    final p = proxy;
    c.findProxy = (_) => p == null ? 'DIRECT' : 'PROXY $p';
    return c;
  }

  /// Accepts "1.2.3.4:8080", "http://host:3128", "host" (defaults to 8080).
  static String? normalizeProxy(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    s = s.replaceFirst(RegExp(r'^[a-zA-Z]+://'), '');
    s = s.split('/').first;
    if (!s.contains(':')) s = '$s:8080';
    final port = int.tryParse(s.split(':').last);
    if (port == null || port <= 0 || port > 65535) return null;
    return s;
  }
}

bool isNetworkError(Object e) =>
    e is SocketException ||
    e is HttpException ||
    e is TimeoutException ||
    e is HandshakeException ||
    e is TlsException ||
    e is OSError;

/// Turns low-level exceptions into a short Roman-Urdu/English message for the UI.
String friendlyError(Object e) {
  if (e is UserFacingException) return e.message;
  if (e is CanceledException) return 'Canceled';
  if (e is HttpStatusException) {
    return switch (e.code) {
      403 => 'Server ne access deny kar diya (403). Link expire ho gaya ho sakta hai, dobara try karein.',
      404 => 'File server par nahi mili (404). Link check karein.',
      410 => 'Link expire ho gaya (410). Dobara analyze karein.',
      429 => 'Bohat zyada requests (429). Thori der baad try karein ya route badlein.',
      _ => 'Server error ${e.code}.',
    };
  }
  if (e is HandshakeException || e is TlsException) {
    return 'Secure connection fail ho gaya. Internet / proxy check karein.';
  }
  if (e is SocketException || e is OSError) {
    return 'Internet connection nahi mil raha. Network / proxy check karein.';
  }
  if (e is TimeoutException) return 'Connection time out ho gaya. Dobara try karein.';
  if (e is FileSystemException) return 'Storage error: ${e.message}';
  if (e is StateError) return e.message;
  final s = e.toString();
  return s.length > 220 ? '${s.substring(0, 220)}…' : s;
}

class HttpStatusException implements Exception {
  HttpStatusException(this.code, this.url);
  final int code;
  final Uri url;
  @override
  String toString() => 'HTTP $code for ${url.host}';
}

/// Quick reachability test through a route. Returns latency.
Future<Duration> testRoute(NetRoute route) async {
  final c = route.client();
  final sw = Stopwatch()..start();
  try {
    final req = await c
        .getUrl(Uri.parse('https://www.gstatic.com/generate_204'))
        .timeout(const Duration(seconds: 20));
    final res = await req.close().timeout(const Duration(seconds: 20));
    await res.drain<void>();
    if (res.statusCode >= 400) throw HttpStatusException(res.statusCode, req.uri);
    return sw.elapsed;
  } finally {
    c.close(force: true);
  }
}
