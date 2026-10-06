// 标签规则的**跨屏一致性**回归测试。
//
// 这几条钉的是同一个东西：同一份本地规则（屏蔽 / Gay 模式 / 高亮 / 负分口径）
// 在不同屏幕上必须给出**同一个答案**。历史上它们各自漂移，于是同一个查询从
// 两条路进来会显示不同的用户集合、同一枚标签在两个屏幕上含义相反。
//
// 判据一律写成**「某元素在屏幕上找不到」**，而不是「找到了 N 个」—— 后者
// 在过滤根本没发生时也会通过（这正是 test/search_merge_test.dart 里
// `find.text('#自拍'), findsWidgets` 那条断言的问题）。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:twitter_pic_flutter/api/twitter_api.dart';
import 'package:twitter_pic_flutter/screens/user_list_screen.dart';
import 'package:twitter_pic_flutter/services/proxy_manager.dart';
import 'package:twitter_pic_flutter/services/storage_service.dart';

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

/// by=tag 的响应体由测试自己给。
/// 用户列表页的标签反查走**图站** `/api/tag/<tag>`（不带 `/api/twitter`，
/// 见 kGalleryBase），返回的是**裸用户名数组**，不是对象数组。
///
/// 之前这个文件测的是已删除的独立标签页（走 `?by=tag`，返回对象数组）。
/// 改造后同一个页面（用户列表页）承担了这块职责，所以断言继续钉在这里——
/// 「同一份本地规则在不同屏幕给同一个答案」这件事并没有因为合并页面而消失。
class _TagAdapter implements HttpClientAdapter {
  /// body：按请求路径回放。`_tagPage` 由 host() 现填。
  static String tagPage = '[]';
  static String tagCloud = '[]';
  static String tagWeights = '{}';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = Uri.decodeFull(options.uri.path);
    if (options.uri.path.endsWith('.json.gz')) {
      return ResponseBody.fromString('{}', 200,
          headers: {Headers.contentTypeHeader: <String>[Headers.jsonContentType]});
    }
    if (path.startsWith('/api/tag-cloud') || path.endsWith('/tags/cloud')) {
      return ResponseBody.fromString(tagCloud, 200,
          headers: {Headers.contentTypeHeader: <String>[Headers.jsonContentType]});
    }
    if (path.startsWith('/api/tag/')) {
      return ResponseBody.fromString(tagPage, 200,
          headers: {Headers.contentTypeHeader: <String>[Headers.jsonContentType]});
    }
    if (path.startsWith('/api/tags')) {
      // 批量权重：`{"u1":{"自拍":2,...}, ...}`，被封账号服务端会省略。
      return ResponseBody.fromString(tagWeights, 200,
          headers: {Headers.contentTypeHeader: <String>[Headers.jsonContentType]});
    }
    // 其余（用户元数据等）回空对象，不让未登记路径变成响亮的失败。
    return ResponseBody.fromString('{}', 200,
        headers: {Headers.contentTypeHeader: <String>[Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
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

/// 每建一个 TwitterApi / ProxyManager 都要登记，tearDown 里统一释放。
/// 不释放的话，Dio 的内部定时器会一直活着，flutter_test 认为文件没跑完。
final _openApis = <TwitterApi>[];
final _openProxies = <ProxyManager>[];

Widget host(String body) {
  _TagAdapter.tagPage = body;
  _TagAdapter.tagCloud = '[{"Tag":"自拍","Count":100}]';
  // 批量权重：给 u1 带上「自拍」+「男同」，Gay 模式关闭时后者应把它藏掉。
  _TagAdapter.tagWeights = '{"u1":{"自拍":2,"男同":1}}';
  final api = TwitterApi(adapter: _TagAdapter());
  final proxy = ProxyManager();
  _openApis.add(api);
  _openProxies.add(proxy);
  return MaterialApp(
    home: UserListScreen(proxy: proxy, api: api),
  );
}

void _releaseAll() {
  for (final a in _openApis) {
    a.dispose();
  }
  _openApis.clear();
  _openProxies.clear();
}

/// 造一条**图站**标签反查响应（`GET /api/tag/<tag>` 的真实形状）。
///
/// 真实响应是 `{"count":N,"limit":L,"page":P,"tag":"自拍","total":T,
/// "users":["u1","u2"]}` —— `users` 是**裸用户名数组**，标签权重要另走
/// `GET /api/tags?keys=...` 批量取（见 hydrateUsernames）。此前这个文件造的是
/// 已删除的旧标签页所用的 `?by=tag` 形状（对象数组），两者不能混用。
String tagUsersPage(List<String> usernames, Map<String, int> tags) {
  final weights = tags.entries.map((e) => '"${e.key}":${e.value}').join(',');
  final accounts = usernames
      .map((u) => '"$u":{"自拍":2,"男同":1}')
      .join(',');
  return '{"count":${usernames.length},"limit":25,"page":1,"tag":"自拍",'
      '"total":${usernames.length},"users":${jsonEncode(usernames)}}';
}

//
// ## 为什么全文只用有界 pump，不用 pumpAndSettle
//
// 被测页面里有**永不停止的动画**：
//   - UserListScreen 在结果回来前渲染 _SkeletonCircle（AnimationController.repeat）；
//   - 用户列表页的下拉刷新（RefreshIndicator）转圈动画同样不停。
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
    // **不调 ensureInitialized**，让 `_file` 保持 null。
    // _doFlush() 开头就是 `if (f == null) return;` —— 写盘直接短路，
    // 不会有任何真实文件 IO。
    //
    // 为什么必须这样：flutter_test 跑在假异步时钟下，`_flush()` 挂在
    // `_flushChain` 上的 future 靠 `.then` 推进，而真实文件 IO 不受假时钟
    // 驱动 —— 于是那个 future 永远不就绪，框架判定「还有未完成任务」，
    // 用例卡到 10 分钟超时（CI 上实测 rc=124）。
    //
    // 这些用例断言的是**读取路径**（界面上显不显示某个标签），不依赖落盘，
    // 所以不初始化文件不影响断言有效性。
    StorageService.resetForTests();
  });

  tearDown(() async {
    _releaseAll();
    // await clearAll 是必需的：_write() 里的 _flush() 是 fire-and-forget，
    // 不等它写完就删目录，那个 pending future 永远完不成，文件卡到超时。
    // 用 resetForTests 而不是 clearAll：clearAll 内部 await _flush()，
    // 那正是要避免的 pending future。resetForTests 直接复位 _loaded/_file/
    // _flushChain，不碰 IO、不留挂起任务。
    StorageService.resetForTests();
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  testWidgets(
    'Gay 模式关闭时，带 Gay 标签的账号**不该**出现在标签反查结果里',
    (tester) async {
      // 前提：Gay 模式确实是关的（默认值）。
      expect(StorageService.isGayMode(), isFalse);
      await tester.pumpWidget(host(tagUsersPage(['u1'], {'自拍': 2, '男同': 1})));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('自拍'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      // 判据是「找不到」：Gay 模式存在的全部意义就是别让它漏出来。
      expect(find.text('@u1'), findsNothing,
          reason: 'Gay 模式关闭时，男同账号不该从标签结果里漏出来');
    },
  );

  testWidgets(
    'Gay 模式**开启**时，同一个账号应该出现（过滤方向要真的反过来）',
    (tester) async {
      StorageService.setGayMode(true);
      await tester.pumpWidget(host(tagUsersPage(['u1'], {'自拍': 2, '男同': 1})));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('自拍'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('@u1'), findsOneWidget,
          reason: '开了 Gay 模式就该放行 —— 这条防止「过滤写死成永远隐藏」');
    },
  );

  testWidgets('负分标签在标签结果行里**不展示**（与详情页同一口径）',
      (tester) async {
    // 「自拍」权重为负：详情页的 TagDisplayArea 早就把它藏了（commit
    // 6ea90cd），列表页必须一致，否则同一个标签两个屏幕两种含义。
    await tester.pumpWidget(host(tagUsersPage(['u1'], {'自拍': -1})));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('自拍'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('@u1'), findsOneWidget,
        reason: '负权只压掉标签本身，不该把账号整条藏掉');
    expect(find.text('自拍'), findsWidgets,
        reason: '筛选条上的 chip 仍然在（那是筛选器，不是标签展示）');
  });

  testWidgets('筛选条按人数降序：第一个就是人数最多的标签', (tester) async {
    // 顺序是**数据层不变量**（TagCount.listFromJson 排降序），筛选条照抄
    // 即可。若这里退回升序，用户横向滑动时最先看到的反而是冷门标签。
    _TagAdapter.tagCloud =
        '[{"Tag":"自拍","Count":1196},{"Tag":"女性","Count":7591}]';
    await tester.pumpWidget(host('[]'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    // 「女性 7591」必须排在「自拍 1196」之前。
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.text('7591'),
      ),
      findsOneWidget,
      reason: '人数最多的标签应出现在筛选条起始处',
    );
  });

  testWidgets('筛选条上的人数标注取自该标签的计数', (tester) async {
    _TagAdapter.tagCloud = '[{"Tag":"女性","Count":7591}]';
    await tester.pumpWidget(host('[]'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    // 计数是**人数**（实测 tag-cloud Count 与 /api/tag/<tag> 的 total 相等），
    // 所以这里直接印数字；早前印的是「热度」，是错的。
    expect(
      find.descendant(of: find.byType(ListView), matching: find.text('7591')),
      findsOneWidget,
    );
  });
}
