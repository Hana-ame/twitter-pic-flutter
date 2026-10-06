// 收藏页进详情页的**能力契约**（PR #13 遗留缺口的显式化）。
//
// ## 这条契约是什么
//
// 详情页点标签时会把请求**递回**背后那个用户列表页、就地切换、然后 pop 自己。
// 仓库里有**三处**能构造 `UserDetailScreen`：
//
//   lib/screens/user_list_screen.dart:434  ← 传句柄（正常路径）
//   lib/widgets/fav_list.dart:269          ← 显式传 null（**决定**，不是漏传）
//   test/tag_same_page_test.dart:135       ← 测试自己两种都造
//
// PR #13 只改了第一处，于是「从收藏页进详情页点标签」落到「此页不支持就地切
// 标签」的提示上。**那个提示本身是对的**：收藏页背后没有列表页可以递回
// （`FavoritesTab` 与 `UserListScreen` 是 `IndexedStack` 里两个平级的 Tab、
// 彼此不可见）。错的是「不传」这件事**在代码里说不出来**——它长得跟「忘了传」
// 一模一样，正是 notes/discipline-dont-hide-product-decisions 点名的
// 「能力靠人记得传参」。
//
// 现在由**两层**钉住，两层都不是「靠记得」：
//
//   1. **编译期**：`UserDetailScreen.tagBrowse` 是 `required`（可空）。漏传
//      直接编译不过；只有 `tagBrowse: null` 这一种写法能把「背后没有列表页」
//      写进代码。将来新加 push 点会**被迫**回答这个问题。
//   2. **运行期**：本文件走真实点击路径，断言点了标签之后提示出现、没被 pop、
//      没多发标签反查请求。
//
// ## 为什么还要第 2 层（编译期不是已经够了）
//
// 编译期只保证「写了决定」，不保证「决定是对的」。而这个决定的后果是**用户
// 可见**的：从收藏页点标签必须给出明确反馈。删掉那句提示、或把 null 换成会
// pop 却没切换的句柄，编译期一律放行，只有本文件会红。
//
// ## ⚠️ 绝不用 pumpAndSettle
//
// 详情页里有 `AnimationController.repeat` 常驻动画（刷新指示器 /
// CircularProgressIndicator），pumpAndSettle 永远不返回。全部用有界 pump。

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:twitter_pic_flutter/api/twitter_api.dart';
import 'package:twitter_pic_flutter/services/proxy_manager.dart';
import 'package:twitter_pic_flutter/services/storage_service.dart';
import 'package:twitter_pic_flutter/widgets/fav_list.dart';

/// 收藏页点的详情页会打这几处：
///  - `GET /api/twitter/tags/<user>`  → 标签区（靠 fav_list.dart 透传的
///    api 实例，**不是**详情页自建的那个——自建那个会打真实网络）
///  - `GET /api/twitter/emojis`       → emoji 投票
///  - `/api/twitter/<user>.json.gz`   → `_refreshProfile()`（timeline 为空时）
///  - 其余（用户列表那套）            → 回空对象
class _Adapter implements HttpClientAdapter {
  /// 记录**所有**请求路径，用来断言「点标签没有多发一个列表请求」。
  final List<String> paths = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = Uri.decodeFull(options.uri.path);
    paths.add(options.uri.query.isEmpty ? path : '$path?${options.uri.query}');
    String body;
    if (path.startsWith('/api/twitter/tags/')) {
      body = '{"tags":{"自拍":2}}';
    } else if (path.endsWith('.json.gz')) {
      body = '{"account_info":{"name":"alice","nick":"Alice"},'
          '"timeline":[],"total_urls":0}';
    } else {
      body = '{}';
    }
    return ResponseBody.fromString(body, 200,
        headers: {Headers.contentTypeHeader: <String>[Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

void main() {
  late Directory tmp;
  late _Adapter adapter;

  /// 有界推进。**不要** await 任何真实网络 future 再 pumpWidget。
  Future<void> settle(WidgetTester tester, [int times = 5]) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fav_tag_browse_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    StorageService.resetForTests();
    TwitterApi.resetForTests();
    await StorageService.ensureInitialized();
    adapter = _Adapter();
    StorageService.toggleFav('alice');
  });

  tearDown(() async {
    StorageService.resetForTests();
    TwitterApi.resetForTests();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  testWidgets('收藏页进去的详情页：标签可点，且**一定**给明确反馈',
      (tester) async {
    final api = TwitterApi(adapter: adapter);
    addTearDown(api.dispose);
    final proxy = ProxyManager();
    addTearDown(proxy.dispose);

    // 前置①：收藏项真的在（否则点不到 tile，下面的断言会在自己没喂对数据时
    // 假通过）。
    expect(StorageService.isFav('alice'), isTrue,
        reason: '前置①：alice 必须已收藏');

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [FavList(api: api, proxy: proxy)]),
      ),
    ));
    await settle(tester);
    expect(find.text('@alice'), findsOneWidget,
        reason: '前置②：收藏项必须渲染出来，否则 tap 无从谈起');

    // 进详情页（300ms 的 PageRouteBuilder 过渡）。
    await tester.tap(find.text('@alice'));
    await settle(tester, 15);

    // 前置③④：真的到了详情页，且标签区真的渲染出可点的标签 —— 判据本身必须
    // 有承载物，否则后面的提示断言会在「压根没进详情页」时假通过。
    expect(find.widgetWithText(AppBar, '@alice'), findsOneWidget,
        reason: '前置③：必须已经 push 到详情页');
    expect(find.text('自拍'), findsOneWidget,
        reason: '前置④：标签区必须真的渲染出可点标签（靠 fav_list.dart 透传 api）');

    final pathsBefore = List<String>.from(adapter.paths);
    await tester.tap(find.text('自拍'));
    await settle(tester);

    // 契约本体：收藏页背后没有列表页可递回 → 不就地切，**但必须说清楚**。
    expect(find.textContaining('不支持标签就地查看'), findsOneWidget,
        reason: '「点了没反应」与「跳转失败」用户分不出来；入口保留就必须有反馈');

    // 反向断言 A：没有偷偷把详情页 pop 掉。若将来有人「顺手补齐传参」但只 pop，
    // 这条会红（pop 后 AppBar 与标签区都不在了）。
    expect(find.widgetWithText(AppBar, '@alice'), findsOneWidget,
        reason: '不能就地切时就不该 pop：pop 完用户回到收藏页且看不到任何结果');

    // 反向断言 B：不能靠「把标签查找再做一份在收藏页」来骗过提示。
    // 那是 tag_browse.dart 开头明确否掉的方案（同一件事两份实现必然漂移）。
    final newPaths = adapter.paths.skip(pathsBefore.length);
    expect(newPaths.where((p) => p.contains('/api/tag')), isEmpty,
        reason: '收藏页绝不能自己去拉标签反查：那份实现在用户列表页，重复必然漂移');
  });
}