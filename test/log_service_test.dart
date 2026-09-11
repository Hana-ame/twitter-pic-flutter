// log_service_test.dart
// 日志落盘与「异常退出」判定的回归测试。
//
// 这些逻辑没有 UI、也不依赖设备，所以能在 CI 的 `flutter test` 里真跑：
// 日志目录通过 LogService.debugUseDirectory 直接注入临时目录，
// 不需要 mock path_provider 的平台通道。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/services/log_service.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('log_service_test');
    LogService.resetForTests();
    await LogService.debugUseDirectory(tmp);
  });

  tearDown(() async {
    LogService.resetForTests();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<String> logText() async {
    final dir = LogService.logDirectoryPath;
    if (dir == null) return '';
    final f = File('$dir/app.log');
    if (!await f.exists()) return '';
    return f.readAsString();
  }

  test('首次启动没有会话文件：不报异常退出', () async {
    expect(await LogService.takeUncleanExit(), isNull);
  });

  test('会话没打正常退出标记 → 下次启动判定为没正常结束', () async {
    LogService.startSession();

    final incident = await LogService.takeUncleanExit();
    expect(incident, isNotNull);
    expect(incident!.buildNum, 'test');
    // 记录会留在历史里，设置页据此展示
    expect(LogService.incidents, hasLength(1));
  });

  test('打了正常退出标记就不再判定为异常', () async {
    LogService.startSession();
    LogService.markCleanExit();

    expect(await LogService.takeUncleanExit(), isNull);
  });

  test('detached 后又回到前台：标记翻回进行中，之后闪退仍能检测到', () async {
    LogService.startSession();
    LogService.markCleanExit();
    expect(await LogService.takeUncleanExit(), isNull);

    // 下一次会话：模拟 resumed 把标记翻回来
    LogService.startSession();
    LogService.markCleanExit();
    LogService.markSessionActive();

    expect(await LogService.takeUncleanExit(), isNotNull);
  });

  test('Go 日志增量落盘；缓冲被清空时打标记并只补一次全量', () async {
    await LogService.pollGoLogs(['a', 'b']);
    expect(await logText(), contains('a\nb\n'));

    await LogService.pollGoLogs(['a', 'b', 'c']);
    var text = await logText();
    expect(text, contains('c'));
    // 增量：a 只应出现一次（不是每次轮询全量重写）
    expect('a'.allMatches(text).length, 1);

    // 模拟 StartProxy 清空缓冲：旧 tail 在新列表里找不到
    await LogService.pollGoLogs(['x']);
    text = await logText();
    expect(text, contains('日志缓冲已轮转'));
    expect(text, contains('x'));
  });

  test('缓冲裁剪（下标对不上）时按 tail 定位，不重复写', () async {
    await LogService.pollGoLogs(['a', 'b', 'c']);
    // 条数不变但整体前移一行：下标 2 处已不是 'c'
    await LogService.pollGoLogs(['b', 'c', 'd']);

    final text = await logText();
    expect(text, contains('d'));
    expect('d'.allMatches(text).length, 1);
  });

  test('Dart 错误同时进内存与磁盘，并出现在反馈包里', () async {
    LogService.recordError('FlutterError', 'boom', StackTrace.empty);
    await LogService.flush();

    expect(await logText(), contains('boom'));

    final dump = await LogService.buildDump();
    expect(dump, contains('boom'));
    // 反馈包里必须带上反馈渠道，否则用户拿到日志也不知道发去哪
    expect(dump, contains(LogService.kGroupUrl));
    expect(dump, contains(LogService.kGroupApplyUrl));
  });

  test('诊断信息（非错误）也会落盘并进反馈包', () async {
    LogService.recordNote('poster', '抓帧不可用：已退回每张卡片各自持有播放器');
    await LogService.flush();

    expect(await logText(), contains('抓帧不可用'));

    final dump = await LogService.buildDump();
    expect(dump, contains('本次运行诊断'));
    expect(dump, contains('抓帧不可用'));
    // 不能混进"错误"段：段落名撒谎就等于没有诊断
    expect(dump, isNot(contains('本次运行 Dart 错误')));
  });

  test('调用方补充的上下文（代理状态等）会进反馈包', () async {
    final dump = await LogService.buildDump(
      extra: const {'代理': '运行中', '端口': '8443'},
    );
    expect(dump, contains('代理: 运行中'));
    expect(dump, contains('端口: 8443'));
  });

  test('「不再提示」跨会话持久化', () async {
    await LogService.suppressPrompt();
    expect(LogService.promptSuppressed, isTrue);

    // 模拟重启：清内存态但保留目录
    LogService.resetForTests();
    await LogService.debugUseDirectory(tmp);
    expect(LogService.promptSuppressed, isTrue);
  });

  test('writeDump 落成文件', () async {
    final f = await LogService.writeDump(prefix: 'dump');
    expect(f, isNotNull);
    expect(await f!.exists(), isTrue);
    expect(await f.readAsString(), contains('=== Twitter Pic 反馈日志 ==='));
  });
}
