// 标签规则的**跨屏一致性**回归测试。
//
// 这几条钉的是同一个东西：同一份本地规则（屏蔽 / Gay 模式 / 高亮 / 负分口径）
// 在不同屏幕上必须给出**同一个答案**。历史上它们各自漂移，于是同一个查询从
// 两条路进来会显示不同的用户集合、同一枚标签在两个屏幕上含义相反。
//
// 判据一律写成**「某元素在屏幕上找不到」**，而不是「找到了 N 个」—— 后者
// 在过滤根本没发生时也会通过（这正是 test/search_merge_test.dart 里
// `find.text('#自拍'), findsWidgets` 那条断言的问题）。

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:twitter_pic_flutter/api/twitter_api.dart';
import 'package:twitter_pic_flutter/screens/tag_user_list_screen.dart';
import 'package:twitter_pic_flutter/services/proxy_manager.dart';
import 'package:twitter_pic_flutter/services/storage_service.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

/// by=tag 的响应体由测试自己给。
class _TagAdapter implements HttpClientAdapter {
  final String body;
  _TagAdapter(this.body);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path.endsWith('.json.gz')) {
      return ResponseBody.fromString('{}', 200,
          headers: {Headers.contentTypeHeader: <String>[Headers.jsonContentType]});
    }
    return ResponseBody.fromString(body, 200,
        headers: {Headers.contentTypeHeader: <String>[Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
}

Widget host(String body) {
  final api = TwitterApi(adapter: _TagAdapter(body));
  return MaterialApp(
    home: TagUserListScreen(
      tag: '自拍',
      api: api,
      proxy: ProxyManager(),
      onSelectUser: (_) {},
    ),
  );
}

/// 造一个带完整标签集的 by=tag 响应。
String tagBody(String username, Map<String, int> tags) {
  final entries = tags.entries.map((e) => '"${e.key}":${e.value}').join(',');
  return '[{"username":"$username","tags":{$entries}}]';
}

//
// ## 为什么全文只用有界 pump，不用 pumpAndSettle
//
// 被测页面里有**永不停止的动画**：
//   - UserListScreen 在结果回来前渲染 _SkeletonCircle（AnimationController.repeat）；
//   - TagUserListScreen 外面包着 RefreshIndicator，转圈动画同样不停。
// pumpAndSettle 的语义是「一直 pump 直到没有任何待处理帧」，遇到这种动画
// **永远不会返回** —— 本次 CI 上就因此挂死了 30 多分钟（正常一轮约 80 秒）。
// 一律改成 pump(const Duration(...))，自己控制推进多少帧。
void main() {
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('tagrules');
    PathProviderPlatform.instance = _FakePathProvider(tmpDir.path);
    // **必须用 resetForTests，不能用 clearAll + ensureInitialized。**
    // _loaded 是进程级 static，clearAll 不会把它置回 false，所以第二次
    // ensureInitialized 会直接 return，_file 仍指着**上一个测试文件**留下的
    // 临时目录（那个目录已被 tearDown 删掉）—— 于是写入落到不存在的路径上。
    // 单独跑本文件没事，多文件一起跑就出问题：这是典型的「单跑绿、整包红」。
    StorageService.resetForTests();
    await StorageService.ensureInitialized();
  });

  tearDown(() async {
    await StorageService.clearAll();
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  testWidgets(
    'Gay 模式关闭时，带 Gay 标签的账号**不该**出现在标签反查列表里',
    (tester) async {
      // 前提：Gay 模式确实是关的（默认值）。
      expect(StorageService.isGayMode(), isFalse);
      // u1 同时带「自拍」和 Gay 词表里的「男同」。
      await tester.pumpWidget(
          host(tagBody('u1', {'自拍': 2, '男同': 1})));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      // 判据是「找不到」：Gay 模式存在的全部意义就是别让它漏出来。
      expect(find.text('@u1'), findsNothing,
          reason: 'Gay 模式关闭时，男同账号不该从标签页漏出来');
    },
  );

  testWidgets(
    'Gay 模式**开启**时，同一个账号应该出现（过滤方向要真的反过来）',
    (tester) async {
      StorageService.setGayMode(true);
      await tester.pumpWidget(
          host(tagBody('u1', {'自拍': 2, '男同': 1})));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('@u1'), findsOneWidget,
          reason: '开了 Gay 模式就该放行 —— 这条防止「过滤写死成永远隐藏」');
    },
  );

  testWidgets(
    '负分标签在标签列表里**不展示**（与详情页同一口径）',
    (tester) async {
      // 「自拍」权重为负：详情页的 TagDisplayArea 早就把它藏了（commit
      // 6ea90cd），列表页必须一致，否则同一个标签两个屏幕两种含义。
      await tester.pumpWidget(host(tagBody('u1', {'自拍': -1})));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('#自拍'), findsNothing,
          reason: 'score<0 的标签全局不展示');
    },
  );

  testWidgets('高亮规则要能到达标签列表（带星标）', (tester) async {
    StorageService.setHighlightTags(['自拍']);
    await tester.pumpWidget(host(tagBody('u1', {'自拍': 2})));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byIcon(Icons.star), findsOneWidget,
        reason: '标签管理里标了高亮，标签页就该给同样的强调');
  });

  testWidgets('未高亮的标签**不该**有星标（防止星标变成常亮装饰）', (tester) async {
    StorageService.setHighlightTags(['别的标签']);
    await tester.pumpWidget(host(tagBody('u1', {'自拍': 2})));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byIcon(Icons.star), findsNothing);
  });
}