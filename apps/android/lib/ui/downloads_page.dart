import 'package:flutter/material.dart';

import '../core/manager.dart';
import '../core/models.dart';
import '../core/net.dart';
import 'theme.dart';
import 'widgets.dart';

class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key, required this.manager});

  final DownloadManager manager;

  @override
  Widget build(BuildContext context) {
    final tasks = manager.tasks;
    final hasFinished = tasks.any((t) => t.status == TaskStatus.done || t.status == TaskStatus.canceled);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        SectionTitle(
          'Downloads',
          trailing: hasFinished
              ? TextButton.icon(
                  onPressed: manager.clearFinished,
                  icon: const Icon(Icons.cleaning_services_rounded, size: 18),
                  label: const Text('Clear'),
                )
              : null,
        ),
        if (tasks.isEmpty)
          const EmptyState(
            icon: Icons.download_rounded,
            title: 'Koi download nahi',
            subtitle: 'Home par link paste karein aur Analyze dabayein.',
          ),
        for (final t in tasks) _TaskCard(task: t, manager: manager),
      ],
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task, required this.manager});

  final DownloadTask task;
  final DownloadManager manager;

  Future<void> _open(BuildContext context) async {
    final uri = task.savedUri;
    if (uri == null) return;
    try {
      await manager.native.open(uri, task.option.mime);
    } catch (e) {
      if (context.mounted) toast(context, friendlyError(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = task;
    final s = t.status;
    final color = statusColor(s);
    final indeterminate = s == TaskStatus.merging || s == TaskStatus.saving || s == TaskStatus.resolving ||
        (s == TaskStatus.downloading && t.progress == null);

    final stats = <String>[];
    if (s == TaskStatus.downloading || s == TaskStatus.paused || s == TaskStatus.queued) {
      stats.add(t.total > 0 ? '${fmtBytes(t.received)} / ${fmtBytes(t.total)}' : fmtBytes(t.received));
    }
    if (s == TaskStatus.downloading && t.speed > 0) {
      stats.add('${fmtBytes(t.speed)}/s');
      if (t.eta != null) stats.add('ETA ${fmtDuration(t.eta)}');
    }
    if (s == TaskStatus.done) stats.add(fmtBytes(t.total));
    if (t.item.isNotEmpty && !s.isFinished) stats.insert(0, 'item ${t.item}');

    return GlassCard(
      glow: s.isActive,
      padding: const EdgeInsets.fromLTRB(14, 14, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MediaThumb(url: t.thumbnail, width: 84, height: 52, icon: iconForMime(t.option.mime)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.fileName,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: C.text, fontWeight: FontWeight.w700, height: 1.25)),
                    const SizedBox(height: 4),
                    Text('${t.option.label} · ${t.site}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: C.muted, fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (!s.isFinished || s == TaskStatus.failed)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  minHeight: 8,
                  value: indeterminate ? null : (t.progress ?? 0),
                  color: color,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Pill(
                s == TaskStatus.downloading && t.progress != null
                    ? '${(t.progress! * 100).toStringAsFixed(1)}%'
                    : (t.stage.isNotEmpty ? t.stage : s.label),
                color: color,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(stats.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: C.muted, fontSize: 12)),
              ),
              ..._actions(context),
            ],
          ),
          if (s == TaskStatus.failed && t.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 6),
              child: Text(t.error!, style: const TextStyle(color: C.bad, fontSize: 12.5, height: 1.35)),
            ),
          if (s == TaskStatus.done && t.savedPath != null)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 6),
              child: Text(t.savedPath!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: C.muted, fontSize: 11.5)),
            ),
        ],
      ),
    );
  }

  List<Widget> _actions(BuildContext context) {
    Widget btn(IconData i, String tip, VoidCallback f, {Color color = C.text}) => IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: tip,
          icon: Icon(i, color: color, size: 22),
          onPressed: f,
        );
    final id = task.id;
    switch (task.status) {
      case TaskStatus.downloading:
      case TaskStatus.queued:
      case TaskStatus.resolving:
        return [
          btn(Icons.pause_rounded, 'Pause', () => manager.pause(id)),
          btn(Icons.close_rounded, 'Cancel', () => manager.cancel(id), color: C.bad),
        ];
      case TaskStatus.paused:
        return [
          btn(Icons.play_arrow_rounded, 'Resume', () => manager.resume(id), color: C.cyan),
          btn(Icons.close_rounded, 'Cancel', () => manager.cancel(id), color: C.bad),
        ];
      case TaskStatus.failed:
      case TaskStatus.canceled:
        return [
          btn(Icons.refresh_rounded, 'Retry', () => manager.resume(id), color: C.cyan),
          btn(Icons.delete_outline_rounded, 'Remove', () => manager.remove(id), color: C.muted),
        ];
      case TaskStatus.done:
        return [
          btn(Icons.open_in_new_rounded, 'Open', () => _open(context), color: C.ok),
          btn(Icons.delete_outline_rounded, 'Remove from list', () => manager.remove(id), color: C.muted),
        ];
      case TaskStatus.merging:
      case TaskStatus.saving:
        return const [SizedBox(width: 8)];
    }
  }
}
