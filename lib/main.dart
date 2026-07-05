import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(460, 680),
    center: true,
    title: 'Mac Never Sleep',
    titleBarStyle: TitleBarStyle.normal,
  );
  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const MacNeverSleepApp());
}

class MacNeverSleepApp extends StatelessWidget {
  const MacNeverSleepApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.tealAccent,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with TrayListener, WindowListener {
  /// The running `caffeinate` process while "Keep Awake" is on.
  Process? _caffeinate;

  /// Whether `pmset disablesleep` is active (survives lid close).
  bool _lidCloseAwake = false;

  bool _busy = false;

  Timer? _statsTimer;
  _SystemStats _stats = _SystemStats.empty();

  /// Which stats are shown as text next to the menu bar icon.
  Set<String> _shownStats = {'battery'};

  bool get _keepAwake => _caffeinate != null;
  bool get _active => _keepAwake || _lidCloseAwake;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.setPreventClose(true);
    trayManager.addListener(this);
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList('shownStats');
    if (saved != null) _shownStats = saved.toSet();
    await _syncLidStateFromSystem();
    if (mounted) setState(() {});
    // tray_manager only creates the status item once an icon is set,
    // so setIcon must come before setTitle/setContextMenu.
    try {
      await trayManager.setIcon('assets/tray_sleep.png', isTemplate: true);
      await _refreshTray();
    } catch (_) {}
    await _refreshStats();
    _statsTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _refreshStats());
  }

  Future<void> _refreshStats() async {
    _stats = await _SystemStats.gather();
    if (mounted) setState(() {});
    try {
      await _refreshTray();
    } catch (_) {}
  }

  /// Reads the current SleepDisabled value so the UI matches reality
  /// even if the app was quit without turning it off.
  Future<void> _syncLidStateFromSystem() async {
    try {
      final result = await Process.run('pmset', ['-g']);
      final match =
          RegExp(r'SleepDisabled\s+(\d)').firstMatch(result.stdout.toString());
      if (match != null) {
        _lidCloseAwake = match.group(1) == '1';
      }
    } catch (_) {}
  }

  Future<void> _refreshTray() async {
    await trayManager.setIcon(
      _active ? 'assets/tray_awake.png' : 'assets/tray_sleep.png',
      isTemplate: true,
    );
    final titleParts = <String>[
      if (_shownStats.contains('battery') && _stats.batteryPercent != null)
        '${_stats.batteryPercent}%',
      if (_shownStats.contains('cpu') && _stats.cpuUsage != null)
        'CPU ${_stats.cpuUsage}',
      if (_shownStats.contains('ram') && _stats.ramUsage != null)
        'RAM ${_stats.ramUsedShort}',
      if (_shownStats.contains('temp') && _stats.batteryTemp != null)
        '${_stats.batteryTemp}',
      if (_shownStats.contains('cycles') && _stats.cycleCount != null)
        '${_stats.cycleCount}cyc',
    ];
    await trayManager.setTitle(
        titleParts.isEmpty ? '' : ' ${titleParts.join('  ')}');

    await trayManager.setContextMenu(Menu(items: [
      MenuItem(
        key: 'noop',
        label: '🔋 Battery: ${_stats.batteryLine}',
        disabled: true,
      ),
      MenuItem(
        key: 'noop',
        label: '🔁 Cycle Count: ${_stats.cycleCount ?? '—'}',
        disabled: true,
      ),
      MenuItem(
        key: 'noop',
        label: '🌡 Battery Temp: ${_stats.batteryTemp ?? '—'}',
        disabled: true,
      ),
      MenuItem(
        key: 'noop',
        label: '⚙️ CPU Usage: ${_stats.cpuUsage ?? '—'}',
        disabled: true,
      ),
      MenuItem(
        key: 'noop',
        label: '🧠 RAM: ${_stats.ramUsage ?? '—'}',
        disabled: true,
      ),
      MenuItem.separator(),
      MenuItem.submenu(
        label: 'Show in Menu Bar',
        submenu: Menu(items: [
          MenuItem.checkbox(
            key: 'stat_battery',
            label: 'Battery %',
            checked: _shownStats.contains('battery'),
          ),
          MenuItem.checkbox(
            key: 'stat_cpu',
            label: 'CPU Usage',
            checked: _shownStats.contains('cpu'),
          ),
          MenuItem.checkbox(
            key: 'stat_ram',
            label: 'RAM Used',
            checked: _shownStats.contains('ram'),
          ),
          MenuItem.checkbox(
            key: 'stat_temp',
            label: 'Battery Temp',
            checked: _shownStats.contains('temp'),
          ),
          MenuItem.checkbox(
            key: 'stat_cycles',
            label: 'Cycle Count',
            checked: _shownStats.contains('cycles'),
          ),
        ]),
      ),
      MenuItem.separator(),
      MenuItem.checkbox(
        key: 'keep_awake',
        label: 'Keep Mac Awake',
        checked: _keepAwake,
      ),
      MenuItem.checkbox(
        key: 'lid_awake',
        label: 'Stay Awake When Lid Is Closed',
        checked: _lidCloseAwake,
      ),
      MenuItem.separator(),
      MenuItem(key: 'screen_off', label: 'Turn Screen Off Now'),
      MenuItem(key: 'show', label: 'Open Mac Never Sleep'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit'),
    ]));
  }

  Future<void> _toggleKeepAwake(bool value) async {
    if (value && !_keepAwake) {
      // -i idle sleep, -s system sleep — display is NOT held awake,
      // so the screen can dim/turn off and save battery while
      // background work (e.g. a server) keeps running.
      _caffeinate = await Process.start('caffeinate', ['-is']);
    } else if (!value) {
      _caffeinate?.kill();
      _caffeinate = null;
    }
    setState(() {});
    try {
      await _refreshTray();
    } catch (_) {}
  }

  Future<void> _toggleLidCloseAwake(bool value) async {
    setState(() => _busy = true);
    final newValue = value ? 1 : 0;
    // pmset disablesleep needs root — osascript shows the admin
    // password dialog. If the user cancels, exit code is non-zero.
    final result = await Process.run('osascript', [
      '-e',
      'do shell script "pmset -a disablesleep $newValue" '
          'with administrator privileges',
    ]);
    if (result.exitCode == 0) {
      _lidCloseAwake = value;
    }
    setState(() => _busy = false);
    try {
      await _refreshTray();
    } catch (_) {}
  }

  Future<void> _turnScreenOff() async {
    // Blacks the display immediately; the system stays awake because
    // caffeinate only blocks system sleep, not display sleep.
    await Process.run('pmset', ['displaysleepnow']);
  }

  Future<void> _quit() async {
    _caffeinate?.kill();
    if (_lidCloseAwake) {
      // Never leave sleep disabled behind after quitting.
      await Process.run('osascript', [
        '-e',
        'do shell script "pmset -a disablesleep 0" '
            'with administrator privileges',
      ]);
    }
    try {
      await trayManager.destroy();
    } catch (_) {}
    exit(0);
  }

  @override
  void onWindowClose() {
    _quit();
  }

  @override
  void onTrayIconMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  Future<void> _toggleStat(String stat) async {
    if (!_shownStats.remove(stat)) _shownStats.add(stat);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('shownStats', _shownStats.toList());
    try {
      await _refreshTray();
    } catch (_) {}
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final key = menuItem.key ?? '';
    if (key.startsWith('stat_')) {
      _toggleStat(key.substring(5));
      return;
    }
    switch (menuItem.key) {
      case 'keep_awake':
        _toggleKeepAwake(!_keepAwake);
      case 'lid_awake':
        _toggleLidCloseAwake(!_lidCloseAwake);
      case 'screen_off':
        _turnScreenOff();
      case 'show':
        windowManager.show();
        windowManager.focus();
      case 'quit':
        _quit();
    }
  }

  @override
  void dispose() {
    _statsTimer?.cancel();
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    _caffeinate?.kill();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StatusScene(active: _active),
            const SizedBox(height: 8),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              child: Text(
                _active
                    ? 'Your Mac will stay awake'
                    : 'Normal sleep is allowed',
                key: ValueKey(_active),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: 24),
            Card(
              child: SwitchListTile(
                secondary: DisplaySleepPreview(on: _keepAwake),
                title: const Text('Keep Mac Awake'),
                subtitle: const Text(
                    'System stays awake for servers and downloads. '
                    'Display still sleeps to save battery.'),
                value: _keepAwake,
                onChanged: _toggleKeepAwake,
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: SwitchListTile(
                secondary: LidClosePreview(on: _lidCloseAwake),
                title: const Text('Stay Awake When Lid Is Closed'),
                subtitle: const Text(
                    'Screen turns off, but servers keep running with the '
                    'MacBook closed. Needs your admin password.'),
                value: _lidCloseAwake,
                onChanged: _busy ? null : _toggleLidCloseAwake,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _turnScreenOff,
              icon: const Icon(Icons.brightness_1_outlined),
              label: const Text('Turn Screen Off Now'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
            const Spacer(),
            Text(
              '⚠️ With lid-closed mode on, the Mac stays awake in a bag — '
              'watch battery and heat. Both switches turn off safely when '
              'you quit the app.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// System stats shown in the menu bar dropdown, read from pmset,
/// ioreg, top and sysctl — no special permissions required.
class _SystemStats {
  _SystemStats({
    this.batteryPercent,
    this.batteryState,
    this.cycleCount,
    this.batteryTemp,
    this.cpuUsage,
    this.ramUsage,
  });

  _SystemStats.empty()
      : batteryPercent = null,
        batteryState = null,
        cycleCount = null,
        batteryTemp = null,
        cpuUsage = null,
        ramUsage = null;

  final int? batteryPercent;
  final String? batteryState;
  final int? cycleCount;
  final String? batteryTemp;
  final String? cpuUsage;
  final String? ramUsage;

  String get batteryLine {
    if (batteryPercent == null) return '—';
    final state = batteryState != null ? ' ($batteryState)' : '';
    return '$batteryPercent%$state';
  }

  /// Compact RAM string for the menu bar title, e.g. "7.3G".
  String get ramUsedShort {
    final match = RegExp(r'^([\d.]+)').firstMatch(ramUsage ?? '');
    return match != null ? '${match.group(1)}G' : '—';
  }

  static Future<_SystemStats> gather() async {
    int? percent;
    String? state;
    int? cycles;
    String? temp;
    String? cpu;
    String? ram;

    try {
      final results = await Future.wait([
        Process.run('pmset', ['-g', 'batt']),
        Process.run('ioreg', ['-rn', 'AppleSmartBattery']),
        // Two samples: the first CPU line is a since-boot average,
        // only the second reflects current load.
        Process.run('top', ['-l', '2', '-n', '0', '-s', '1']),
        Process.run('sysctl', ['-n', 'hw.memsize']),
      ]);

      final batt = results[0].stdout.toString();
      final battMatch = RegExp(r'(\d+)%;\s*([^;]+);?').firstMatch(batt);
      if (battMatch != null) {
        percent = int.tryParse(battMatch.group(1)!);
        state = battMatch.group(2)!.trim();
      }

      final ioreg = results[1].stdout.toString();
      final cycleMatch =
          RegExp(r'"CycleCount"\s*=\s*(\d+)').firstMatch(ioreg);
      if (cycleMatch != null) cycles = int.tryParse(cycleMatch.group(1)!);
      final tempMatch =
          RegExp(r'"Temperature"\s*=\s*(\d+)').firstMatch(ioreg);
      if (tempMatch != null) {
        final celsius = int.parse(tempMatch.group(1)!) / 100.0;
        temp = '${celsius.toStringAsFixed(1)}°C';
      }

      final top = results[2].stdout.toString();
      final cpuMatches = RegExp(
              r'CPU usage:\s*([\d.]+)% user,\s*([\d.]+)% sys,\s*([\d.]+)% idle')
          .allMatches(top)
          .toList();
      if (cpuMatches.isNotEmpty) {
        final idle = double.parse(cpuMatches.last.group(3)!);
        cpu = '${(100 - idle).toStringAsFixed(1)}%';
      }
      final memMatch =
          RegExp(r'PhysMem:\s*(\d+)([MG]) used').firstMatch(top);
      final totalBytes = int.tryParse(results[3].stdout.toString().trim());
      if (memMatch != null && totalBytes != null) {
        var usedGb = double.parse(memMatch.group(1)!);
        if (memMatch.group(2) == 'M') usedGb /= 1024;
        final totalGb = totalBytes / (1024 * 1024 * 1024);
        ram = '${usedGb.toStringAsFixed(1)} / ${totalGb.toStringAsFixed(0)} GB';
      }
    } catch (_) {}

    return _SystemStats(
      batteryPercent: percent,
      batteryState: state,
      cycleCount: cycles,
      batteryTemp: temp,
      cpuUsage: cpu,
      ramUsage: ram,
    );
  }
}

/// Big looping scene at the top: floating z-z-z while sleep is allowed,
/// a glowing coffee cup with rising steam while the Mac is kept awake.
class StatusScene extends StatefulWidget {
  const StatusScene({super.key, required this.active});

  final bool active;

  @override
  State<StatusScene> createState() => _StatusSceneState();
}

class _StatusSceneState extends State<StatusScene>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 150,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          return widget.active ? _awake(t) : _asleep(t, scheme);
        },
      ),
    );
  }

  Widget _awake(double t) {
    final pulse = 0.5 + 0.5 * math.sin(t * 2 * math.pi);
    return Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 100 + 16 * pulse,
          height: 100 + 16 * pulse,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.orangeAccent.withValues(alpha: 0.10 + 0.08 * pulse),
          ),
        ),
        const Icon(Icons.coffee, size: 60, color: Colors.orangeAccent),
        for (int i = 0; i < 3; i++) _steamPuff(t, i),
      ],
    );
  }

  Widget _steamPuff(double t, int i) {
    final p = (t * 1.5 + i / 3) % 1.0;
    return Transform.translate(
      offset: Offset(
        (i - 1) * 12 + 6 * math.sin((p * 3 + i) * math.pi),
        -38 - 34 * p,
      ),
      child: Opacity(
        opacity: (1 - p) * 0.7,
        child: Container(
          width: 7,
          height: 7,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white70,
          ),
        ),
      ),
    );
  }

  Widget _asleep(double t, ColorScheme scheme) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Icon(Icons.bedtime, size: 56, color: scheme.primary),
        for (int i = 0; i < 3; i++) _floatingZ(t, i, scheme),
      ],
    );
  }

  Widget _floatingZ(double t, int i, ColorScheme scheme) {
    final p = (t + i / 3) % 1.0;
    return Transform.translate(
      offset: Offset(34 + 26 * p + 6 * i, -14 - 42 * p),
      child: Opacity(
        opacity: (1 - p).clamp(0.0, 1.0),
        child: Text(
          'z',
          style: TextStyle(
            fontSize: 16.0 + 5 * i,
            fontWeight: FontWeight.bold,
            color: scheme.primary,
          ),
        ),
      ),
    );
  }
}

/// Mini animation for "Keep Mac Awake": the display keeps dimming
/// (display may sleep) while the green server dot keeps blinking
/// (system stays awake).
class DisplaySleepPreview extends StatefulWidget {
  const DisplaySleepPreview({super.key, required this.on});

  final bool on;

  @override
  State<DisplaySleepPreview> createState() => _DisplaySleepPreviewState();
}

class _DisplaySleepPreviewState extends State<DisplaySleepPreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          final dim = widget.on
              ? 0.25 + 0.75 * (0.5 + 0.5 * math.cos(t * 2 * math.pi))
              : 1.0;
          final pulse =
              widget.on ? 0.6 + 0.4 * math.sin(t * 4 * math.pi) : 1.0;
          return Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: dim,
                child: const Icon(Icons.desktop_windows, size: 30),
              ),
              Positioned(
                right: 2,
                bottom: 2,
                child: Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.on
                        ? Colors.greenAccent.withValues(alpha: pulse)
                        : Colors.grey,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Mini animation for lid-closed mode: the laptop lid keeps closing
/// while the green server dot keeps blinking — closed but running.
class LidClosePreview extends StatefulWidget {
  const LidClosePreview({super.key, required this.on});

  final bool on;

  @override
  State<LidClosePreview> createState() => _LidClosePreviewState();
}

class _LidClosePreviewState extends State<LidClosePreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          // Ease the lid between open (slightly tilted) and closed.
          final closeT =
              widget.on ? 0.5 - 0.5 * math.cos(t * 2 * math.pi) : 0.0;
          final angle = 0.25 + closeT * 1.25;
          final pulse =
              widget.on ? 0.6 + 0.4 * math.sin(t * 4 * math.pi) : 1.0;
          return Stack(
            alignment: Alignment.bottomCenter,
            children: [
              // Base of the laptop.
              Positioned(
                bottom: 8,
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.blueGrey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Lid, hinged at the bottom.
              Positioned(
                bottom: 11,
                child: Transform(
                  alignment: Alignment.bottomCenter,
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 0.004)
                    ..rotateX(angle),
                  child: Container(
                    width: 32,
                    height: 22,
                    decoration: BoxDecoration(
                      color: Colors.blueGrey.shade500,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 0,
                top: 4,
                child: Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.on
                        ? Colors.greenAccent.withValues(alpha: pulse)
                        : Colors.grey,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
