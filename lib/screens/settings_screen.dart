// settings_screen.dart
// 设置页面：查看代理状态、清除缓存、关于信息

import 'package:flutter/material.dart';

import '../services/proxy_manager.dart';

class SettingsScreen extends StatelessWidget {
  final ProxyManager proxy;

  const SettingsScreen({super.key, required this.proxy});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const SizedBox(height: 8),

          // ─── 代理状态 ───────────────────────────────────────────────────────
          const _SectionTitle('代理状态'),
          _StatusCard(
            label: '状态',
            value: proxy.isRunning ? '运行中' : '已停止',
            color: proxy.isRunning ? Colors.green : Colors.red,
          ),
          _StatusCard(
            label: '端口',
            value: proxy.port?.toString() ?? '-',
          ),
          _StatusCard(
            label: '初始化',
            value: proxy.isInitialized ? '已完成' : '未初始化',
            color: proxy.isInitialized ? Colors.green : Colors.grey,
          ),
          const SizedBox(height: 8),

          // ─── 操作 ───────────────────────────────────────────────────────────
          const _SectionTitle('操作'),
          ListTile(
            leading: const Icon(Icons.restart_alt, color: Colors.blue),
            title: const Text('重启代理'),
            subtitle: const Text('重新初始化 ECH 代理'),
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('正在重启 ECH ...'), duration: Duration.zero),
              );
              proxy.stop();
              proxy.start(bootstrapIp: '127.0.0.1');
            },
          ),
          ListTile(
            leading: const Icon(Icons.bug_report, color: Colors.orange),
            title: const Text('查看日志'),
            subtitle: const Text('显示 Go 侧调试日志'),
            onTap: () => _showLogs(context),
          ),
          const Divider(),

          // ─── 关于 ───────────────────────────────────────────────────────────
          const _SectionTitle('关于'),
          _StatusCard(label: '版本', value: 'v1.0.0'),
          _StatusCard(label: '构建', value: DateTime.now().toString()),
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
    final logs = proxy.getLogs();
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
  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Text(
        title,
        style: const TextStyle(fontSize: 12, color: Colors.blue, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _StatusCard({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
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
