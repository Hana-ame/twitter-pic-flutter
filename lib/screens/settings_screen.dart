// settings_screen.dart
// 设置页面：查看代理状态、外观主题切换、已屏蔽账号与浏览历史管理、网络诊断、清除缓存、关于信息

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/twitter_api.dart';
import '../services/log_service.dart';
import '../services/poster_service.dart';
import '../services/proxy_manager.dart';
import '../services/storage_service.dart';
import '../utils/doh_resolver.dart';
import '../utils/ech_url.dart';
import '../widgets/progressive_image.dart';
import '../widgets/report_help.dart';
import 'browse_history_screen.dart';

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
  bool _gayMode = false;
  String _themeMode = 'light';
  /// 上一次 didChangeDependencies 看到的 ModalRoute，用于判断路由是否换了。
  ModalRoute<dynamic>? _lastRoute;

  @override
  void initState() {
    super.initState();
    _gayMode = StorageService.isGayMode();
    _themeMode = StorageService.getThemeMode();
    StorageService.changes.addListener(_syncFromStorage);
  }

  @override
  void dispose() {
    StorageService.changes.removeListener(_syncFromStorage);
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == _lastRoute) return;
    _lastRoute = route;
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncFromStorage());
  }

  void _syncFromStorage() {
    if (!mounted) return;
    final actualGay = StorageService.isGayMode();
    final actualTheme = StorageService.getThemeMode();
    if (actualGay != _gayMode || actualTheme != _themeMode) {
      setState(() {
        _gayMode = actualGay;
        _themeMode = actualTheme;
      });
    } else {
      // 屏蔽列表或浏览历史数量变化也同步刷新副标题
      setState(() {});
    }
  }

  String _themeModeLabel(String mode) {
    switch (mode) {
      case 'dark':
        return '深色模式';
      case 'system':
        return '跟随系统';
      default:
        return '浅色模式';
    }
  }

  void _showThemePicker() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('外观主题'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<String>(
              title: const Text('浅色模式'),
              value: 'light',
              groupValue: _themeMode,
              onChanged: (v) {
                if (v != null) StorageService.setThemeMode(v);
                Navigator.pop(ctx);
              },
            ),
            RadioListTile<String>(
              title: const Text('深色模式'),
              value: 'dark',
              groupValue: _themeMode,
              onChanged: (v) {
                if (v != null) StorageService.setThemeMode(v);
                Navigator.pop(ctx);
              },
            ),
            RadioListTile<String>(
              title: const Text('跟随系统'),
              value: 'system',
              groupValue: _themeMode,
              onChanged: (v) {
                if (v != null) StorageService.setThemeMode(v);
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showBlockedUsersDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final blocked = StorageService.getBlockedUsers();
          return AlertDialog(
            title: Text('已屏蔽账号 (${blocked.length})'),
            content: SizedBox(
              width: 320,
              height: 300,
              child: blocked.isEmpty
                  ? const Center(
                      child: Text('暂无已屏蔽账号',
                          style: TextStyle(color: Colors.grey)),
                    )
                  : ListView.builder(
                      itemCount: blocked.length,
                      itemBuilder: (_, i) {
                        final u = blocked[i];
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text('@$u', style: const TextStyle(fontSize: 13)),
                          trailing: TextButton(
                            onPressed: () {
                              StorageService.removeBlockedUser(u);
                              setDialogState(() {});
                            },
                            child: const Text('取消屏蔽', style: TextStyle(fontSize: 12)),
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              if (blocked.isNotEmpty)
                TextButton(
                  onPressed: () {
                    StorageService.clearBlockedUsers();
                    setDialogState(() {});
                  },
                  child: const Text('全部解除', style: TextStyle(color: Colors.red)),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ─── 网络诊断 ─────────────────────────────────────────────────────────────
  bool _diagRunning = false;
  final List<_DiagItem> _diag = [];

  Future<String> _httpProbe(String url,
      {int timeoutSec = 20, int maxReadBytes = 64 * 1024}) async {
    final client = HttpClient()
      ..connectionTimeout = Duration(seconds: timeoutSec);
    final sw = Stopwatch()..start();
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(Duration(seconds: timeoutSec));
      final res = await req.close().timeout(Duration(seconds: timeoutSec));
      final len = res.contentLength;
      var got = 0;
      await for (final chunk
          in res.timeout(Duration(seconds: timeoutSec), onTimeout: (s) {
        s.addError(TimeoutException('body 读取超时', Duration(seconds: timeoutSec)));
      })) {
        got += chunk.length;
        if (got >= maxReadBytes) break;
      }
      return 'HTTP ${res.statusCode} · ${sw.elapsedMilliseconds}ms · ${len >= 0 ? len : '?'}B (读 ${got}B)';
    } catch (e) {
      return '失败: ${sw.elapsedMilliseconds}ms · $e';
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _rangeProbe(String url, {int timeoutSec = 20}) async {
    final client = HttpClient()..connectionTimeout = Duration(seconds: timeoutSec);
    final sw = Stopwatch()..start();
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(Duration(seconds: timeoutSec));
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1023');
      final res = await req.close().timeout(Duration(seconds: timeoutSec));
      final cr = res.headers.value(HttpHeaders.contentRangeHeader) ?? '-';
      final ar = res.headers.value('accept-ranges') ?? '-';
      final cl = res.headers.value(HttpHeaders.contentLengthHeader) ?? '-';
      var got = 0;
      await for (final chunk in res) {
        got += chunk.length;
        if (got > 8 * 1024) break;
      }
      final detail =
          'HTTP ${res.statusCode} · Content-Range: $cr · Accept-Ranges: $ar · Content-Length: $cl · 收到 ${got}B · ${sw.elapsedMilliseconds}ms';
      return res.statusCode == 206 ? detail : '失败: Range 未被支持 → $detail';
    } catch (e) {
      return '失败: ${sw.elapsedMilliseconds}ms · $e';
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _imageDecodeProbe(String url, {int timeoutSec = 30}) async {
    final sw = Stopwatch()..start();
    final completer = Completer<String>();
    final stream =
        ProgressiveImageProvider(url).resolve(ImageConfiguration.empty);
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        completer.complete(
            '解码成功 ${info.image.width}x${info.image.height} · ${sw.elapsedMilliseconds}ms');
      },
      onError: (e, _) {
        stream.removeListener(listener);
        completer.complete('失败: ${sw.elapsedMilliseconds}ms · $e');
      },
    );
    stream.addListener(listener);
    return completer.future.timeout(
      Duration(seconds: timeoutSec),
      onTimeout: () => '失败: ${timeoutSec}s 超时（连上但没出图）',
    );
  }

  Future<_RawJsonResult> _fetchRawJson(String username) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final date = DateTime.now().toIso8601String().split('T')[0];
      final url = '$kApiBase/$username.json.gz?t=$date';
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final res = await req.close().timeout(const Duration(seconds: 20));
      final headers = <String, String>{
        'content-type': res.headers.value('content-type') ?? '?',
        'content-encoding': res.headers.value('content-encoding') ?? '无',
        'content-length': res.headers.value('content-length') ?? '?',
      };
      if (res.statusCode != 200) {
        return _RawJsonResult(
          statusCode: res.statusCode,
          headers: headers,
          error: 'HTTP ${res.statusCode}',
        );
      }
      final bytes = await res
          .timeout(const Duration(seconds: 45), onTimeout: (s) {
            s.addError(TimeoutException(
                'body 读取超时', const Duration(seconds: 45)));
          })
          .fold<List<int>>(
            <int>[],
            (acc, chunk) => acc..addAll(chunk),
          );
      var text = '';
      var method = 'utf8';
      try {
        text = utf8.decode(bytes);
      } catch (_) {
        text = utf8.decode(gzip.decode(bytes));
        method = 'gzip+utf8';
      }
      final decoded = jsonDecode(text);
      return _RawJsonResult(
        statusCode: res.statusCode,
        headers: headers,
        decodeMethod: method,
        bytes: bytes.length,
        json: decoded is Map<String, dynamic> ? decoded : null,
      );
    } catch (e) {
      return _RawJsonResult(statusCode: 0, headers: const {}, error: '$e');
    } finally {
      client.close(force: true);
    }
  }

  String _checkJsonFields(_RawJsonResult res) {
    final buf = StringBuffer();
    buf.writeln('HTTP ${res.statusCode}');
    buf.writeln('content-type: ${res.headers['content-type']}');
    buf.writeln('content-encoding: ${res.headers['content-encoding']}');
    if (res.error != null) {
      buf.writeln('错误: ${res.error}');
      return buf.toString();
    }
    buf.writeln('解码: ${res.decodeMethod} · ${res.bytes}B');
    final json = res.json;
    if (json == null) {
      buf.writeln('JSON 非对象');
      return buf.toString();
    }

    final tl = json['timeline'];
    buf.writeln('顶层字段: ${json.keys.join(', ')}');
    buf.writeln('timeline: ${tl is List ? '${tl.length} 条' : '非数组!'}');
    if (tl is List && tl.isNotEmpty && tl.first is Map) {
      const need = ['url', 'type', 'date'];
      final first = tl.first as Map;
      for (final k in need) {
        buf.writeln("timeline[0].'$k' ${first.containsKey(k) ? '✓' : '✗ 缺失'}");
      }
      final sample = first.entries.take(3).map((e) {
        final v = e.value.toString();
        return "'${e.key}': ${v.length > 50 ? '${v.substring(0, 50)}…' : v}";
      }).join(' | ');
      buf.writeln('样例: $sample');
    }

    final info = json['account_info'];
    if (info is Map) {
      const need = ['name', 'nick', 'profile_image'];
      for (final k in need) {
        buf.writeln("account_info.'$k' ${info.containsKey(k) ? '✓' : '✗ 缺失'}");
      }
      buf.writeln('头像: ${info['profile_image']}');
    } else {
      buf.writeln('account_info: 缺失或非对象');
    }
    return buf.toString();
  }

  static bool _passed(String result) {
    if (result.startsWith('失败') || result.contains('（跳过）')) return false;
    final m = RegExp(r'HTTP (\d{3})').firstMatch(result);
    if (m != null) {
      final code = int.parse(m.group(1)!);
      return code >= 200 && code < 400;
    }
    return !result.contains('✗');
  }

  Future<void> _runDiag() async {
    if (_diagRunning) return;
    setState(() {
      _diagRunning = true;
      _diag.clear();
    });

    Future<void> step(String label, Future<String> Function() fn,
        {bool expectFail = false}) async {
      if (!mounted) return;
      setState(() => _diag.add(_DiagItem(label: label, running: true)));
      String result;
      try {
        result = await fn();
      } catch (e) {
        result = '失败: $e';
      }
      if (!mounted) return;
      final pass = _passed(result);
      setState(() {
        final i = _diag.indexWhere((d) => d.label == label);
        if (i >= 0) {
          _diag[i] = _DiagItem(
            label: label,
            result: result,
            ok: expectFail ? !pass : pass,
          );
        }
      });
    }

    _RawJsonResult? sample;
    String? avatarUrl, photoUrl, videoUrl;
    Future<void> ensureSample() async {
      if (sample != null) return;
      final api = TwitterApi();
      try {
        final users = await api.getUserList();
        if (users.isEmpty) return;
        final raw = await _fetchRawJson(users.first.username);
        sample = raw;
        if (raw.error != null) return;
        avatarUrl = raw.json?['account_info']?['profile_image']?.toString();
        final tl = raw.json?['timeline'];
        if (tl is List) {
          for (final e in tl) {
            if (e is! Map) continue;
            final u = e['url']?.toString() ?? '';
            final t = e['type']?.toString() ?? '';
            if (photoUrl == null && u.contains('pbs.twimg.com')) photoUrl = u;
            if (videoUrl == null &&
                (u.contains('video.twimg.com') ||
                    t == 'video' ||
                    t == 'animated_gif')) {
              videoUrl = u;
            }
            if (photoUrl != null && videoUrl != null) break;
          }
        }
      } finally {
        api.dispose();
      }
    }

    await step('1. API 直连 (TwitterApi 实际通道)', () async {
      final api = TwitterApi();
      try {
        final users = await api.getUserList();
        return '$kApiBase → ${users.length} 个用户';
      } finally {
        api.dispose();
      }
    });

    await step('2. 用户 JSON 编码与字段检查', () async {
      await ensureSample();
      final s = sample;
      if (s == null) return '失败: 用户列表为空';
      return _checkJsonFields(s);
    });

    await step('2b. getMetaData 经 Dio+模型解析', () async {
      final api = TwitterApi();
      try {
        final users = await api.getUserList();
        if (users.isEmpty) return '失败: 用户列表为空';
        final meta =
            await api.getMetaData(users.first.username, forceRefresh: true);
        final av = meta.accountInfo.avatar;
        final line = 'timeline ${meta.timeline.length} 条 · '
            '头像: ${av ?? '-'} · total_urls: ${meta.totalUrls} · '
            'type[0]: ${meta.timeline.isNotEmpty ? meta.timeline.first.type : '-'}';
        final problems = <String>[];
        if (meta.timeline.isEmpty) problems.add('timeline 解析后为空');
        if (av == null || av.isEmpty) problems.add('头像为空');
        return problems.isEmpty ? line : '失败: ${problems.join('、')} → $line';
      } on DioException catch (e) {
        return '失败: ${e.error ?? e.message}\n'
            '实际请求: ${e.requestOptions.uri}\n'
            'API base: $kApiBase';
      } catch (e) {
        return '失败: $e';
      } finally {
        api.dispose();
      }
    });

    await step('3. API 原始探测 (不经 Dio)', () {
      return _httpProbe('$kApiBase/?list=users');
    });

    await step('4. video-cf 经 ECH 代理', () async {
      final port = widget.proxy.port;
      if (port == null) return '失败: 代理未启动 (port=null)';
      return _httpProbe('http://127.0.0.1:$port/favicon.ico');
    });

    await step('5. video-cf 直连 (预期失败)', () {
      return _httpProbe('https://video-cf.twimg.com/favicon.ico', timeoutSec: 10);
    }, expectFail: true);

    await step('6. 真实头像经代理 (raw HttpClient)', () async {
      final port = widget.proxy.port;
      if (port == null) return '失败: 代理未启动 (port=null)';
      await ensureSample();
      final avatar = avatarUrl;
      if (avatar == null || avatar.isEmpty) return '失败: 无头像 URL';
      final replaced = EchUrl.rewrite(avatar, port);
      final probe = await _httpProbe(replaced, timeoutSec: 30);
      return '原始: $avatar\n代理: $replaced\n→ $probe';
    });

    await step('7. 真实头像 widget 栈解码 (ProgressiveImageProvider)', () async {
      final port = widget.proxy.port;
      if (port == null) return '失败: 代理未启动 (port=null)';
      await ensureSample();
      final avatar = avatarUrl;
      if (avatar == null || avatar.isEmpty) return '失败: 无头像 URL';
      final r = await _imageDecodeProbe(EchUrl.rewrite(avatar, port));
      return '${EchUrl.rewrite(avatar, port)}\n→ $r';
    });

    await step('8. 真实图片 widget 栈解码', () async {
      final port = widget.proxy.port;
      if (port == null) return '失败: 代理未启动 (port=null)';
      await ensureSample();
      final photo = photoUrl;
      if (photo == null || photo.isEmpty) return '无 pbs 图片条目（跳过）';
      final rewritten = EchUrl.rewrite(photo, port);
      final r = await _imageDecodeProbe(rewritten);
      return '原始: $photo\n代理: $rewritten\n→ $r';
    });

    await step('9. 真实视频 Range 分段探测', () async {
      final port = widget.proxy.port;
      if (port == null) return '失败: 代理未启动 (port=null)';
      await ensureSample();
      final video = videoUrl;
      if (video == null || video.isEmpty) return '无视频条目（跳过）';
      final rewritten = EchUrl.rewrite(video, port);
      final r = await _rangeProbe(rewritten);
      return '原始: $video\n代理: $rewritten\n→ $r';
    });

    await step('10. ECH 代理转发记录 (video-cf)', () async {
      final port = widget.proxy.port;
      if (port == null) return '失败: 代理未启动 (port=null)';
      final lines = widget.proxy.getLogs();
      if (lines.isEmpty) return '失败: 代理日志为空';
      final media = lines.where((l) => l.contains('video-cf.twimg.com')).toList();
      int countOf(List<String> ls, String needle) =>
          ls.where((l) => l.contains(needle)).length;
      final done = media.where((l) => l.startsWith('← ')).toList();
      final okDone = done.where((l) => l.startsWith('← 200') || l.startsWith('← 206')).length;
      final shown = media.length > 6 ? media.sublist(media.length - 6) : media;
      return '代理日志 ${lines.length} 行\n'
          '转发 video-cf.twimg.com ${media.length} 条：'
          '图片 /media/ ${countOf(media, '/media/')} · '
          '头像 /profile_images/ ${countOf(media, '/profile_images/')} · '
          '视频 .mp4 ${countOf(media, '.mp4')}\n'
          '已完成 ${done.length} 条，其中 200/206 成功 $okDone 条\n'
          '最近 ${shown.length} 条：\n${shown.join('\n')}';
    });

    if (mounted) setState(() => _diagRunning = false);
  }

  Future<void> _copyDiag() async {
    if (_diag.isEmpty) return;
    final buf = StringBuffer();
    buf.writeln('Twitter Pic 诊断报告 · ${widget.buildNum}');
    buf.writeln(
        '代理: ${widget.proxy.isRunning ? '运行中' : '已停止'} · port=${widget.proxy.port ?? '-'} · init=${widget.proxy.isInitialized}');
    buf.writeln('API endpoint: $kApiBase (直连)');
    buf.writeln('');
    for (final d in _diag) {
      buf.writeln('【${d.label}】 ${d.running ? 'RUNNING' : (d.ok ? 'PASS' : 'FAIL')}');
      if (d.result.isNotEmpty) buf.writeln(d.result.trim());
      buf.writeln('');
    }
    await Clipboard.setData(ClipboardData(text: buf.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Row(
        children: [
          Icon(Icons.check_circle, size: 18, color: Colors.white),
          SizedBox(width: 8),
          Text('诊断结果已复制，可直接粘贴'),
        ],
      ),
    ));
  }

  Future<void> _clearData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除数据'),
        content: const Text('将清除所有收藏、屏蔽列表、标签规则、搜索历史、浏览历史，'
            '以及图片与视频封面缓存。\n\n此操作不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清除')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await StorageService.clearAll();
    await PosterService.clearAll();
    await ProgressiveDiskCache.clearAll();
    if (mounted) {
      setState(() {
        _gayMode = StorageService.isGayMode();
        _themeMode = StorageService.getThemeMode();
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('数据已清除')));
    }
  }

  Future<void> _clearLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除日志'),
        content: const Text('将清空磁盘日志文件（app.log）和内存中的日志记录。\n\n'
            '异常结束记录与崩溃检测标记会保留。\n\n'
            '此操作不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清除')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await LogService.clearLogs();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('日志已清除')));
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
    final blockedCount = StorageService.getBlockedUsers().length;
    final historyCount = StorageService.getBrowseHistory().length;
    return Scaffold(
      appBar: widget.embedded ? null : AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const SizedBox(height: 8),

          // ─── 代理状态 ───────────────────────────────────────────────────────
          const _SectionTitle(title: '代理状态', icon: Icons.router, color: Colors.blue),
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

          // ─── 操作与偏好 ─────────────────────────────────────────────────────
          const _SectionTitle(title: '操作与偏好', icon: Icons.settings, color: Colors.orange),
          ListTile(
            leading: const Icon(Icons.dark_mode_outlined, color: Colors.indigo),
            title: const Text('外观主题'),
            subtitle: Text(_themeModeLabel(_themeMode)),
            onTap: _showThemePicker,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.palette_outlined, color: Colors.purple),
            title: const Text('Gay 模式'),
            subtitle: Text(_gayMode ? '已开启（仅显示 Gay 专属标签内容）' : '已关闭（隐藏 Gay 专属标签内容）'),
            value: _gayMode,
            activeColor: Colors.purple,
            onChanged: (val) {
              setState(() {
                _gayMode = val;
                StorageService.setGayMode(val);
              });
            },
          ),
          ListTile(
            leading: const Icon(Icons.history, color: Colors.teal),
            title: const Text('浏览历史'),
            subtitle: Text('最近浏览过的账号（共 $historyCount 条）'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => BrowseHistoryScreen(proxy: widget.proxy),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.person_off_outlined, color: Colors.deepOrange),
            title: const Text('已屏蔽账号'),
            subtitle: Text(blockedCount == 0
                ? '当前没有已屏蔽的账号'
                : '已屏蔽 $blockedCount 个账号，点击查看或解除'),
            onTap: _showBlockedUsersDialog,
          ),
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
            subtitle: const Text('清除收藏、屏蔽、标签、搜索与浏览历史'),
            onTap: _clearData,
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.red),
            title: const Text('清除日志'),
            subtitle: const Text('清空 app.log 与内存日志，并复位「不再提示」开关'),
            onTap: _clearLogs,
          ),
          const Divider(),

          // ─── 网络诊断 ───────────────────────────────────────────────────────
          const _SectionTitle(title: '网络诊断', icon: Icons.science, color: Colors.teal),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Expanded(
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
                if (_diag.isNotEmpty && !_diagRunning) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _copyDiag,
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 4),
          ..._diag.map((d) => _DiagTile(item: d)),
          const SizedBox(height: 8),
          const Divider(),

          // ─── 日志与反馈 ─────────────────────────────────────────────────────
          const _SectionTitle(title: '日志与反馈', icon: Icons.bug_report, color: Colors.purple),
          ListTile(
            leading: const Icon(Icons.copy_all, color: Colors.purple),
            title: const Text('复制日志反馈包'),
            subtitle: const Text('日志 + 版本 + 代理状态，直接粘贴到群里'),
            onTap: _copyLogDump,
          ),
          ListTile(
            leading: const Icon(Icons.groups, color: Colors.purple),
            title: const Text('加群反馈'),
            subtitle: const Text('chatto 聊天群「推图」'),
            onTap: () => showGroupHelpDialog(context),
          ),
          if (LogService.incidents.isNotEmpty)
            ListTile(
              leading: const Icon(Icons.history, color: Colors.orange),
              title: const Text('异常结束记录'),
              subtitle: Text(
                LogService.incidents.first.describe,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: _showIncidents,
            ),
          const SizedBox(height: 8),
          const Divider(),

          // ─── 关于 ───────────────────────────────────────────────────────────
          const _SectionTitle(title: '关于', icon: Icons.info_outline, color: Colors.blueGrey),
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

  Future<void> _copyLogDump() async {
    await LogService.pollGoLogs(widget.proxy.getLogs());
    if (!mounted) return;
    await copyLogDump(context, extra: {
      '代理': widget.proxy.isRunning ? '运行中' : '已停止',
      '端口': '${widget.proxy.port ?? '-'}',
      'ECH 初始化': '${widget.proxy.isInitialized}',
      'API endpoint': '$kApiBase (直连)',
    });
  }

  void _showIncidents() {
    final items = LogService.incidents;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('异常结束记录'),
        content: SizedBox(
          width: 320,
          height: 300,
          child: items.isEmpty
              ? const Center(child: Text('暂无记录'))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      items[i].describe,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
        ),
        actions: [
          if (items.isNotEmpty)
            TextButton(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(ctx);
                await Clipboard.setData(ClipboardData(
                  text: items.map((e) => e.describe).join('\n'),
                ));
                messenger.showSnackBar(const SnackBar(content: Text('已复制')));
              },
              child: const Text('复制'),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  void _showLogs(BuildContext context) {
    unawaited(LogService.logTail(maxLines: 400).then((logs) {
      if (!mounted) return;
      _showLogsDialog(context, logs);
    }));
  }

  void _showLogsDialog(BuildContext context, List<String> logs) {
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
          if (logs.isNotEmpty)
            TextButton(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(ctx);
                await Clipboard.setData(ClipboardData(text: logs.join('\n')));
                messenger.showSnackBar(const SnackBar(content: Text('日志已复制')));
              },
              child: const Text('复制'),
            ),
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

class _RawJsonResult {
  final int statusCode;
  final Map<String, String> headers;
  final String? decodeMethod;
  final int bytes;
  final Map<String, dynamic>? json;
  final String? error;

  _RawJsonResult({
    required this.statusCode,
    required this.headers,
    this.decodeMethod,
    this.bytes = 0,
    this.json,
    this.error,
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
