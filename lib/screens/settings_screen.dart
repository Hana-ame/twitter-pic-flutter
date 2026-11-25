// settings_screen.dart
// 设置页面：查看代理状态、网络诊断、清除缓存、关于信息

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/twitter_api.dart';
import '../services/log_service.dart';
import '../services/network_diagnostics_service.dart';
import '../services/poster_service.dart';
import '../services/proxy_manager.dart';
import '../services/storage_service.dart';
import '../services/video_downloader.dart';
import '../utils/doh_resolver.dart';
import '../utils/ech_url.dart';
import '../video/video_compat_mode.dart';
import '../widgets/progressive_image.dart';
import '../widgets/report_help.dart';

class SettingsScreen extends StatefulWidget {
  final ProxyManager proxy;
  final TwitterApi? api;
  final String buildNum;

  /// 作为主界面 Tab 内嵌时由外层提供 Scaffold/AppBar，避免双层工具栏
  /// （外层 "Twitter Pic" + 内层 "设置" 叠在一起）。
  final bool embedded;

  const SettingsScreen({
    super.key,
    required this.proxy,
    this.api,
    this.buildNum = 'dev',
    this.embedded = false,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TwitterApi _api;
  late final bool _ownsApi;
  bool _restarting = false;
  bool _gayMode = false;
  VideoCompatMode _videoCompat = VideoCompatMode.standard;
  /// 上一次 didChangeDependencies 看到的 ModalRoute，用于判断路由是否换了。
  ModalRoute<dynamic>? _lastRoute;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? TwitterApi();
    _ownsApi = widget.api == null;
    _gayMode = StorageService.isGayMode();
    _videoCompat = StorageService.getVideoCompatMode();
    StorageService.changes.addListener(_syncStorage);
  }

  @override
  void dispose() {
    StorageService.changes.removeListener(_syncStorage);
    if (_ownsApi) _api.dispose();
    super.dispose();
  }

  /// 从别的页面改同一个开关后回到本页时，把 UI 拉回真实值。
  ///
  /// 「Gay 模式」有两处开关写**同一个** storage key：这里的 SwitchListTile，
  /// 以及标签管理页（tag_controller.dart）的那个。本页在 main.dart 里是
  /// IndexedStack 的一个分支——**保活、不会重新 initState**，所以从标签管理页
  /// 改完返回时，这里的开关还停在旧值：文案写着「已关闭」，可过滤其实已经
  /// 生效；用户再点一下反而是把它关掉。
  ///
  /// 这与 user_list_screen.dart 里已有的同一类处理（注释写的是
  /// 「IndexedStack 保活使本页不会自动重建，返回后必须刷新」）是同一个坑，
  /// 区别只是本页被路由遮住时拿不到通知。用 RouteAware 在**恢复可见**时读一次
  /// 存储，而不是在 didChangeDependencies 里读 —— 后者在路由 push 期间就会
  /// 触发，那时用户可能还没改完。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 只在「依附的 ModalRoute 变了」时重新同步，而不是每次 build 都同步。
    // ModalRoute.of(context) 在 didChangeDependencies 里拿到的就是当前 route，
    // 拿它当 key 与上一次比较即可（这是 Flutter 里判断「路由是否换了」的标准写法）。
    final route = ModalRoute.of(context);
    if (route == _lastRoute) return;
    _lastRoute = route;
    // 在下一帧同步，而不是立刻：本页被 push 回来时路由的动画还没结束，
    // 立刻读存储虽然也对，但会在同一帧内连续 setState 两次，白白多一次重建。
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncStorage());
  }

  void _syncStorage() {
    if (!mounted) return;
    final actualGay = StorageService.isGayMode();
    final actualCompat = StorageService.getVideoCompatMode();
    if (actualGay != _gayMode || actualCompat != _videoCompat) {
      setState(() {
        _gayMode = actualGay;
        _videoCompat = actualCompat;
      });
    }
  }

  // ─── 网络诊断 ─────────────────────────────────────────────────────────────
  bool _diagRunning = false;
  final List<DiagItem> _diag = [];

  Future<void> _runDiag() async {
    if (_diagRunning) return;
    setState(() {
      _diagRunning = true;
      _diag.clear();
    });

    Future<void> step(String label, Future<String> Function() fn,
        {bool expectFail = false}) async {
      if (!mounted) return;
      setState(() => _diag.add(DiagItem(label: label, running: true)));
      String result;
      try {
        result = await fn();
      } catch (e) {
        result = '失败: $e';
      }
      if (!mounted) return;
      final pass = NetworkDiagnosticsService.passed(result);
      setState(() {
        final i = _diag.indexWhere((d) => d.label == label);
        if (i >= 0) {
          _diag[i] = DiagItem(
            label: label,
            result: result,
            ok: expectFail ? !pass : pass,
          );
        }
      });
    }

    // 取样一次供 2/6/7/8/9 复用：原先每个测试各自下一遍 100KB+ 的 json.gz，
    // 一整轮诊断光下载就要十几秒。
    RawJsonResult? sample;
    String? avatarUrl, photoUrl, videoUrl;
    Future<void> ensureSample() async {
      if (sample != null) return;
      final users = await _api.getUserList();
      if (users.isEmpty) return;
      final raw =
          await NetworkDiagnosticsService.fetchRawJson(users.first.username);
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
    }

    // 1. API 经 ECH 代理（TwitterApi 实际通道：x.moonchan.xyz 被墙后走
    //    127.0.0.1:<port> 的 ECH 隧道；代理未启动时请求会等待，不直连）
    await step('1. API 经 ECH 代理 (TwitterApi 实际通道)', () async {
      final users = await _api.getUserList();
      final via = TwitterApi.proxyPort != null
          ? '127.0.0.1:${TwitterApi.proxyPort}'
          : '等待代理就绪(未注册端口)';
      return '$via → ${users.length} 个用户';
    });

    // 2. 原始 JSON：编码检测 + 字段与模型匹配检查
    await step('2. 用户 JSON 编码与字段检查', () async {
      await ensureSample();
      final s = sample;
      if (s == null) return '失败: 用户列表为空';
      return NetworkDiagnosticsService.checkJsonFields(s);
    });

    // 2b. getMetaData 经 Dio + fromJson 解析 —— App 显示头像/媒体走的就是这条
    // 路。测试 2 是 raw 抓取，绕过了 Dio 与模型层，两者结论可能完全不同：
    // raw 有 644 条而这里为 0，就说明问题在解析层而不是网络。
    await step('2b. getMetaData 经 Dio+模型解析', () async {
      try {
        final users = await _api.getUserList();
        if (users.isEmpty) return '失败: 用户列表为空';
        final meta =
            await _api.getMetaData(users.first.username, forceRefresh: true);
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
      }
    });

    // 3. API 原始探测（不经 Dio，用 dart:io 直接 GET，区分 Dio/网络层问题）。
    //    3a 直连（x.moonchan.xyz 被墙时预期失败）；3b 经 ECH 代理（实际通道）。
    await step('3a. API 直连 (预期失败，被墙)', () {
      return NetworkDiagnosticsService.httpProbe('$kApiBase/?list=users', timeoutSec: 10);
    }, expectFail: true);
    await step('3b. API 经代理 raw (实际通道)', () async {
      final port = TwitterApi.proxyPort;
      if (port == null) return '失败: 未注册代理端口';
      return NetworkDiagnosticsService.httpProbe('http://127.0.0.1:$port/api/twitter/?list=users');
    });

    // 4. video-cf 经本机 ECH 代理
    await step('4. video-cf 经 ECH 代理', () async {
      final port = widget.proxy.port;
      if (port == null) return '失败: 代理未启动 (port=null)';
      return NetworkDiagnosticsService.httpProbe('http://127.0.0.1:$port/favicon.ico');
    });

    // 5. video-cf 直连（预期失败：被墙，需 ECH）
    await step('5. video-cf 直连 (预期失败)', () {
      return NetworkDiagnosticsService.httpProbe('https://video-cf.twimg.com/favicon.ico', timeoutSec: 10);
    }, expectFail: true);

    // 6. 真实头像 URL → 代理 → raw HttpClient（证明“链路通不通”）
    await step('6. 真实头像经代理 (raw HttpClient)', () async {
      final port = widget.proxy.port;
      if (port == null) return '失败: 代理未启动 (port=null)';
      await ensureSample();
      final avatar = avatarUrl;
      if (avatar == null || avatar.isEmpty) return '失败: 无头像 URL';
      final replaced = EchUrl.rewrite(avatar, port);
      final probe = await NetworkDiagnosticsService.httpProbe(replaced, timeoutSec: 30);
      return '原始: $avatar\n代理: $replaced\n→ $probe';
    });

    // 7. 真实头像 → NetworkImage 解码（ProxyAvatar 用的就是这套栈）。
    // 与测试 6 的区别：这里过 Flutter 的图片缓存与解码。若 6 通过而 7 失败，
    // 说明问题在 widget 层（解码/尺寸/缓存），而不是网络。
    await step('7. 真实头像 widget 栈解码 (ProgressiveImageProvider)', () async {
      final port = widget.proxy.port;
      if (port == null) return '失败: 代理未启动 (port=null)';
      await ensureSample();
      final avatar = avatarUrl;
      if (avatar == null || avatar.isEmpty) return '失败: 无头像 URL';
      final r = await NetworkDiagnosticsService.imageDecodeProbe(EchUrl.rewrite(avatar, port));
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
      final r = await NetworkDiagnosticsService.imageDecodeProbe(rewritten);
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
      final r = await NetworkDiagnosticsService.rangeProbe(rewritten);
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
    final via = TwitterApi.proxyPort != null
        ? '经 ECH 代理 127.0.0.1:${TwitterApi.proxyPort}'
        : '等待代理就绪(未注册端口)';
    buf.writeln('API endpoint: $kApiBase ($via)');
    buf.writeln('视频兼容模式: ${_videoCompat.summary}');
    final lastDecoder = await VideoCompatChannel.getLastDecoderSummary();
    if (lastDecoder != null) {
      buf.writeln('最近视频解码器: $lastDecoder');
    }
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
        content: const Text('将清除所有收藏、屏蔽列表、标签规则、搜索历史，'
            '以及视频封面缓存。\n\n此操作不可撤销。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清除')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await StorageService.clearAll();
    // 封面缓存也一起清：它在磁盘上（应用支持目录的 posters/），不清会越攒越多。
    await PosterService.clearAll();
    // 图片磁盘缓存（v0.6.1 新增，image-cache/）：同一个理由，而且它更大。
    await ProgressiveDiskCache.clearAll();
    await VideoDownloader.cleanExpiredTempFiles(maxAge: Duration.zero);
    if (mounted) {
      // clearAll 把兼容模式也复位成标准了：本地 state 与原生解码模式都要跟上，
      // 否则清完数据这一页还显示着旧模式、原生侧也还停在旧的解码策略上。
      final compatAfterClear = StorageService.getVideoCompatMode();
      unawaited(VideoCompatChannel.apply(compatAfterClear));
      setState(() {
        _gayMode = StorageService.isGayMode();
        _videoCompat = compatAfterClear;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('数据已清除')));
    }
  }

  /// 清除日志：磁盘 app.log + 内存日志。范围与边界见 LogService.clearLogs
  /// —— 异常结束记录与崩溃检测标记有意保留。
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
          const Divider(),

          // ─── 视频播放兼容模式（默认标准，出问题时逐级尝试）──────────────────
          _SectionTitle(
            title: '视频播放兼容（默认标准模式）',
            icon: Icons.video_settings,
            color: Colors.indigo,
          ),
          const ListTile(
            leading: Icon(Icons.info_outline, color: Colors.indigo),
            title: Text('画面斜切 / 绿色斜纹时改这里'),
            subtitle: Text(
              '部分机型（多为联发科）播放宽高不能被 16 整除的竖屏视频会花屏——'
              '硬件解码器输出的行跨度与 Flutter 纹理采样对不上。从上往下逐级试，'
              '选到第一个画面正常的即可；越靠上的模式越省电。'
              '所有模式都只是调整解码器的尝试顺序，不会删掉硬件解码，'
              '软解解不了的格式仍会自动回退硬解。',
            ),
          ),
          // 5 个选项直接铺开而不是藏进下拉框：出问题的用户正处在「要把所有选项
          // 试一遍」的状态，多一次点击只会让人以为没得选。
          ...VideoCompatMode.values.map(
            (mode) => ListTile(
              leading: Icon(
                mode == _videoCompat
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: mode == _videoCompat ? Colors.indigo : Colors.grey,
              ),
              title: Text(mode.label),
              subtitle: Text(mode.description),
              selected: mode == _videoCompat,
              onTap: () => _updateVideoCompat(mode),
            ),
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
            subtitle: const Text('清除收藏、屏蔽、标签、搜索历史'),
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

          // ─── 日志与反馈 ─────────────────────────────────────────────────────
          _SectionTitle(title: '日志与反馈', icon: Icons.bug_report, color: Colors.purple),
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

  /// 复制反馈包：先补一次 Go 日志（最后两秒的行可能还没进磁盘），再组装。
  Future<void> _copyLogDump() async {
    await LogService.pollGoLogs(widget.proxy.getLogs());
    final lastDecoder = await VideoCompatChannel.getLastDecoderSummary();
    if (!mounted) return;
    await copyLogDump(context, extra: {
      '代理': widget.proxy.isRunning ? '运行中' : '已停止',
      '端口': '${widget.proxy.port ?? '-'}',
      'ECH 初始化': '${widget.proxy.isInitialized}',
      'API endpoint': TwitterApi.proxyPort != null
          ? '$kApiBase → 127.0.0.1:${TwitterApi.proxyPort} (ECH)'
          : '$kApiBase (等待代理就绪)',
      '视频兼容模式': '${_videoCompat.summary} (decoder=${_videoCompat.nativeDecoderMode})',
      if (lastDecoder != null) '最近视频解码器': lastDecoder,
    });
  }

  /// 异常结束记录（最多 10 条）。判定依据见 LogService.takeUncleanExit——
  /// 强杀与系统回收也会落到这里，所以文案只说「没有正常结束」。
  void _updateVideoCompat(VideoCompatMode next) {
    setState(() => _videoCompat = next);
    StorageService.setVideoCompatMode(next);
    unawaited(VideoCompatChannel.apply(next));
  }

  void _showIncidents() {
    final items = LogService.incidents;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('异常结束记录'),
        content: SizedBox(
          // 不用 double.maxFinite：Windows 端会撑成整屏宽（已知问题）。
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
    // 读磁盘 app.log（不是 Go ring）：反馈包里放的就是这份，看到什么就
    // 能复制什么。Go ring 只有 500 行内存态，ring 里早就被挤掉的历史和
    // 所有 Dart 侧错误（recordError 只落盘不进 ring）在这里是看不到的 ——
    // 那等于让用户在屏幕上看到的和反馈包里对不上。
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
          // 不用 double.maxFinite：Windows 桌面端会撑满整屏宽（与 _showIncidents 保持同一定宽策略）。
          width: 520,
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

class _DiagTile extends StatelessWidget {
  final DiagItem item;

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
