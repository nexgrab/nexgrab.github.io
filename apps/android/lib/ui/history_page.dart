import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/manager.dart';
import '../core/models.dart';
import '../core/net.dart';
import 'theme.dart';
import 'widgets.dart';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key, required this.manager});
  final DownloadManager manager;

  Future<void> _open(BuildContext context, HistoryEntry h) async {
    try {
      await manager.native.open(h.uri, h.mime);
    } catch (e) {
      if (context.mounted) {
        toast(context, '${friendlyError(e)}\nFile shayad delete ya move ho chuki hai.', error: true);
      }
    }
  }

  Future<void> _clearAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('History clear karein?'),
        content: const Text('Sirf list saaf hogi. Downloaded files phone mein rahengi.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) manager.clearHistory();
  }

  @override
  Widget build(BuildContext context) {
    final list = manager.history;
    final total = list.fold<int>(0, (a, h) => a + h.size);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        SectionTitle(
          'History',
          trailing: list.isEmpty
              ? null
              : TextButton.icon(
                  onPressed: () => _clearAll(context),
                  icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                  label: const Text('Clear'),
                ),
        ),
        if (list.isEmpty)
          const EmptyState(
            icon: Icons.history_rounded,
            title: 'Abhi history khali hai',
            subtitle: 'Mukammal downloads yahan nazar aayenge.',
          )
        else
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 10),
            child: Text('${list.length} files · ${fmtBytes(total)}',
                style: const TextStyle(color: C.muted, fontSize: 12.5)),
          ),
        for (final h in list)
          GlassCard(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            margin: const EdgeInsets.only(bottom: 10),
            onTap: () => _open(context, h),
            child: Row(
              children: [
                MediaThumb(url: h.thumbnail, width: 72, height: 46, icon: iconForMime(h.mime)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(h.fileName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: C.text, fontWeight: FontWeight.w600, height: 1.25)),
                      const SizedBox(height: 3),
                      Text('${fmtBytes(h.size)} · ${h.quality} · ${fmtDate(h.finished)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: C.muted, fontSize: 11.5)),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert_rounded, color: C.muted),
                  color: C.surface2,
                  onSelected: (v) async {
                    switch (v) {
                      case 'open':
                        await _open(context, h);
                      case 'copy':
                        await Clipboard.setData(ClipboardData(text: h.sourceUrl));
                        if (context.mounted) toast(context, 'Link copy ho gaya');
                      case 'remove':
                        manager.removeHistory(h.id);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'open', child: Text('Open')),
                    PopupMenuItem(value: 'copy', child: Text('Copy source link')),
                    PopupMenuItem(value: 'remove', child: Text('Remove from history')),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}
