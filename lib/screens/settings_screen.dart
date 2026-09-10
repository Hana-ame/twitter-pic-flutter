// settings_screen.dart
// 设置页面：查看代理状态、网络诊断、清除缓存、关于信息

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../api/twitter_api.dart';
import '../services/proxy_manager.dart';
import '../services/storage_service.dart';
import '../utils/doh_resolver.dart';

class SettingsScreen extends StatefulWidget {
  final ProxyManager proxy;
  final String buildNum;

  /// 作为主界面 Tab 内嵌时由外层提供 Scaffold/AppBar，避免双层工具栏
  /// （外层 "Twitter Pic" + 内层 "设置" 叠在一起）。
  final bool embedded;

  const SettingsScreen({
    super.key,
    required this.proxy,
    this.buildNum = 'dev',
    this.embedded = false,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _restarting = false;

  // ─── 网络诊断 ─────────────────────────────────────────────────────────────
  bool _diagRunning = false;
  final List<_DiagItem> _diag = [];

  /// 发起一次 HTTP 探测，返回简短结果文本。
  Future<String> _httpProbe(String url, {int timeoutSec = 8}) async {
    final client = HttpClient()
      ..connectionTimeout = Duration(seconds: timeoutSec);
    client.badCertificateCallback = (cert, host, port) => true;
    final sw = Stopwatch()..start();
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(Duration(seconds: timeoutSec));
      final res = await req.close().timeout(Duration(seconds: timeoutSec));
      final len = res.contentLength;
      // 只读少量 body 确认通道，不整包下载。
      await res.drain<void>().timeout(Duration(seconds: timeoutSec));
      return 'HTTP ${res.statusCode} · ${sw.elapsedMilliseconds}ms · ${len >= 0 ? len : '?'}B';
    } catch (e) {
      return '失败: $e';
    } finally {
      client.close(force: true);
    }
  }

  /// 抓取 `<username>.json.gz` 并解析为原始 Map（不解码成模型）。
  /// 用于诊断 JSON 结构与模型是否匹配（timeline 字段名、类型等）。
  Future<Map<String, dynamic>?> _fetchRawJson(String username) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    client.badCertificateCallback = (cert, host, port) => true;
    try {
      final date = DateTime.now().toIso8601String().split('T')[0];
      final url =
          'https://x.moonchan.xyz/api/twitter/$username.json.gz?t=$date';
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final res = await req.close();
      if (res.statusCode != 200) {
        return <String, dynamic>{'__http_error__': 'HTTP ${res.statusCode}'};
      }
      final bytes = await res.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      // 可能是 gzip 压缩：先尝试 utf8，失败再解压。
      var text = '';
      try {
        text = utf8.decode(bytes);
      } catch (_) {
        text = utf8.decode(gzip.decode(bytes));
      }
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e) {
      return <String, dynamic>{'__http_error__': '$e'};
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _runDiag() async {
    if (_diagRunning) return;
    setState(() {
      _diagRunning = true;
      _diag.clear();
    });

    Future<void> step(String label, Future<String> Function() fn) async {
      if (!mounted) return;
      setState(() => _diag.add(_DiagItem(label: label, running: true)));
      String result;
      try {
        result = await fn();
      } catch (e) {
        result = '失败: $e';
      }
      if (!mounted) return;
      setState(() {
        final i = _diag.indexWhere((d) => d.label == label);
        if (i >= 0) {
          _diag[i] = _DiagItem(
            label: label,
            result: result,
            ok: !result.startsWith('失败'),
          );
        }
      });
    }

    // 1. API 直连：拉用户列表，检查数量
    await step('1. API 直连 (x.moonchan.xyz)', () async {
      final api = TwitterApi();
      try {
        final users = await api.getUserList();
        return 'HTTP 200 · ${users.length} 个用户';
      } finally {
        api.dispose();
      }
    });

    // 2. 第一个用户的原始 JSON：顶层 keys + timeline 结构 + 头像字段
    await step('2. 用户 JSON 结构 (.json.gz)', () async {
      final api = TwitterApi();
      try {
        final users = await api.getUserList();
        if (users.isEmpty) return '失败: 用户列表为空';
        final u = users.first;
        final raw = await _fetchRawJson(u.username);
        if (raw == null) return '失败: 无法获取 ${u.username}.json.gz';
        final topKeys = raw.keys.map((k) => "'$k'").join(', ');
        final tl = raw['timeline'];
        final tlLen = tl is List ? tl.length : -1;
        var tlInfo = 'timeline: $tlLen 条';
        if (tl is List && tl.isNotEmpty) {
          final first = tl.first;
          if (first is Map) {
            final keys = first.keys.map((k) => "'$k'").join(', ');
            tlInfo += '\ntimeline[0] 字段: $keys';
            final sample = first.values.take(2).map((v) => v.toString().length > 60 ? '${v.toString().substring(0, 60)}…' : v.toString()).join(' | ');
            tlInfo += '\ntimeline[0] 样例: $sample';
          }
        }
        final info = raw['account_info'];
        final avatar = info is Map ? info['profile_image'] : '(无 account_info)';
        return '顶层字段: $topKeys\n$tlInfo\n头像: $avatar';
      } finally {
        api.dispose();
      }
    });

    // 3. pbs.moonchan.xyz 镜像通道（头像）
    await step('3. pbs.moonchan.xyz (头像镜像)', () {
      return _httpProbe('https://pbs.moonchan.xyz/media/x.jpg');
    });

    // 4. video-cf 经本机 ECH 代理
    await step('4. video-cf 经 ECH 代理', () async {
      final port = widget.proxy.port;
      if (port == null) return '失败: 代理未启动 (port=null)';
      return _httpProbe('http://127.0.0.1:$port/favicon.ico');
    });

    // 5. video-cf 直连（预期失败：被墙，需 ECH）
    await step('5. video-cf 直连 (预期失败)', () {
      return _httpProbe('https://video-cf.twimg.com/favicon.ico');
    });

    if (mounted) setState(() => _diagRunning = false);
  }

  Future<void> _clearData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除数据'),
        content: const Text('将清除所有收藏、屏蔽列表、标签规则、搜索历史。\n\n此操作不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清除')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await StorageService.clearAll();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('数据已清除')));
    }
  }

  Future<void> _restart() async {
    if (_restarting) return;
    setState(() => _restarting = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('正在重启 ECH ...'), duration: Duration.zero),
    );
    try {
      widget.proxy.stop();
      final ip = await resolveDomainRobustly(kDohHost);
      await widget.proxy.start(bootstrapIp: ip);
      if (mounted) {
        setState(() => _restarting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('代理已重启')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _restarting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('重启失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final proxy = widget.proxy;
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const SizedBox(height: 8),

          // ─── 代理状态 ───────────────────────────────────────────────────────
          _SectionTitle(title: '代理状态', icon: Icons.router, color: Colors.blue),
          _StatusCard(
            icon: Icons.circle,
            label: '状态',
            value: proxy.isRunning ? '运行中' : '已停止',
            color: proxy.isRunning ? Colors.green : Colors.red,
          ),
          _StatusCard(
            icon: Icons.numbers,
            label: '端口',
            value: proxy.port?.toString() ?? '-',
          ),
          _StatusCard(
            icon: Icons.check_circle,
            label: '初始化',
            value: proxy.isInitialized ? '已完成' : '未初始化',
            color: proxy.isInitialized ? Colors.green : Colors.grey,
          ),
          const SizedBox(height: 8),

          // ─── 操作 ───────────────────────────────────────────────────────────
          _SectionTitle(title: '操作', icon: Icons.settings, color: Colors.orange),
          ListTile(
            leading: const Icon(Icons.restart_alt, color: Colors.blue),
            title: const Text('重启代理'),
            subtitle: const Text('重新初始化 ECH 代理'),
            trailing: _restarting
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _restarting ? null : _restart,
          ),
          ListTile(
            leading: const Icon(Icons.bug_report, color: Colors.orange),
            title: const Text('查看日志'),
            subtitle: const Text('显示 Go 侧调试日志'),
            onTap: () => _showLogs(context),
          ),
          ListTile(
            leading: const Icon(Icons.delete_sweep, color: Colors.red),
            title: const Text('清除数据'),
            subtitle: const Text('清除收藏、屏蔽、标签、搜索历史'),
            onTap: _clearData,
          ),
          const Divider(),

          // ─── 网络诊断 ───────────────────────────────────────────────────────
          _SectionTitle(title: '网络诊断', icon: Icons.science, color: Colors.teal),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: FilledButton.tonalIcon(
              onPressed: _diagRunning ? null : _runDiag,
              icon: _diagRunning
                  ? const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow, size: 16),
              label: Text(_diagRunning ? '测试中...' : '运行全部通道测试'),
            ),
          ),
          const SizedBox(height: 4),
          ..._diag.map((d) => _DiagTile(item: d)),
          const SizedBox(height: 8),
          const Divider(),

          // ─── 关于 ───────────────────────────────────────────────────────────
          _SectionTitle(title: '关于', icon: Icons.info_outline, color: Colors.blueGrey),
          _StatusCard(icon: Icons.info_outline, label: '版本', value: widget.buildNum),
          const SizedBox(height: 8),

          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Twitter Pic - ECH 代理图片浏览器\n\n'
              '通过本机 ECH 代理访问 Twitter 媒体资源。\n'
              '所有代理通信均使用端到端加密。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  void _showLogs(BuildContext context) {
    final logs = widget.proxy.getLogs();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('调试日志'),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: logs.isEmpty
              ? const Center(child: Text('暂无日志'))
              : ListView.builder(
                  itemCount: logs.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(logs[i], style: const TextStyle(fontSize: 10, fontFamily: 'monospace')),
                  ),
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color color;

  const _SectionTitle({required this.title, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? color;

  const _StatusCard({
    required this.label,
    required this.value,
    required this.icon,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 18, color: color ?? Colors.grey[600]),
      title: Text(label, style: const TextStyle(fontSize: 14)),
      trailing: Text(
        value,
        style: TextStyle(
          fontSize: 14,
          color: color ?? Colors.grey[600],
          fontWeight: color != null ? FontWeight.bold : null,
        ),
      ),
    );
  }
}

/// 单条诊断结果。
class _DiagItem {
  final String label;
  final String result;
  final bool ok;
  final bool running;

  _DiagItem({
    required this.label,
    this.result = '',
    this.ok = false,
    this.running = false,
  });
}

class _DiagTile extends StatelessWidget {
  final _DiagItem item;

  const _DiagTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final IconData icon;
    if (item.running) {
      color = Colors.blueGrey;
      icon = Icons.hourglass_top;
    } else if (item.ok) {
      color = Colors.green;
      icon = Icons.check_circle;
    } else {
      color = Colors.red;
      icon = Icons.error;
    }

    return ListTile(
      dense: true,
      leading: Icon(icon, size: 16, color: color),
      title: Text(
        item.label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
      subtitle: item.result.isEmpty
          ? null
          : Text(item.result, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
      trailing: item.running
          ? const SizedBox(
              width: 12, height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
    );
  }
}
