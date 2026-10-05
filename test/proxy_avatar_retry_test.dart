// 「头像概率加载不出」的回归钉子。
//
// 背景（本文件要钉的那条因果链）：
//   ProxyAvatar 的候选通道表只有 ECH 一个元素（`_candidates` 在 proxy.port
//   非空时返回单元素列表），于是 errorBuilder 里的
//   `if (_attempt < candidates.length - 1)` **永远为假**——那条「换下一个通道」
//   的分支是死代码。于是任何一次加载失败都直接落到首字母占位，
//   **没有第二次机会**：而一次失败的常见成因是瞬时的（代理刚起 / ECH 抖动 /
//   连接被掐），同项目的 twitter_image.dart 就为此加过一次性自动重试。
//
//   结果是：**一次抖动 = 该账号永久显示字母头像**，直到这个 widget 被整个
//   重建。用户侧的观感就是「有的账号有头像、有的没有」——即「概率加载不出」。
//
// 判据（每条都可证伪）：
//   1) 首次失败必须**自动重试一次**，而不是一次就永久占位（retry 代号 0 → 1）；
//   2) 重试后仍失败才落占位，且**不会无限重试**（retry 恰好为 1，不是 2、3…）；
//   3) 换人（URL 变）后重试额度归还给新人，不被上一张图白吃；
//   4) 端口变化（代理重启）后重试额度同样归还。
//
// 不联网：flutter_test 默认把 HttpOverrides 换成 mock 客户端，任何请求都回
// 400，ProgressiveImageProvider 必然走 reportError —— 正好就是要测的那条失败
// 路径，不需要真的把代理跑起来。
//
// 有界 pump 而非 pumpAndSettle：本项目为此付过「挂死 22 分钟」的代价，
// 逐文件/整包的判据差异见 .github/workflows/build.yml 的绿色分级注释。

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/services/proxy_manager.dart';
import 'package:twitter_pic_flutter/widgets/progressive_image.dart';
import 'package:twitter_pic_flutter/widgets/proxy_avatar.dart';

/// 只暴露「端口可改」这一个可变点的假代理。
///
/// 真实 [ProxyManager] 的 `port` 由 FFI 启动流程写入（单元测试里起不来），
/// 所以这里覆盖 getter：port 与 portNotifier 同源，改一个另一个跟着变，
/// 保持与真实实现「端口变化会触发 portNotifier」这条语义一致。
class _FakeProxy extends ProxyManager {
  final ValueNotifier<int?> notifier = ValueNotifier<int?>(8443);

  @override
  int? get port => notifier.value;

  @override
  ValueListenable<int?> get portNotifier => notifier;
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 当前渲染的 Image 用的 provider 的 retry 代号（= 「这是第几次尝试」）。
int _retryOf(WidgetTester tester) {
  final image = tester.widget<Image>(find.byType(Image));
  return (image.image as ProgressiveImageProvider).retry;
}

/// 有界 pump：给 mock 客户端的异步往返留出真实事件循环的时间。
///
/// 不用 pumpAndSettle：Image 的 completer 在 mock 客户端下永远走失败分支，
/// pumpAndSettle 会一直等「再没有待处理帧」，而失败路径本身不产生新帧的
/// 时刻并不保证到达——历史上这里挂死过。
Future<void> _settle(WidgetTester tester, {int maxPumps = 20}) async {
  for (var i = 0; i < maxPumps; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late _FakeProxy proxy;

  setUp(() => proxy = _FakeProxy());

  tearDown(() {
    proxy.notifier.dispose();
    // 全仓静态状态隔离：本项目的 CI 闸门 1 就是查这件事（写盘 / 写 static
    // 的测试必须 reset），单文件绿、整包串味正是这里出过的形态。
    ProgressiveDiskCache.resetForTests();
  });

  testWidgets('首次加载失败会自动重试一次，而不是一次就永久占位',
      (tester) async {
    await tester.pumpWidget(_wrap(ProxyAvatar(
      url: 'https://pbs.twimg.com/profile_images/abc.jpg',
      fallbackText: 'A',
      proxy: proxy,
    )));

    // 第一次失败前，retry 代号应为 0（初次尝试）。
    expect(_retryOf(tester), 0,
        reason: '首次渲染就是第 0 次尝试');

    await _settle(tester);

    // 关键判据：失败后 retry 必须前进到 1 —— 说明真的重新发了请求。
    // 修复前这里恒为 0，且直接渲染字母占位（永久卡死）。
    expect(_retryOf(tester), 1,
        reason: '首次失败必须自动重试一次（retry 0→1），否则一次抖动就永久变字母头像');
  });

  testWidgets('重试后仍失败才落占位，且不会无限重试', (tester) async {
    await tester.pumpWidget(_wrap(ProxyAvatar(
      url: 'https://pbs.twimg.com/profile_images/abc.jpg',
      fallbackText: 'A',
      proxy: proxy,
    )));
    await _settle(tester);

    // 两次都失败后停在 CircleAvatar（_buildFallback），而不是中间的灰底
    // Container（_buildFallbackInner）——说明重试机会已用尽并正式放弃。
    expect(find.byType(CircleAvatar), findsOneWidget,
        reason: '重试后仍失败才落首字母占位');
    expect(_retryOf(tester), 1,
        reason: '只自动重试一次：retry 恰好为 1，不能是 2/3…（否则是死循环重试）');
  });

  testWidgets('换人后重试额度归还给新人，不被上一张图白吃',
      (tester) async {
    await tester.pumpWidget(_wrap(ProxyAvatar(
      url: 'https://pbs.twimg.com/profile_images/alice.jpg',
      fallbackText: 'A',
      proxy: proxy,
    )));
    await _settle(tester);
    expect(_retryOf(tester), 1, reason: '前置条件：alice 已经用掉了自动重试');

    // 换成 bob：URL 变 → didUpdateWidget 把 retry 与 autoRetried 一起复位。
    await tester.pumpWidget(_wrap(ProxyAvatar(
      url: 'https://pbs.twimg.com/profile_images/bob.jpg',
      fallbackText: 'B',
      proxy: proxy,
    )));

    expect(_retryOf(tester), 0,
        reason: '新人必须从第 0 次尝试重新开始；否则 bob 的唯一一次自动重试被 alice 白吃了');
  });

  testWidgets('端口变化（代理重启）后重试额度归还', (tester) async {
    await tester.pumpWidget(_wrap(ProxyAvatar(
      url: 'https://pbs.twimg.com/profile_images/abc.jpg',
      fallbackText: 'A',
      proxy: proxy,
    )));
    await _settle(tester);
    expect(_retryOf(tester), 1, reason: '前置条件：已用掉自动重试');

    // 代理重启 → 端口变化 → _onPortChanged 复位。端口同时进 URL，
    // 所以这是一张「新目标图」，额度必须从头算。
    proxy.notifier.value = 9999;
    await tester.pump();

    expect(_retryOf(tester), 0,
        reason: '换端口后 retry 必须复位，否则代理重启后头像就再也拿不到图');
  });

  testWidgets('url 为 null 时直接首字母占位，不发任何请求', (tester) async {
    await tester.pumpWidget(_wrap(ProxyAvatar(
      url: null,
      fallbackText: 'A',
      proxy: proxy,
    )));
    await tester.pump();

    expect(find.byType(Image), findsNothing,
        reason: '没有 URL 就没有任何候选通道，不该建 Image');
    expect(find.text('A'), findsOneWidget);
  });
}
