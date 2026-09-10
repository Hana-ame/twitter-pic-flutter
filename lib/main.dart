// main.dart
// 应用入口：初始化 ECH 代理（进程内反向代理），展示用户列表。
//
// 与旧版 (v0.2.8) 的主要差异：
//   1. 删除了所有 per-request FFI 调用（fetchAsync / fetchToFileAsync）
//   2. 启动时调用 proxy.start() 启动本机 HTTP 代理
//   3. 所有网络请求通过 EchUrl.rewrite() 改写为走 127.0.0.1:port
//   4. 新增「重启 ECH」按钮（AppBar），用于代理异常时手动恢复
//   5. 新增 _startInFlight 守卫，防止并发启动
//   6. 重启后端口可能变化，通过 _port 字段统一管理

import 'package:flutter/material.dart';

import 'api/twitter_api.dart';
import 'services/proxy_manager.dart';
import 'services/storage_service.dart';
import 'screens/settings_screen.dart';
import 'screens/user_list_screen.dart';
import 'utils/doh_resolver.dart';
import 'widgets/fav_list.dart';
import 'widgets/tag_controller.dart';

const _kBuildNum = String.fromEnvironment('BUILD_NUM', defaultValue: 'dev');

// ─── 入口 ────────────────────────────────────────────────────────────────────

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await StorageService.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final ProxyManager _proxy = ProxyManager();
  bool _proxyReady = false;
  String? _proxyError;
  List<String> _logs = [];
  bool _showLog = false;
  bool _startInFlight = false;

  // ─── 启动 / 重启 ─────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _start();
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

      _logs = _proxy.getLogs();
      if (!mounted) return;
      setState(() => _proxyReady = true);
    } catch (e) {
      _logs = _proxy.getLogs();
      if (!mounted) return;
      setState(() => _proxyError = e.toString());
    } finally {
      _startInFlight = false;
    }
  }

  /// 运行中重启 ECH 代理。
  /// 用于代理静默失效、ECH 配置过期、或用户怀疑卡死时手动恢复。
  Future<void> _restart() async {
    final confirmed = await showDialog<bool>(
      context: context,
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
          content: Text('正在重启 ECH ...'), duration: Duration.zero),
    );

    await _start();
  }

  // ─── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Twitter Pic v$_kBuildNum',
      theme: ThemeData(
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
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Twitter Pic', style: TextStyle(fontWeight: FontWeight.w600)),
          actions: [
            IconButton(
              icon: const Icon(Icons.local_offer_outlined),
              tooltip: '标签管理',
              onPressed: () => Navigator.of(context).push(
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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            const Text('正在初始化 ECH ...', style: TextStyle(color: Colors.grey, fontSize: 14)),
          ],
        ),
      );
    }
    return _HomeScreen(proxy: _proxy);
  }

  @override
  void dispose() {
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
        destinations: [
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
  const FavoritesTab({required this.proxy});

  @override
  State<FavoritesTab> createState() => _FavoritesTabState();
}

class _FavoritesTabState extends State<FavoritesTab> {
  final TwitterApi _api = TwitterApi();

  @override
  void dispose() {
    _api.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListView(
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
          FavList(api: _api, proxy: widget.proxy),
        ],
      ),
    );
  }
}

// ─── 设置 Tab ────────────────────────────────────────────────────────────────

class SettingsTab extends StatefulWidget {
  final ProxyManager proxy;
  const SettingsTab({required this.proxy});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  @override
  Widget build(BuildContext context) {
    return SettingsScreen(proxy: widget.proxy, buildNum: _kBuildNum);
  }
}
