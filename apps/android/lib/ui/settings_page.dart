import 'package:flutter/material.dart';

import '../core/manager.dart';
import '../core/models.dart';
import 'theme.dart';
import 'widgets.dart';

const appVersion = '3.3.0';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.manager});
  final DownloadManager manager;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _folder;

  AppSettings get s => widget.manager.settings;

  @override
  void initState() {
    super.initState();
    _folder = TextEditingController(text: s.folder);
  }

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.manager.saveSettings();
    if (mounted) setState(() {});
  }

  Future<void> _pickQuality() async {
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final q in AppSettings.qualities)
              ListTile(
                leading: Icon(
                  q == s.defaultQuality ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: q == s.defaultQuality ? C.cyan : C.muted,
                ),
                title: Text(q),
                onTap: () => Navigator.pop(c, q),
              ),
          ],
        ),
      ),
    );
    if (v != null) {
      s.defaultQuality = v;
      await _save();
    }
  }

  Future<void> _saveFolder() async {
    final f = _folder.text.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '');
    s.folder = f.isEmpty ? 'NexGrab' : f;
    _folder.text = s.folder;
    await _save();
    if (mounted) toast(context, 'Folder: Download/${s.folder}');
  }

  Widget _row(IconData icon, String title, String sub, {Widget? trailing, VoidCallback? onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(icon, color: C.cyan),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: C.text, fontWeight: FontWeight.w700)),
                  Text(sub, style: const TextStyle(color: C.muted, fontSize: 12.5)),
                ],
              ),
            ),
            if (trailing != null) trailing,
          ],
        ),
      ),
    );
  }

  Future<void> _update() async {
    try {
      final v = await widget.manager.updateYtdlp();
      if (mounted) toast(context, 'yt-dlp updated: $v');
    } catch (e) {
      if (mounted) toast(context, 'Update fail: $e', error: true);
    }
    if (mounted) setState(() {});
  }

  Future<void> _cookies() async {
    try {
      final ok = await widget.manager.pickCookies();
      if (mounted && ok) toast(context, 'Cookies file set ho gayi');
    } catch (e) {
      if (mounted) toast(context, '$e', error: true);
    }
    if (mounted) setState(() {});
  }

  Widget _engineCard() {
    final m = widget.manager;
    final status = m.ytdlpReady
        ? 'yt-dlp ${m.ytdlpVersion} · ready'
        : (m.ytdlpInitError.isNotEmpty ? 'Error: ${m.ytdlpInitError}' : 'Engine shuru ho raha hai...');
    final hasCookies = m.settings.cookieFile.isNotEmpty;
    return GlassCard(
      child: Column(
        children: [
          _row(
            Icons.memory_rounded,
            'Download engine (1000+ sites)',
            status,
            trailing: TextButton(
              onPressed: m.ytdlpUpdating ? null : _update,
              child: Text(m.ytdlpUpdating ? 'Updating...' : 'Update'),
            ),
          ),
          const Divider(height: 8),
          _row(
            Icons.cookie_outlined,
            'Cookies file (cookies.txt)',
            hasCookies ? 'Set hai · login wali videos chalengi' : 'Instagram / YouTube login ke liye (optional)',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasCookies)
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: C.muted),
                    onPressed: () async {
                      await m.clearCookies();
                      if (mounted) setState(() {});
                    },
                  ),
                TextButton(onPressed: _cookies, child: Text(hasCookies ? 'Change' : 'Select')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        const SectionTitle('Settings'),
        GlassCard(
          child: Column(
            children: [
              _row(Icons.high_quality_rounded, 'Default quality', s.defaultQuality,
                  trailing: const Icon(Icons.chevron_right_rounded, color: C.muted), onTap: _pickQuality),
              const Divider(height: 8),
              _row(
                Icons.tune_rounded,
                'Har dafa quality poochein',
                s.askQuality ? 'Analyze ke baad options dikhayein' : 'Seedha default quality download',
                trailing: Switch(
                  value: s.askQuality,
                  onChanged: (v) {
                    s.askQuality = v;
                    _save();
                  },
                ),
              ),
              const Divider(height: 8),
              _row(
                Icons.layers_rounded,
                'Ek waqt mein downloads',
                'Zyada = tez, lekin net divide hota hai',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final n in [1, 2, 3])
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: ChoiceChip(
                          label: Text('$n'),
                          selected: s.maxParallel == n,
                          onSelected: (_) {
                            s.maxParallel = n;
                            _save();
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.folder_rounded, color: C.cyan),
                  SizedBox(width: 14),
                  Text('Save folder', style: TextStyle(color: C.text, fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _folder,
                style: const TextStyle(color: C.text),
                decoration: InputDecoration(
                  prefixText: 'Download/',
                  prefixStyle: const TextStyle(color: C.muted),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.save_rounded, color: C.cyan),
                    onPressed: _saveFolder,
                  ),
                ),
                onSubmitted: (_) => _saveFolder(),
              ),
              const SizedBox(height: 8),
              const Text('Files phone ke Download folder mein save hoti hain, File Manager / Gallery mein nazar aati hain.',
                  style: TextStyle(color: C.muted, fontSize: 12.5, height: 1.4)),
            ],
          ),
        ),
        _engineCard(),
        GlassCard(
          child: Column(
            children: [
              _row(Icons.info_outline_rounded, 'NexGrab', 'Version $appVersion'),
              const Divider(height: 8),
              _row(Icons.code_rounded, 'Developer', 'WSNex'),
              const Divider(height: 8),
              _row(Icons.verified_user_outlined, 'Privacy', 'Koi account, tracking ya ads nahi'),
            ],
          ),
        ),
      ],
    );
  }
}
