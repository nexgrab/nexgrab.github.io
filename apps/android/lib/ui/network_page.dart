import 'package:flutter/material.dart';

import '../core/manager.dart';
import '../core/models.dart';
import '../core/net.dart';
import 'theme.dart';
import 'widgets.dart';

class NetworkPage extends StatefulWidget {
  const NetworkPage({super.key, required this.manager});
  final DownloadManager manager;

  @override
  State<NetworkPage> createState() => _NetworkPageState();
}

class _NetworkPageState extends State<NetworkPage> {
  late final TextEditingController _proxy;
  bool _testing = false;
  String? _result;
  bool _resultOk = false;

  AppSettings get s => widget.manager.settings;

  @override
  void initState() {
    super.initState();
    _proxy = TextEditingController(text: s.customProxy);
  }

  @override
  void dispose() {
    _proxy.dispose();
    super.dispose();
  }

  Future<void> _setRoute(RouteMode r) async {
    setState(() {
      s.route = r;
      _result = null;
    });
    await widget.manager.saveSettings();
  }

  Future<void> _saveProxy() async {
    final raw = _proxy.text.trim();
    if (raw.isNotEmpty && NetRoute.normalizeProxy(raw) == null) {
      toast(context, 'Proxy format: host:port (jaise 192.168.1.5:8080)', error: true);
      return;
    }
    s.customProxy = raw;
    await widget.manager.saveSettings();
    if (mounted) toast(context, 'Proxy save ho gaya');
  }

  Future<void> _test() async {
    if (s.route == RouteMode.custom) {
      s.customProxy = _proxy.text.trim();
      await widget.manager.saveSettings();
    }
    setState(() {
      _testing = true;
      _result = null;
    });
    await widget.manager.refreshTor();
    try {
      final d = await testRoute(widget.manager.route);
      _resultOk = true;
      _result = 'Connected · ${d.inMilliseconds} ms (${widget.manager.routeLabel})';
    } catch (e) {
      _resultOk = false;
      _result = friendlyError(e);
      if (widget.manager.route.mode == RouteMode.tor) {
        _result = '$_result\nOrbot chal raha hai? Orbot settings mein HTTP proxy port 8118 on hona chahiye.';
      }
    }
    if (mounted) setState(() => _testing = false);
  }

  Widget _torStatus() {
    final up = widget.manager.torUp == true;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
      child: Row(
        children: [
          Icon(up ? Icons.verified_user_rounded : Icons.shield_outlined, size: 18, color: up ? C.ok : C.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              up ? 'Tor connected · downloads Tor se jayenge' : 'Tor band hai · Orbot khol kar Start dabayein',
              style: TextStyle(color: up ? C.ok : C.muted, fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  Widget _routeTile(RouteMode mode, IconData icon, String title, String sub) {
    final sel = s.route == mode;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _setRoute(mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: sel ? C.cyan.withAlpha(26) : C.bg2,
            border: Border.all(color: sel ? C.cyan : C.border, width: sel ? 1.4 : 1),
          ),
          child: Row(
            children: [
              Icon(icon, color: sel ? C.cyan : C.muted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(color: C.text, fontWeight: FontWeight.w700)),
                    Text(sub, style: const TextStyle(color: C.muted, fontSize: 12.5)),
                  ],
                ),
              ),
              Icon(sel ? Icons.check_circle_rounded : Icons.circle_outlined, color: sel ? C.cyan : C.border),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        const SectionTitle('Smart Network Center'),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Route', style: TextStyle(color: C.muted, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              _routeTile(RouteMode.auto, Icons.auto_awesome_rounded, 'Auto (recommended)',
                  'Orbot chal raha ho to Tor, warna Direct. Kuch set nahi karna.'),
              if (s.route == RouteMode.auto) _torStatus(),
              _routeTile(RouteMode.direct, Icons.bolt_rounded, 'Direct', 'Seedha internet (sab se tez)'),
              _routeTile(RouteMode.tor, Icons.security_rounded, 'Tor / Orbot',
                  'Orbot ka HTTP proxy $torHttpProxy use karta hai'),
              _routeTile(RouteMode.custom, Icons.dns_rounded, 'Custom proxy', 'Apna HTTP proxy (host:port)'),
              if (s.route == RouteMode.custom) ...[
                const SizedBox(height: 4),
                TextField(
                  controller: _proxy,
                  style: const TextStyle(color: C.text),
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    hintText: '192.168.1.5:8080',
                    prefixIcon: const Icon(Icons.settings_ethernet_rounded, color: C.cyan),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.save_rounded, color: C.cyan),
                      onPressed: _saveProxy,
                    ),
                  ),
                  onSubmitted: (_) => _saveProxy(),
                ),
              ],
            ],
          ),
        ),
        GlassCard(
          child: Row(
            children: [
              const Icon(Icons.alt_route_rounded, color: C.violet),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Smart fallback', style: TextStyle(color: C.text, fontWeight: FontWeight.w700)),
                    Text('Auto/Custom proxy fail ho to Direct (Tor-only mode kabhi nahi)',
                        style: TextStyle(color: C.muted, fontSize: 12.5)),
                  ],
                ),
              ),
              Switch(
                value: s.smartFallback,
                onChanged: (v) async {
                  setState(() => s.smartFallback = v);
                  await widget.manager.saveSettings();
                },
              ),
            ],
          ),
        ),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              GradientButton(
                label: 'TEST CONNECTION',
                icon: Icons.network_check_rounded,
                busy: _testing,
                onPressed: _test,
              ),
              if (_result != null) ...[
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(_resultOk ? Icons.check_circle_rounded : Icons.error_rounded,
                        color: _resultOk ? C.ok : C.bad),
                    const SizedBox(width: 10),
                    Expanded(child: Text(_result!, style: const TextStyle(color: C.text, height: 1.4))),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
