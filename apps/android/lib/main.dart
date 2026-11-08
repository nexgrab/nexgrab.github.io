import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/manager.dart';
import 'core/models.dart';
import 'native.dart';
import 'ui/downloads_page.dart';
import 'ui/history_page.dart';
import 'ui/home_page.dart';
import 'ui/network_page.dart';
import 'ui/settings_page.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: C.bg2,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const RskApp());
}

class RskApp extends StatelessWidget {
  const RskApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NexGrab',
      theme: buildTheme(),
      home: const Shell(),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  final _native = AndroidNative();
  late final DownloadManager _manager = DownloadManager(_native);
  final _homeKey = GlobalKey<HomePageState>();
  StreamSubscription<void>? _changes;
  StreamSubscription<String>? _shares;
  int _index = 0;
  String? _startupError;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      await _native.init();
      await _manager.init();
      _changes = _manager.changes.listen((_) {
        if (mounted) setState(() {});
      });
      _shares = _native.sharedLinks.listen(_onShared);
      final shared = await _native.takeShared();
      if (mounted) setState(() {});
      if (shared != null && shared.trim().isNotEmpty) _onShared(shared);
    } catch (e) {
      if (mounted) setState(() => _startupError = e.toString());
    }
  }

  void _onShared(String text) {
    setState(() => _index = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) => _homeKey.currentState?.analyzeShared(text));
  }

  @override
  void dispose() {
    _changes?.cancel();
    _shares?.cancel();
    _manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = _startupError != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Start error:\n$_startupError',
                  textAlign: TextAlign.center, style: const TextStyle(color: C.bad)),
            ),
          )
        : !_manager.ready
            ? const Center(child: CircularProgressIndicator())
            : IndexedStack(
                index: _index,
                children: [
                  HomePage(
                    key: _homeKey,
                    manager: _manager,
                    onOpenDownloads: () => setState(() => _index = 1),
                  ),
                  DownloadsPage(manager: _manager),
                  NetworkPage(manager: _manager),
                  HistoryPage(manager: _manager),
                  SettingsPage(manager: _manager),
                ],
              );

    final running = _manager.ready
        ? _manager.tasks.where((t) => t.status.isActive || t.status == TaskStatus.queued).length
        : 0;

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-0.9, -1.1),
            radius: 1.4,
            colors: [Color(0xFF0E2340), C.bg],
          ),
        ),
        child: SafeArea(bottom: false, child: body),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (v) => setState(() => _index = v),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home_rounded, color: C.cyan),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: running > 0,
              label: Text('$running'),
              child: const Icon(Icons.download_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: running > 0,
              label: Text('$running'),
              child: const Icon(Icons.download_rounded, color: C.cyan),
            ),
            label: 'Downloads',
          ),
          const NavigationDestination(
            icon: Icon(Icons.hub_outlined),
            selectedIcon: Icon(Icons.hub_rounded, color: C.cyan),
            label: 'Network',
          ),
          const NavigationDestination(
            icon: Icon(Icons.history_rounded),
            selectedIcon: Icon(Icons.history_rounded, color: C.cyan),
            label: 'History',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings_rounded, color: C.cyan),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
