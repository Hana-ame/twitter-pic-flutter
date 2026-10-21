// main.dart
// 应用入口：初始化 ECH 代理（进程内反向代理），展示用户列表，支持外观主题切换与浏览历史。

import 'dart:async';
// 前缀导入：dart:ui 与 material 有同名导出（TextStyle / Image 等），
// 不带前缀会直接变成歧义错误。
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/painting.dart';

import 'api/twitter_api.dart';
import 'services/log_service.dart';
import 'services/poster_service.dart';
import 'services/proxy_manager.dart';
import 'services/storage_service.dart';
import 'screens/browse_history_screen.dart';
import 'screens/ranking_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/user_detail_screen.dart';
import 'screens/user_list_screen.dart';
import 'utils/doh_resolver.dart';
import 'widgets/fav_list.dart';
import 'widgets/progressive_image.dart';
import 'widgets/report_help.dart';
import 'widgets/tag_controller.dart';

const _kBuildNum = String.fromEnvironment('BUILD_NUM', defaultValue: 'dev');

// ─── 入口 ────────────────────────────────────────────────────────────────────

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    FlutterError.onError = (details) {
      LogService.recordError('FlutterError', details.exception, details.stack);
      FlutterError.presentError(details);
    };
    ui.PlatformDispatcher.instance.onError = (error, stack) {
      LogService.recordError('PlatformDispatcher', error, stack);
      return true;
    };

    PaintingBinding.instance.imageCache.maximumSizeBytes = 160 << 20;
    PaintingBinding.instance.imageCache.maximumSize = 1500;

    await StorageService.ensureInitialized();
    await LogService.ensureInitialized(buildNum: _kBuildNum);
    await PosterService.ensureInitialized();
    unawaited(ProgressiveDiskCache.ensureInitialized());

    final pendingExit = await LogService.takeUncleanExit();
    LogService.startSession();

    runApp(MyApp(pendingExit: pendingExit));
  }, (error, stack) {
    LogService.recordError('zone', error, stack);
  });
}

class MyApp extends StatefulWidget {
  /// 上次运行没有正常结束时的记录（正常启动为 null）。
  final Incident? pendingExit;

  const MyApp({super.key, this.pendingExit});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  final ProxyManager _proxy = ProxyManager();
  bool _proxyReady = false;
  String? _proxyError;
  List<String> _logs = [];
  bool _showLog = false;
  bool _startInFlight = false;
  String _themeMode = 'light';

  /// 用于在 MaterialApp 之上拿一个可用的 context 弹「上次异常结束」提示。
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  /// Go 日志轮询：把代理的日志环形缓冲持续搬到磁盘。
  Timer? _logTimer;

  // ─── 启动 / 重启 ─────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _themeMode = StorageService.getThemeMode();
    StorageService.changes.addListener(_onStorageChanged);
    WidgetsBinding.instance.addObserver(this);
    _start();
    _startLogPolling();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowExitReport());
  }

  void _onStorageChanged() {
    if (!mounted) return;
    final nextTheme = StorageService.getThemeMode();
    if (nextTheme != _themeMode) {
      setState(() => _themeMode = nextTheme);
    }
  }

  ThemeMode get _resolvedThemeMode {
    switch (_themeMode) {
      case 'dark':
        return ThemeMode.dark;
      case 'system':
        return ThemeMode.system;
      default:
        return ThemeMode.light;
    }
  }

  /// 上次没有正常结束时，主动提示用户加群反馈。
  void _maybeShowExitReport() {
    final incident = widget.pendingExit;
    if (incident == null || LogService.promptSuppressed || !mounted) return;
    final ctx = _navKey.currentContext;
    if (ctx == null) return;
    showExitReportDialog(ctx, incident: incident, extra: _runtimeContext());
  }

  /// 反馈包里附带的运行时上下文。
  Map<String, String> _runtimeContext() => <String, String>{
        '代理': _proxy.isRunning ? '运行中' : '已停止',
        '端口': '${_proxy.port ?? '-'}',
        'ECH 初始化': '${_proxy.isInitialized}',
      };

  void _startLogPolling() {
    _logTimer?.cancel();
    _logTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!LogService.isReady) return;
      unawaited(LogService.pollGoLogs(_proxy.getLogs()));
      if (_showLog && mounted) {
        final latest = _proxy.getLogs();
        if (latest.length != _logs.length) {
          _logs = latest;
          setState(() {});
        }
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      LogService.markCleanExit();
      unawaited(LogService.pollGoLogs(_proxy.getLogs()));
      unawaited(LogService.flush());
    } else if (state == AppLifecycleState.resumed) {
      LogService.markSessionActive();
    }
  }

  Future<void> _start() async {
    if (_startInFlight) return;
    _startInFlight = true;
    try {
      // 1. 解析 DoH 服务器 IP
      String? ip;
      for (var i = 0; i < 5; i++) {
        try {
          ip = await resolveDomainRobustly(kDohHost);
          break;
        } catch (e) {
          if (i >= 4) rethrow;
          await Future.delayed(const Duration(seconds: 2));
        }
      }

      // 2. 启动代理（内部完成 ECH 初始化 + 启动 HTTP 代理）
      final port = await _proxy.start(bootstrapIp: ip!);
      print('ECH proxy started on port $port');

      unawaited(LogService.pollGoLogs(_proxy.getLogs()));

      _logs = _proxy.getLogs();
      if (!mounted) return;
      setState(() => _proxyReady = true);
    } catch (e, st) {
      _logs = _proxy.getLogs();
      LogService.recordError('ProxyStart', e, st);
      if (!mounted) return;
      setState(() => _proxyError = e.toString());
    } finally {
      _startInFlight = false;
    }
  }

  /// 运行中重启 ECH 代理。
  Future<void> _restart() async {
    final navCtx = _navKey.currentContext;
    if (navCtx == null) return;
    final confirmed = await showDialog<bool>(
      context: navCtx,
      builder: (ctx) => AlertDialog(
        title: const Text('重启 ECH'),
        content: const Text(
            '将重新初始化 ECH 代理。\n\n'
            '进行中的图片/视频下载会中断。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('重启'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _proxyError = null;
      _proxyReady = false;
      _showLog = false;
    });

    if (!mounted) return;
    ScaffoldMessenger.maybeOf(_navKey.currentContext ?? context)?.showSnackBar(
      const SnackBar(
          content: Text('正在重启 ECH ...'), duration: Duration.zero),
    );

    await _start();
  }

  // ─── UI ──────────────────────────────────────────────────────────────────

  static final ThemeData _lightTheme = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF4F6CFF),
      brightness: Brightness.light,
    ),
    useMaterial3: true,
    appBarTheme: const AppBarTheme(
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 2,
      backgroundColor: Colors.transparent,
      foregroundColor: Color(0xFF4F6CFF),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade200),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: const Color(0xFF4F6CFF).withValues(alpha: 0.12),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      backgroundColor: const Color(0xFF333333),
    ),
  );

  static final ThemeData _darkTheme = ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF4F6CFF),
      brightness: Brightness.dark,
    ),
    useMaterial3: true,
    appBarTheme: const AppBarTheme(
      centerTitle: true,
      elevation: 0,
      scrolledUnderElevation: 2,
      backgroundColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.grey.shade800),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      indicatorColor: const Color(0xFF4F6CFF).withValues(alpha: 0.24),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Twitter Pic v$_kBuildNum',
      navigatorKey: _navKey,
      theme: _lightTheme,
      darkTheme: _darkTheme,
      themeMode: _resolvedThemeMode,
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Twitter Pic', style: TextStyle(fontWeight: FontWeight.w600)),
          actions: [
            IconButton(
              icon: const Icon(Icons.history),
              tooltip: '浏览历史',
              onPressed: () => _navKey.currentState?.push(
                MaterialPageRoute(
                  builder: (_) => BrowseHistoryScreen(proxy: _proxy),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.emoji_events_outlined),
              tooltip: '排行榜',
              onPressed: () => _navKey.currentState?.push(
                MaterialPageRoute(
                  builder: (routeCtx) => Scaffold(
                    appBar: AppBar(title: const Text('Emoji 排行榜')),
                    body: RankingScreen(
                      api: TwitterApi(),
                      onSelectUser: (profile) {
                        Navigator.of(routeCtx).push(
                          MaterialPageRoute(
                            builder: (_) => UserDetailScreen(
                              profile: profile,
                              proxy: _proxy,
                              tagBrowse: null,
                              recordHistory: true,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.local_offer_outlined),
              tooltip: '标签管理',
              onPressed: () => _navKey.currentState?.push(
                MaterialPageRoute(builder: (_) => const TagControllerScreen()),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.restart_alt),
              tooltip: _startInFlight ? '正在初始化...' : '重启 ECH',
              onPressed: _startInFlight ? null : _restart,
            ),
            IconButton(
              icon: Icon(_showLog ? Icons.close : Icons.list),
              tooltip: '日志',
              onPressed: () => setState(() => _showLog = !_showLog),
            ),
          ],
        ),
        body: _showLog ? _buildLog() : _buildBody(),
      ),
    );
  }

  Widget _buildLog() {
    if (_logs.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.receipt_long_outlined, size: 48, color: Colors.grey),
            SizedBox(height: 8),
            Text('暂无日志', style: TextStyle(color: Colors.grey, fontSize: 13)),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _logs.length,
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text(
          _logs[i],
          style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_proxyError != null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outlined, size: 56, color: Colors.red),
              const SizedBox(height: 16),
              const Text('ECH 代理启动失败', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              SelectableText(
                _proxyError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
              if (_logs.isNotEmpty) ...[
                const Divider(height: 32),
                const Text('--- Go 日志 ---',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: _logs.map((l) => Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(l, style: const TextStyle(fontSize: 10, fontFamily: 'monospace')),
                    )).toList(),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _startInFlight
                    ? null
                    : () {
                        setState(() {
                          _proxyError = null;
                          _proxyReady = false;
                        });
                        _start();
                      },
                icon: _startInFlight
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (!_proxyReady) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('正在初始化 ECH ...', style: TextStyle(color: Colors.grey, fontSize: 14)),
          ],
        ),
      );
    }
    return _HomeScreen(proxy: _proxy);
  }

  @override
  void dispose() {
    StorageService.changes.removeListener(_onStorageChanged);
    _logTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _proxy.dispose();
    super.dispose();
  }
}

// ─── 主界面：底部导航 ────────────────────────────────────────────────────────

class _HomeScreen extends StatefulWidget {
  final ProxyManager proxy;
  const _HomeScreen({required this.proxy});

  @override
  State<_HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<_HomeScreen> {
  int _tabIndex = 0;
  // 每次切到收藏 Tab 时 +1，强制重建 FavoritesTab 以重新读取收藏列表。
  int _favTick = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tabIndex,
        children: [
          UserListScreen(proxy: widget.proxy),
          FavoritesTab(key: ValueKey('fav$_favTick'), proxy: widget.proxy),
          SettingsTab(proxy: widget.proxy),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() {
          _tabIndex = i;
          if (i == 1) _favTick++;
        }),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.people_outlined),
            selectedIcon: Icon(Icons.people),
            label: '用户',
          ),
          NavigationDestination(
            icon: Icon(Icons.favorite_border),
            selectedIcon: Icon(Icons.favorite),
            label: '收藏',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}

// ─── 收藏夹 Tab ──────────────────────────────────────────────────────────────

class FavoritesTab extends StatefulWidget {
  final ProxyManager proxy;
  const FavoritesTab({super.key, required this.proxy});

  @override
  State<FavoritesTab> createState() => _FavoritesTabState();
}

class _FavoritesTabState extends State<FavoritesTab> {
  final TwitterApi _api = TwitterApi();
  int _listTick = 0;

  @override
  void dispose() {
    _api.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: RefreshIndicator(
        color: const Color(0xFF4F6CFF),
        onRefresh: () async {
          setState(() => _listTick++);
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(8),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                '收藏夹',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(height: 8),
            FavList(
              key: ValueKey('favlist$_listTick'),
              api: _api,
              proxy: widget.proxy,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 设置 Tab ────────────────────────────────────────────────────────────────

class SettingsTab extends StatefulWidget {
  final ProxyManager proxy;
  const SettingsTab({super.key, required this.proxy});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  @override
  Widget build(BuildContext context) {
    return SettingsScreen(proxy: widget.proxy, buildNum: _kBuildNum, embedded: true);
  }
}
