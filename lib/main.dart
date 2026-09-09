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

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'services/proxy_manager.dart';
import 'services/storage_service.dart';
import 'screens/settings_screen.dart';
import 'screens/user_list_screen.dart';
import 'utils/ech_url.dart';
import 'widgets/tag_controller.dart';

const _kBuildNum = String.fromEnvironment('BUILD_NUM', defaultValue: 'dev');
const _kDohHost = 'moonchan.xyz';
const _kDohUrl = 'https://moonchan.xyz/doh';

// ─── DoH 域名解析（系统 DNS → 腾讯 DNS → 阿里 DNS）──────────────────────────

Future<String> _resolveDomainRobustly(String domain) async {
  try {
    final result = await InternetAddress.lookup(domain);
    if (result.isNotEmpty) return result.first.address;
  } catch (e) {
    print('System DNS failed: $e');
  }

  final dohUrls = [
    'http://119.29.29.29/d?dn=$domain',
    'https://223.5.5.5/resolve?name=$domain&type=1',
  ];

  for (final url in dohUrls) {
    final client = HttpClient();
    try {
      client.badCertificateCallback = (cert, host, port) => true;
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('Accept', 'application/dns-json');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == 200 && body.isNotEmpty) {
        if (url.contains('119.29.29.29')) {
          final ips = body.split(';');
          if (ips.isNotEmpty && ips.first.contains('.')) return ips.first;
        }
        if (url.contains('223.5.5.5')) {
          final json = jsonDecode(body);
          if (json['Status'] == 0 && json['Answer'] != null) {
            for (final ans in json['Answer']) {
              if (ans['type'] == 1) return ans['data'].toString();
            }
          }
        }
      }
    } catch (e) {
      print('HTTP DNS failed: $url -> $e');
    } finally {
      client.close();
    }
  }

  throw Exception('failed to resolve $domain');
}

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
          ip = await _resolveDomainRobustly(_kDohHost);
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
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: Text('Twitter Pic v$_kBuildNum'),
          centerTitle: true,
          actions: [
            // 入口：高亮/屏蔽标签管理
            IconButton(
              icon: const Icon(Icons.local_offer_outlined),
              tooltip: '标签管理',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TagControllerScreen()),
              ),
            ),
            // 入口：设置
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: '设置',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => SettingsScreen(proxy: _proxy)),
              ),
            ),
            // 入口：重启 ECH 代理
            IconButton(
              icon: const Icon(Icons.restart_alt),
              tooltip: _startInFlight ? '正在初始化...' : '重启 ECH',
              onPressed: _startInFlight ? null : _restart,
            ),
            // 入口：调试日志
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
    if (_logs.isEmpty) return const Center(child: Text('(no logs)'));
    return ListView.builder(
      itemCount: _logs.length,
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(_logs[i], style: const TextStyle(fontSize: 11)),
      ),
    );
  }

  Widget _buildBody() {
    if (_proxyError != null) {
      return Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 8),
              SelectableText('$_proxyError',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red, fontSize: 13)),
              if (_logs.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text('--- Go 日志 ---',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                ...(_logs.map((l) => Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(l, style: const TextStyle(fontSize: 10)),
                    ))),
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _startInFlight
                    ? null
                    : () {
                        setState(() {
                          _proxyError = null;
                          _proxyReady = false;
                        });
                        _start();
                      },
                child: const Text('重试'),
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
            Text('正在初始化 ECH ...'),
          ],
        ),
      );
    }
    return UserListScreen(proxy: _proxy);
  }

  @override
  void dispose() {
    _proxy.dispose();
    super.dispose();
  }
}
