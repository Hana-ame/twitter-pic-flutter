// proxy_avatar.dart
// 头像加载组件。
//
// 通道策略：只有本机 ECH 代理一个通道。
//   EchUrl.rewrite 丢弃原始域名（pbs.twimg.com / video-cf.twimg.com / abs…），
//   代理统一拼 https://video-cf.twimg.com/<path> 再 ECH fetch。
//   代理未启动或加载失败 → 首字母占位。
//
// 背景：pbs.twimg.com 与 video-cf.twimg.com 在墙内直连都被封（实测 000），
// 但两者是同一 CDN 后端，改域名就能命中 video-cf.twimg.com 的 ECH 路径。
// 第三方镜像 pbs.moonchan.xyz 已弃用——不可靠，且会把请求导去未知节点。

import 'package:flutter/material.dart';

import '../services/proxy_manager.dart';
import '../utils/ech_url.dart';
import 'progressive_image.dart';

class ProxyAvatar extends StatefulWidget {
  final String? url;
  final String fallbackText;
  final double radius;
  final ProxyManager proxy;

  const ProxyAvatar({
    super.key,
    required this.url,
    required this.fallbackText,
    required this.proxy,
    this.radius = 16,
  });

  @override
  State<ProxyAvatar> createState() => _ProxyAvatarState();
}

class _ProxyAvatarState extends State<ProxyAvatar> {
  // 当前尝试的候选通道下标；全部失败后显示首字母占位。
  int _attempt = 0;

  // 「第几次尝试」的重试代号，喂给 ProgressiveImageProvider 的 retry 参数。
  //
  // **必须与 _attempt 分开**：_attempt 是「当前在试第几个通道」，而通道表
  // 只有 ECH 一个元素，于是 _attempt 一旦为 1，build 开头的
  // `if (_attempt >= candidates.length) return _buildFallback();` 就会永远
  // 命中占位——两者共用一个计数器时，自动重试会把自己关在门外（首次失败 →
  // 重试 → 直接渲染字母头像，永远不再发请求）。retry 代号只参与 ImageCache
  // 的缓存 key 判据，与通道下标语义不同，不能合并。
  int _retry = 0;

  // 是否已经自动重试过一次。
  //
  // 为什么需要它（这是「头像概率加载不出」的根因）：通道候选表 [ProxyManager
  // 的 _candidates] 只有 ECH 一个元素，于是 `_attempt < candidates.length - 1`
  // 永远为假——errorBuilder 里那个「还有下一个通道就换过去」的分支**永远走不到**，
  // 任何一次失败都直接落到首字母占位。而一次失败的常见成因是**瞬时的**：
  // 代理刚起来 / ECH 握手抖动 / 连接被掐（同一个项目里的
  // twitter_image.dart 就为此加过自动重试，注释原文写着「代理可能刚起来或抽
  // 了一下」）。于是**一次抖动就永久变成字母头像**，直到该 widget 被整个重建
  // ——表现为「有的账号有头像、有的没有」，即用户报的「概率加载不出」。
  //
  // 修法沿用本项目既有的做法（不新造风格）：与 twitter_image.dart 的
  // `_autoRetried` 同构——首次失败用 postFrame 回调自动重试一次（必须推迟到
  // 帧后：errorBuilder 是在 build 期间回调的，直接 setState 会抛
  // "setState() called during build"），再失败才交给占位。
  bool _autoRetried = false;

  @override
  void initState() {
    super.initState();
    // 代理重启后端口变化：重置候选通道下标。否则头像一旦降级到直连就再
    // 也不会回到 ECH 通道——IndexedStack 不重建父级，didUpdateWidget 的
    // port 比对永不触发。
    widget.proxy.portNotifier.addListener(_onPortChanged);
  }

  void _onPortChanged() {
    if (mounted) {
      setState(() {
        _attempt = 0;
        // 端口变了 = 换了一个目标 URL（EchUrl.rewrite 把端口写进 URL），
        // 缓存 key 与重试语义都重来一遍，否则上一张图的「已重试过」会白吃
        // 掉这一张图唯一的一次自动重试。
        _retry = 0;
        _autoRetried = false;
      });
    }
  }

  @override
  void dispose() {
    widget.proxy.portNotifier.removeListener(_onPortChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(ProxyAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.proxy.port != widget.proxy.port) {
      _attempt = 0;
      // 换人（URL 变）或换端口都要把「自动重试额度」还回去：它是一次性的，
      // 用在上一张图上就不该再消耗新图的那一次。
      _retry = 0;
      _autoRetried = false;
    }
  }

  /// 自动重试一次。调用方必须保证已经在帧后（postFrame 回调），
  /// 或已确认不在 build 期间。
  ///
  /// 方法名不能叫 [_retry]：那是 [int _retry] 这个字段的名字，两者同名会在
  /// 分析期直接报 `duplicate_definition`，且 `WidgetsBinding.addPostFrameCallback`
  /// 里那个闭包会把方法调用解析成对 int 的调用 → `invocation_of_non_function_expression`。
  void _autoRetryOnce() {
    if (!mounted) return;
    setState(() {
      // retry 参与 ProgressiveImageProvider 的相等性判据：+1 等于换缓存 key，
      // ImageCache 才不会把上一次那个已经 reportError 过的 completer 交回来
      // （否则「重试」只是重放同一个失败，什么都不会发生）。
      _retry++;
      _autoRetried = true;
    });
  }

  /// 生成候选 URL 列表。
  ///
  /// 只有 ECH 代理一个通道：`EchUrl.rewrite` 丢弃原始域名，代理统一拼
  /// `https://video-cf.twimg.com/<path>` 再 ECH fetch。不尝试 pbs.twimg.com
  /// 直连（墙内必死，实测 000），也不依赖第三方镜像 pbs.moonchan.xyz。
  List<String> _candidates() {
    final url = widget.url;
    if (url == null) return const [];
    final port = widget.proxy.port;
    if (port != null) return [EchUrl.rewrite(url, port)];
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.url;
    if (url == null) return _buildFallback();

    final candidates = _candidates();
    if (_attempt >= candidates.length) return _buildFallback();

    final target = candidates[_attempt];

    return ClipOval(
      child: SizedBox(
        width: widget.radius * 2,
        height: widget.radius * 2,
        child: Image(
          // v0.6.4：改用 ProgressiveImageProvider，不再用 Image.network。
          // 理由是**所有 media 必须走 ECH 代理 + 落磁盘缓存**这一条纪律：
          // Image.network 只命中内存 ImageCache，内存一挤就得经 ECH 重下一遍
          // 头像；而 ProgressiveImageProvider 是本项目媒体取流的唯一入口
          // （ECH 改写 + 逐块解码 + 磁盘缓存都在里面）。
          image: ProgressiveImageProvider(target, retry: _retry),
          key: ValueKey('${target}_$_retry'),
          fit: BoxFit.cover,
          width: widget.radius * 2,
          height: widget.radius * 2,
          errorBuilder: (context, error, stackTrace) {
            // 首次失败自动重试一次（与 twitter_image.dart 同构）：失败多是
            // 瞬时的（代理刚起 / ECH 抖动 / 连接被掐），不重试就永久变字母。
            //
            // 必须推迟到帧后：errorBuilder 是 Image 在 build 期间回调的，
            // 这里直接 setState 会抛 "setState() called during build"。
            if (!_autoRetried) {
              WidgetsBinding.instance
                  .addPostFrameCallback((_) => _autoRetryOnce());
              return _buildFallbackInner();
            }
            // 当前通道失败 → 试下一个候选通道。
            if (_attempt < candidates.length - 1) {
              setState(() => _attempt++);
              return _buildFallbackInner();
            }
            return _buildFallback();
          },
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return _buildFallbackInner();
          },
        ),
      ),
    );
  }

  Widget _buildFallback() {
    return CircleAvatar(
      radius: widget.radius,
      child: Text(
        widget.fallbackText,
        style: TextStyle(fontSize: widget.radius * 0.8),
      ),
    );
  }

  Widget _buildFallbackInner() {
    return Container(
      width: widget.radius * 2,
      height: widget.radius * 2,
      color: Colors.grey[300],
      child: Center(
        child: Text(
          widget.fallbackText,
          style: TextStyle(fontSize: widget.radius * 0.8, color: Colors.white),
        ),
      ),
    );
  }
}
