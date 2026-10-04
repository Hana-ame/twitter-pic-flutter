// 「默认屏蔽标签复活」缺陷的回归测试。
//
// 原实现用 `if (storedBlock.isEmpty)` 决定要不要给默认值，而「用户主动清空」
// 和「从没配过」在这个判据下**完全一样** —— 于是用户把唯一的「无关内容」删掉，
// 重启它又回来了，而且**再也删不掉**（每次开页面都从默认值重新长出来）。
//
// 判据写成「显式存了空列表就不许复活」，因为这正是用户能观察到的差别：
// 存了 [] 就该显示「无屏蔽标签」，默认只在键**不存在**时出现。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:twitter_pic_flutter/services/storage_service.dart';
import 'package:twitter_pic_flutter/widgets/tag_controller.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

/// 把 StorageService 里 fire-and-forget 的写盘链排空。
///
/// `_write()` 内部是 `unawaited(_flush())`，每次写都往 `_flushChain` 上挂一个
/// future。flutter_test 用假异步时钟，`.then` 回调要等下一次 pump 才会跑；
/// 而这些写发生在 widget 测试体内，于是该 future 永远不就绪，框架判定
/// 「还有未完成任务」，用例卡到 10 分钟超时。
///
/// 既有测试没这问题：它们从不在 widget 测试体内调这些写方法。
///
/// 用法：写完立刻 `await flushStorage();`，把链排空。
Future<void> flushStorage() => StorageService.debugFlushPending();
void main() {
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('blockres');
    PathProviderPlatform.instance = _FakePathProvider(tmpDir.path);
    // 用 resetForTests：_loaded 是进程级 static，clearAll 不会把它置回
    // false，第二次 ensureInitialized 会直接 return，导致 _file 仍指着上一个
    // 测试文件留下的临时目录（已被 tearDown 删掉）。单跑绿、整包红。
    StorageService.resetForTests();
    await StorageService.ensureInitialized();
  });

  tearDown(() async {
    // **必须 await 写盘完成再删目录。** _write() 里的 _flush() 是 async 且
    // 调用点不 await（它 fire-and-forget），于是测试结束时仍有一个 pending
    // future 在往磁盘写；tearDown 这时把目录删掉，那个 future 永远等不到
    // 完成 —— flutter_test 判定「还有未完成任务」，整个文件卡到 10 分钟超时。
    await StorageService.clearAll();
    StorageService.resetForTests();
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  testWidgets('用户显式清空屏蔽列表后，默认标签**不许复活**', (tester) async {
    // 这是「用户主动清空」：键存在，值是空列表。
    StorageService.setTagRules({'highlight': <String>[], 'block': <String>[]});
    await flushStorage();

    await tester.pumpWidget(
        const MaterialApp(home: TagControllerScreen()));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('无关内容'), findsNothing,
        reason: '用户已经明确清空了，默认标签不该被塞回来');
    expect(find.text('无屏蔽标签'), findsOneWidget,
        reason: '应如实显示空态');
  });

  testWidgets('从没配过时仍给一份默认屏蔽标签（别把首次体验也一起去掉）',
      (tester) async {
    // 注意：这里**不写** tag-rules，模拟全新安装。
    await tester.pumpWidget(
        const MaterialApp(home: TagControllerScreen()));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('无关内容'), findsOneWidget,
        reason: '键不存在 = 从没配过，默认屏蔽规则应当生效');
  });

  testWidgets('用户自己加进去的屏蔽标签要活过重启', (tester) async {
    StorageService.setTagRules(
        {'highlight': <String>[], 'block': <String>['广告']});
    await flushStorage();

    await tester.pumpWidget(
        const MaterialApp(home: TagControllerScreen()));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('广告'), findsOneWidget);
    expect(find.text('无关内容'), findsNothing,
        reason: '用户给的是 [广告]，默认值不该混进来');
  });
}