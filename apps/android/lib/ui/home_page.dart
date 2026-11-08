import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/manager.dart';
import '../core/models.dart';
import '../core/net.dart';
import 'theme.dart';
import 'widgets.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.manager, required this.onOpenDownloads});

  final DownloadManager manager;
  final VoidCallback onOpenDownloads;

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  final _url = TextEditingController();
  bool _busy = false;
  bool _playlist = false;
  String? _error;
  MediaInfo? _info;
  MediaOption? _selected;
  int _request = 0;

  DownloadManager get m => widget.manager;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  /// Called when a link is shared into the app.
  void analyzeShared(String text) {
    _url.text = text.trim();
    _analyze();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final t = data?.text?.trim() ?? '';
    if (t.isEmpty) {
      if (mounted) toast(context, 'Clipboard khali hai');
      return;
    }
    _url.text = t;
    _analyze();
  }

  Future<void> _analyze() async {
    final input = _url.text.trim();
    if (input.isEmpty) {
      setState(() => _error = 'Pehle link paste karein.');
      return;
    }
    FocusScope.of(context).unfocus();
    final req = ++_request;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
      _selected = null;
    });
    try {
      final info = await m.analyze(input, playlist: _playlist);
      if (!mounted || req != _request) return;
      final pick = m.pickDefault(info);
      if (!m.settings.askQuality) {
        _start(info, pick);
        setState(() => _busy = false);
        return;
      }
      setState(() {
        _info = info;
        _selected = pick;
        _busy = false;
      });
    } catch (e) {
      if (!mounted || req != _request) return;
      setState(() {
        _busy = false;
        _error = friendlyError(e);
      });
    }
  }

  void _start(MediaInfo info, MediaOption opt) {
    final t = m.enqueue(info, opt);
    toast(context, 'Download shuru: ${t.fileName}');
    setState(() {
      _info = null;
      _selected = null;
      _url.clear();
    });
    widget.onOpenDownloads();
  }

  @override
  Widget build(BuildContext context) {
    final active = m.tasks.where((t) => t.status.isActive || t.status == TaskStatus.queued).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _header(),
        const SizedBox(height: 18),
        GlassCard(
          glow: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Download media',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: C.text)),
              const SizedBox(height: 4),
              const Text('YouTube, Instagram, Facebook, TikTok, X + 1000 sites',
                  style: TextStyle(color: C.muted, fontSize: 13)),
              const SizedBox(height: 14),
              TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _analyze(),
                style: const TextStyle(color: C.text),
                decoration: InputDecoration(
                  hintText: 'https://…',
                  prefixIcon: const Icon(Icons.link_rounded, color: C.cyan),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_url.text.isNotEmpty)
                        IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.close_rounded, color: C.muted),
                          onPressed: () => setState(() {
                            _url.clear();
                            _info = null;
                            _error = null;
                          }),
                        ),
                      IconButton(
                        tooltip: 'Paste',
                        icon: const Icon(Icons.content_paste_rounded, color: C.cyan),
                        onPressed: _busy ? null : _paste,
                      ),
                    ],
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Checkbox(
                    value: _playlist,
                    onChanged: _busy ? null : (v) => setState(() => _playlist = v ?? false),
                  ),
                  const Expanded(
                    child: Text('Poori playlist / channel download karein',
                        style: TextStyle(color: C.muted, fontSize: 13)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              GradientButton(
                label: _busy ? 'ANALYZING' : 'ANALYZE LINK',
                icon: Icons.bolt_rounded,
                busy: _busy,
                onPressed: _analyze,
              ),
              const SizedBox(height: 10),
              _torSwitch(),
            ],
          ),
        ),
        if (_error != null) _errorCard(_error!),
        if (_info != null) _infoCard(_info!),
        if (active > 0)
          GlassCard(
            onTap: widget.onOpenDownloads,
            child: Row(
              children: [
                const Icon(Icons.downloading_rounded, color: C.cyan),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('$active download${active == 1 ? '' : 's'} chal rahe hain',
                      style: const TextStyle(color: C.text, fontWeight: FontWeight.w600)),
                ),
                const Icon(Icons.chevron_right_rounded, color: C.muted),
              ],
            ),
          ),
        if (_info == null && _error == null) _tips(),
      ],
    );
  }

  /// Big Tor ON/OFF switch. ON = Auto (Tor whenever Orbot runs), OFF = always Direct.
  Widget _torSwitch() {
    final on = m.settings.route == RouteMode.auto || m.settings.route == RouteMode.tor;
    final connected = m.route.mode == RouteMode.tor;
    final String hint;
    final Color color;
    if (!on) {
      hint = 'OFF: sab downloads Direct';
      color = C.muted;
    } else if (connected) {
      hint = 'ON: Orbot connected, downloads Tor se';
      color = C.ok;
    } else {
      hint = 'ON: Orbot kholein, khulte hi Tor use hoga';
      color = C.warn;
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: C.bg2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: connected ? C.ok.withAlpha(140) : C.border),
      ),
      child: Row(
        children: [
          Icon(connected ? Icons.security_rounded : Icons.shield_outlined, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('TOR', style: TextStyle(color: C.text, fontWeight: FontWeight.w800, letterSpacing: 1)),
                Text(hint, style: TextStyle(color: color, fontSize: 12)),
              ],
            ),
          ),
          Switch(
            value: on,
            onChanged: (v) async {
              m.settings.route = v ? RouteMode.auto : RouteMode.direct;
              await m.saveSettings();
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.asset('assets/nexgrab_logo.png', width: 48, height: 48),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ShaderMask(
                shaderCallback: (r) => C.accent.createShader(r),
                child: const Text('NexGrab',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Colors.white, letterSpacing: .3)),
              ),
              const Text('Futuristic Downloader · v3.2', style: TextStyle(color: C.muted, fontSize: 12.5)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _errorCard(String msg) {
    return GlassCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded, color: C.bad),
          const SizedBox(width: 12),
          Expanded(child: Text(msg, style: const TextStyle(color: C.text, height: 1.4))),
        ],
      ),
    );
  }

  Widget _infoCard(MediaInfo info) {
    final sel = _selected;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MediaThumb(
                url: info.thumbnail,
                width: 120,
                height: 68,
                icon: iconForMime(info.options.first.mime),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(info.title,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: C.text, fontWeight: FontWeight.w700, height: 1.3)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        Pill(info.site, icon: Icons.public_rounded),
                        if (info.duration != null) Pill(fmtDuration(info.duration), color: C.violet),
                      ],
                    ),
                    if (info.author != null) ...[
                      const SizedBox(height: 6),
                      Text(info.author!, style: const TextStyle(color: C.muted, fontSize: 12.5)),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text('Quality / format', style: TextStyle(color: C.muted, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          for (final o in info.options) _optionTile(o, o.id == sel?.id),
          const SizedBox(height: 10),
          GradientButton(
            label: sel == null ? 'DOWNLOAD' : 'DOWNLOAD ${sel.label.toUpperCase()}',
            icon: Icons.download_rounded,
            onPressed: sel == null ? null : () => _start(info, sel),
          ),
        ],
      ),
    );
  }

  Widget _optionTile(MediaOption o, bool selected) {
    final icon = o.isAudio
        ? Icons.music_note_rounded
        : (o.kind == OptionKind.file ? iconForMime(o.mime) : Icons.high_quality_rounded);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() => _selected = o),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: selected ? C.cyan.withAlpha(28) : C.bg2,
            border: Border.all(color: selected ? C.cyan : C.border, width: selected ? 1.4 : 1),
          ),
          child: Row(
            children: [
              Icon(icon, color: selected ? C.cyan : C.muted, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(o.label, style: const TextStyle(color: C.text, fontWeight: FontWeight.w700)),
                    if (o.detail.isNotEmpty)
                      Text(o.detail, style: const TextStyle(color: C.muted, fontSize: 12)),
                  ],
                ),
              ),
              Icon(
                selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                color: selected ? C.cyan : C.border,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tips() {
    Widget tip(IconData i, String t) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(i, size: 18, color: C.cyan),
              const SizedBox(width: 10),
              Expanded(child: Text(t, style: const TextStyle(color: C.muted, height: 1.35))),
            ],
          ),
        );
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Tips', style: TextStyle(color: C.text, fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 10),
          tip(Icons.share_rounded, 'YouTube app mein Share → "NexGrab" dabayein, link khud aa jayega.'),
          tip(Icons.public_rounded, 'YouTube, Instagram, Facebook, TikTok, X, Vimeo... jo bhi yt-dlp support kare (1000+ sites).'),
          tip(Icons.security_rounded, 'TOR: Orbot kholein, TOR switch ON rakhein. Har site Tor se jayegi.'),
          tip(Icons.cookie_outlined, 'Login wali / bot-check wali video: Settings → Cookies file (cookies.txt).'),
          tip(Icons.pause_circle_outline_rounded, 'Download pause/resume ho sakta hai. Net toot jaye to khud resume hota hai.'),
          tip(Icons.folder_open_rounded, 'Files: Download/${m.settings.folder}'),
        ],
      ),
    );
  }
}
