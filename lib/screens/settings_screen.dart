// settings_screen.dart
// 设置页面：查看代理状态、网络诊断、清除缓存、关于信息

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/twitter_api.dart';
import '../services/proxy_manager.dart';
import '../services/storage_service.dart';
import '../utils/doh_resolver.dart';
import '../utils/ech_url.dart';

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
  ///
  /// body 只读前 [maxReadBytes]（足够判断通道通不通）：原先用 `drain()`
  /// 会把整张图下完，媒体经 ECH 拉全图轻松超过默认超时，于是“探测超时”
  /// 其实是探针自己造成的。读够即 break，剩余字节由 `close(force: true)`
  /// 丢弃。超时同时计入首包与后续静默（Stream.timeout）。
  Future<String> _httpProbe(String url,
      {int timeoutSec = 20, int maxReadBytes = 64 * 1024}) async {
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
      // 带上耗时：区分“秒断（连不上）”与“撑到超时（链路慢/上游挂）”
      return '失败: ${sw.elapsedMilliseconds}ms · $e';
    } finally {
      client.close(force: true);
    }
  }

  /// Range 分段探测。ExoPlayer（video_player 底层）播 MP4 一定要分段拉取：
  /// 上游必须回 206 + Content-Range，否则拿不到文件尾部的 moov，视频永不开播。
  Future<String> _rangeProbe(String url, {int timeoutSec = 20}) async {
    final client = HttpClient()..connectionTimeout = Duration(seconds: timeoutSec);
    client.badCertificateCallback = (cert, host, port) => true;
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
      // 只认 206：回 200 说明 Range 被吞了，播放器拿不到尾部元数据。
      return res.statusCode == 206 ? detail : '失败: Range 未被支持 → $detail';
    } catch (e) {
      return '失败: ${sw.elapsedMilliseconds}ms · $e';
    } finally {
      client.close(force: true);
    }
  }

  /// 用 widget 真正使用的那套栈（NetworkImage → 图片缓存 → 解码）验证一张图，
  /// 而不是 raw HttpClient。两者失败原因可能完全不同（例如解码失败、
  /// 缺 Content-Length 导致 codec 报错等）。
  Future<String> _imageDecodeProbe(String url, {int timeoutSec = 30}) async {
    final sw = Stopwatch()..start();
    final completer = Completer<String>();
    final stream = NetworkImage(url).resolve(ImageConfiguration.empty);
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

  /// 抓取 `<username>.json.gz`，返回响应头、编码方式与原始 JSON。
  /// 不解析成模型，供诊断编码与字段结构。
  ///
  /// 这里必须整包下载（要解析 JSON 校验字段），因此逐级显式设超时：
  /// 大账号的 json.gz 若无超时会把整个诊断永久卡在步骤 2。
  Future<_RawJsonResult> _fetchRawJson(String username) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    client.badCertificateCallback = (cert, host, port) => true;
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
      // 编码检测：先按 utf8 解，失败则按 gzip+utf8 解，记录实际编码。
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

  /// 检查 JSON 字段是否匹配模型（TimelineItem/TwitterUser 的期望 key）。
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

  /// 判定一次诊断结果是否“通过”。
  ///
  /// 之前只看是否以“失败”开头，导致 HTTP 404/502 也标成绿色✓——恰恰是
  /// 最需要被看见的错误。现在按 HTTP 状态码与字段检查符号判定。
  static bool _passed(String result) {
    if (result.startsWith('失败')) return false;
    final m = RegExp(r'HTTP (\d{3})').firstMatch(result);
    if (m != null) {
      final code = int.parse(m.group(1)!);
      return code >= 200 && code < 400;
    }
    // 无状态码的纯文本结果（字段/编码检查）：出现 ✗ 判为不通过。
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

    // 取样一次供 2/6/7/8/9 复用：原先每个测试各自下一遍 100KB+ 的 json.gz，
    // 一整轮诊断光下载就要十几秒。
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

    // 1. API 直连（TwitterApi 实际使用的通道：JSON/API 不经代理）
    await step('1. API 直连 (TwitterApi 实际通道)', () async {
      final api = TwitterApi();
      try {
        final users = await api.getUserList();
        return '$kApiBase → ${users.length} 个用户';
      } finally {
        api.dispose();
      }
    });

    // 2. 原始 JSON：编码检测 + 字段与模型匹配检查
    await step('2. 用户 JSON 编码与字段检查', () async {
      await ensureSample();
      final s = sample;
      if (s == null) return '失败: 用户列表为空';
      return _checkJsonFields(s);
    });

    // 2b. getMetaData 经 Dio + fromJson 解析 —— App 显示头像/媒体走的就是这条
    // 路。测试 2 是 raw 抓取，绕过了 Dio 与模型层，两者结论可能完全不同：
    // raw 有 644 条而这里为 0，就说明问题在解析层而不是网络。
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
        // 把 Dio 真正请求的 URL 打出来：历史上 403 的根因就是 baseUrl 与 path
        // 拼接少了斜杠（.../api/twitterx.json.gz），只看 "HTTP 403" 根本看不出来。
        return '失败: ${e.error ?? e.message}\n'
            '实际请求: ${e.requestOptions.uri}\n'
            'API base: $kApiBase';
      } catch (e) {
        return '失败: $e';
      } finally {
        api.dispose();
      }
    });

    // 3. API 原始探测（不经 Dio，用 dart:io 直接 GET，区分 Dio/网络层问题）
    await step('3. API 原始探测 (不经 Dio)', () {
      return _httpProbe('$kApiBase/?list=users');
    });

    // 4. video-cf 经本机 ECH 代理
    await step('4. video-cf 经 ECH 代理', () async {
      final port = widget.proxy.port;
      if (port == null) return '失败: 代理未启动 (port=null)';
      return _httpProbe('http://127.0.0.1:$port/favicon.ico');
    });

    // 5. video-cf 直连（预期失败：被墙，需 ECH）
    await step('5. video-cf 直连 (预期失败)', () {
      return _httpProbe('https://video-cf.twimg.com/favicon.ico', timeoutSec: 10);
    }, expectFail: true);

    // 6. 真实头像 URL → 代理 → raw HttpClient（证明“链路通不通”）
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

    // 7. 真实头像 → NetworkImage 解码（ProxyAvatar 用的就是这套栈）。
    // 与测试 6 的区别：这里过 Flutter 的图片缓存与解码。若 6 通过而 7 失败，
    // 说明问题在 widget 层（解码/尺寸/缓存），而不是网络。
    await step('7. 真实头像 widget 栈解码 (NetworkImage)', () async {
      final port = widget.proxy.port;
      if (port == null) return '失败: 代理未启动 (port=null)';
      await ensureSample();
      final avatar = avatarUrl;
      if (avatar == null || avatar.isEmpty) return '失败: 无头像 URL';
      final r = await _imageDecodeProbe(EchUrl.rewrite(avatar, port));
      return '${EchUrl.rewrite(avatar, port)}\n→ $r';
    });

    // 8. 真实图片（pbs.twimg.com/media，带 format/name）→ widget 栈解码
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

    // 9. 真实视频 → Range 分段探测（ExoPlayer 必需，只认 206）
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

    // 10. 代理转发记录：上面 4/6/7/8/9 都往代理日志里写了记录，这里直接读
    // 出来，确认媒体请求确实经本机 ECH 代理转发到 video-cf.twimg.com
    // （而不是直连某个域名或在本地就被拒了）。
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

  /// 复制诊断报告（含版本与代理上下文），便于直接粘贴反馈。
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

/// 原始 JSON 抓取结果：响应头 + 解码方式 + 解析后的 JSON。
class _RawJsonResult {
  final int statusCode;
  final Map<String, String> headers;
  final String? decodeMethod; // 'utf8' 或 'gzip+utf8'
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
