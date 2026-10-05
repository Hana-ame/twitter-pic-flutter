// 「头像在网络超时时刻永久灰着」的回归钉子（PR #6 / progressive_image.dart）。
//
// 背景（本文件要钉的那条因果链）：
//   `_pump()` 里 `await request.close()` 曾经**既没有超时也没有 catch**。
//   `connectionTimeout` 只管 TCP 建连；上游一旦把连接接了却迟迟不吐响应头，
//   这个 await 就**永远不返回**。于是链条是：
//
//     _pump() 永不完成
//       → completer 既不 setImage 也不 reportError
//       → Image.errorBuilder 永不回调
//       → proxy_avatar 的自动重试（#4）也永不触发（它挂在 errorBuilder 里）
//       → loadingBuilder 一直返回灰底 Container
//
//   用户侧观感就是「头像有概率加载不出，且恰好发生在网络超时时刻」——
//   「有概率」来自「那一次请求有没有正好撞上上游卡住」，不是并发压力。
//
// 修复（48afa27）：给整个请求加 deadline 定时器，覆盖 getUrl 与 close()，
// 到点 `client.close(force: true)`，让在途 await 抛错走既有 catch → reportError。
//
// 判据（每条可证伪，全部只用公开 API —— 断言 errorBuilder/loadingBuilder
// 被调用了什么，也就是用户真正看得见的行为）：
//   1) 上游接了连接却不吐头 → 必须**报错**（errorBuilder 被调用），不是永久
//      停在 loading；
//   2) 报错次数有界，不反复报错形成死循环；
//   3) **不误杀**：响应头一到 deadline 就被取消，正常下载必须照常成功。
//
// 手法：**真的起一个本地 HttpServer**，让客户端用真实 HttpClient 打过去。
// 不 mock dart:io——HttpClient / HttpClientRequest / HttpClientResponse 都是
// interface class，继承或实现它们过不了 analyze（no_generative_constructors_
// in_superclass + invalid_use_of_type_outside_library），第一版就是这么翻车的。
// 真实 socket 反而更可信：被测的 deadline 强关机制跑的是真的 force close。
//
// 必须走 tester.runAsync：`deadline` 是**真 Timer**，而 testWidgets 默认跑在
// fake-async 区里，真 Timer 在那儿永远不触发，测试会「假通过」。runAsync 把
// 真定时器与真 socket I/O 挪出 fake-async。
//
// 有界 pump 而非 pumpAndSettle：本项目为此付过「挂死 22 分钟」的代价，
// 逐文件/整包的判据差异见 .github/workflows/build.yml 的绿色分级注释。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/widgets/progressive_image.dart';

/// 1x1 纯色 PNG，运行时用 zlib 现场构造。
///
/// 为什么不内联字节串：字面量难读也难校验；构造过程读者能看懂。只依赖
/// dart:io 的 zlib，CRC32 自实现（zlib 没暴露 crc32）。
Uint8List _buildPng() {
  final w = 1, h = 1;
  final row = List<int>.filled(w * 3 + 1, 0)..[0] = 0; // filter byte + RGB
  final raw = List<int>.filled(row.length * h, 0);
  for (var y = 0; y < h; y++) {
    raw.setRange(y * row.length, (y + 1) * row.length, row);
  }

  /// 大端 4 字节。Dart 没有 uint32，用 int（补码足够）并显式 & 0xff。
  List<int> be32(int v) =>
      <int>[(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

  int crc32(List<int> data) {
    var crc = 0xffffffff;
    for (final byte in data) {
      crc ^= byte;
      for (var k = 0; k < 8; k++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    return crc ^ 0xffffffff;
  }

  List<int> chunk(String type, List<int> data) {
    final body = <int>[...type.codeUnits, ...data];
    return <int>[...be32(data.length), ...body, ...be32(crc32(body))];
  }

  final ihdr = <int>[
    ...be32(w),
    ...be32(h),
    8, 2, 0, 0, 0, // 8bit truecolor
  ];
  return Uint8List.fromList(<int>[
    137, 80, 78, 71, 13, 10, 26, 10, // PNG magic
    ...chunk('IHDR', ihdr),
    ...chunk('IDAT', zlib.encode(raw)),
    ...chunk('IEND', const <int>[]),
  ]);
}

final Uint8List _pngBytes = _buildPng();

/// 起一个本地服务器，按 [respond] 决定对每个请求怎么回。
///
/// [respond] 拿到 (request, response)：要么完全不写（模拟「接了连接却不吐
/// 头」），要么立刻把 PNG 写回去。请求对象在测试结束时统一 close。
Future<HttpServer> _serve(
  void Function(HttpRequest req, HttpResponse res) respond,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    respond(req, res);
    // 测试收尾时服务器会被 close，pending 的响应随之结束。
  });
  return server;
}

/// 记录 Image 的 errorBuilder / loadingBuilder 各被调了几次。
///
/// 只用公开 API：断言的是用户看得见的行为（灰占位 vs 报错兜底），不去戳
/// ImageStreamCompleter 的私有字段。
class _Probe {
  int errorCount = 0;

  /// loadingBuilder 拿到 progress == null 的次数，即「图真的到位了」。
  int doneCount = 0;
}

/// 装一个 Image，挂上计数用的 error/loading builder。
Widget _host(ProgressiveImageProvider provider, _Probe probe) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: Image(
          image: provider,
          width: 32,
          height: 32,
          errorBuilder: (context, error, stack) {
            probe.errorCount++;
            return const SizedBox(width: 32, height: 32);
          },
          loadingBuilder: (context, child, progress) {
            if (progress == null) probe.doneCount++;
            return const SizedBox(width: 32, height: 32);
          },
        ),
      ),
    ),
  );
}

/// 让真 Timer（deadline）与真 socket I/O 跑完，再推一帧让结果落到树上。
Future<void> _settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
}

void main() {
  late HttpServer server;

  tearDown(() async {
    await server.close(force: true);
    // 全仓静态状态隔离：本项目 CI 闸门 1 就是查这件事（写盘 / 写 static
    // 的测试必须 reset），单文件绿、整包串味正是这里出过的形态。
    ProgressiveDiskCache.resetForTests();
  });

  testWidgets('上游接了连接却不吐响应头：deadline 到点必须报错，不能永久停在 loading',
      (tester) async {
    // 关键：accept 之后**什么都不写**。连接是通的、请求也发出去了，
    // 但响应头永远不来 —— 正是线上那个「代理接了却不吐头」的形态。
    server = await _serve((req, res) {});

    // timeout 压到 300ms：真机默认 20s，测试不能真等。
    final provider = ProgressiveImageProvider(
      'http://127.0.0.1:${server.port}/avatar.jpg',
      timeout: const Duration(milliseconds: 300),
    );
    final probe = _Probe();

    await tester.pumpWidget(_host(provider, probe));
    await _settle(tester);

    expect(probe.errorCount, greaterThan(0),
        reason: '上游不吐头时 deadline 到点必须让错误冒到 errorBuilder；'
            '修复前这里会永久挂在 loadingBuilder，completer 既不 setImage '
            '也不 reportError，用户看到的就是永久灰占位');
    expect(probe.doneCount, 0, reason: '没有数据，不该出现「图已到位」');
  });

  testWidgets('deadline 到点后不会反复报错形成死循环', (tester) async {
    server = await _serve((req, res) {});
    final provider = ProgressiveImageProvider(
      'http://127.0.0.1:${server.port}/avatar.jpg',
      timeout: const Duration(milliseconds: 200),
    );
    final probe = _Probe();

    await tester.pumpWidget(_host(provider, probe));
    await _settle(tester);

    // 有界的具体形状：不该是「一次都没有」（那说明没兜住），也不该是
    // 「每轮都涨」（那是死循环）。上限取远高于实际需求的值，只挡无限循环。
    expect(probe.errorCount, lessThan(20),
        reason: 'deadline 触发后错误冒一次就完事，不该反复报错形成死循环');
  });

  testWidgets('不误杀：响应头一到就取消 deadline，正常下载照常成功',
      (tester) async {
    server = await _serve((req, res) {
      res.headers.contentType = ContentType('image', 'png');
      res.add(_pngBytes);
      res.close();
    });
    // timeout 故意给得偏小，模拟慢速：若 deadline 没有在响应头处取消，
    // 这单就会被杀 —— 那是修复本身引入的新 bug。
    final provider = ProgressiveImageProvider(
      'http://127.0.0.1:${server.port}/big.jpg',
      timeout: const Duration(milliseconds: 300),
    );
    final probe = _Probe();

    await tester.pumpWidget(_host(provider, probe));
    await _settle(tester);

    expect(probe.errorCount, 0,
        reason: '正常响应必须照常成功；deadline 在响应头处就取消了，'
            '不该把慢速大图误杀');
    expect(probe.doneCount, greaterThan(0), reason: '正常路径必须真的解出图');
  });
}