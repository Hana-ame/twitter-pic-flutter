// 「标签页不该为每个账号发一次元数据请求」的回归测试。
//
// ## 这组测试拦的是哪条真实故障（2026-10-06 实测线上）
//
// 用户报「筛选 tag 后有大量查询失败」（点名 `vivi1213813` 点进去就 404）
// 与「并且下一页极慢」。实测：
//
//     GET /api/tag/女性?limit=25&offset=0 → 200, users=25, total=7594
//     GET /api/tags?keys=<同 25 人>       → 200，25 人全在（一个不缺）
//     把这 25 人逐个 GET /api/twitter/<u>.json.gz
//       → 200: 12   404: 13        （404 体固定「查询用户失败: 没有进入 rows.Next()」）
//       → 25 次**串行**累计 30.1s
//
// 客户端这边，**一半的请求注定失败**，而「注定失败的请求」特别致命：
// `getMetaData` 的缓存只存成功结果，404 会走 catch 把缓存条目 remove 掉
// （`twitter_api.dart`「失败不进缓存，下次调用重试」），于是每一次重建列表
// 都会把同一批 404 **再打一遍**。这就是「下一页极慢」——不是并发度不够，
// 而是发起了大量不可能成功的请求。
//
// ## 本文件钉住的那条客户端契约
//
// 列表行**复用**上游已经取好的元数据，不自己再拉一遍。
//
// 改之前 `_visibleUsers` 本来就是 `List<TwitterUser>`，`hydrateUsernames`
// 已经把 nick/avatar/totalUrls 都填好了，但调用方只把 `u.username` 传下去，
// 于是 `_UserTile.initState` 又发一次 `getMetaData` —— 一页 25 行就是 25 次
// **重复**请求（叠加上游那 25 次，每页 50 次）。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/services/proxy_manager.dart';
import 'package:twitter_pic_flutter/api/twitter_api.dart';
import 'package:twitter_pic_flutter/screens/user_list_screen.dart';
import 'package:twitter_pic_flutter/services/storage_service.dart';
import 'package:twitter_pic_flutter/widgets/proxy_avatar.dart';

String _canonPath(String p) {
  try {
    return Uri.decodeFull(p);
  } catch (_) {
    return p;
  }
}

class _RouteAdapter implements HttpClientAdapter {
  final Map<String, Object> routes;
  final List<Uri> seen = <Uri>[];

  _RouteAdapter(this.routes);

  /// 该用户名被单独拉过元数据的次数（用来证明 N+1 消失）。
  int metaRequestsFor(String name) =>
      seen.where((u) => u.path.contains('/api/twitter/$name.json.gz')).length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    seen.add(uri);
    // ⚠️ path `/` 有歧义：首屏是 `GET /?list=users`，而标签页是
    // `GET /api/tag/女性`——后者的 path 不是 `/`，两者不会撞。
    // 但同一 path 可能带不同 query（?list=users / ?after=…），按 path 查表即可，
    // 两者都要空数组。
    final entry = routes[_canonPath(uri.path)];
    final String body;
    if (entry == null) {
      body = '{"error":"no route registered for ${uri.path}"}';
    } else if (entry is String) {
      body = entry;
    } else {
      body = jsonEncode(entry);
    }
    return ResponseBody.fromString(
      body,
      entry == null ? 500 : 200,
      headers: {
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

String _tagPage(List<String> names, {int total = 100}) =>
    jsonEncode({'count': names.length, 'total': total, 'users': names});

String _metaFor(String name, {String? nick}) => jsonEncode({
      'total_urls': 3,
      'timeline': <dynamic>[],
      'account_info': <String, dynamic>{
        'name': name,
        'nick': nick ?? '昵称-$name',
        'profile_image': 'https://example.test/$name.jpg',
      },
    });

void main() {
  late _RouteAdapter adapter;

  final names = List<String>.generate(25, (i) => 'user$i');

  setUp(() {
    adapter = _RouteAdapter(<String, Object>{
      '/api/tag/女性': _tagPage(names),
      '/api/tags': jsonEncode(<String, dynamic>{
        for (final n in names) n: <String, int>{'女性': 1},
      }),
      // 标签栏的数据源。没有它，标签栏是空的，下面 tap('女性') 找不到目标。
      '/api/tag-cloud': jsonEncode(<dynamic>[
        {'Tag': '女性', 'Count': 100},
        {'Tag': '自拍', 'Count': 80},
      ]),
      // 首屏 `GET /?list=users`。注意**最终 path 是 `/api/twitter/`**：
      // `getUserList` 传的 path 是 `'/'`（twitter_api.dart:207），但 Dio 的
      // baseUrl 是 `kApiBase = '.../api/twitter'`（:19），拼出来是
      // `/api/twitter/` + 空 path = `/api/twitter/`。
      //
      // 我上一轮按「path 就是 `/`」只注册了 `/`，于是这条请求 500，
      // `_error` 永久非空 → `_buildDefaultList` 的第三分支
      // （`_selectedTags.isNotEmpty` → 标签结果）**根本走不到**，
      // 症状跑到「没渲染出行」上，与真因隔了三层。
      //
      // 回**空数组**而不是 `{}`：这一档要的是列表形态，回对象会抛
      // UnexpectedResponseException（与 tag_rule_consistency_test.dart:85 同坑）。
      '/api/twitter/': jsonEncode(<dynamic>[]),
      for (final n in names) '/api/twitter/$n.json.gz': _metaFor(n),
    });
  });

  // TwitterApi 的元数据缓存是 static 全实例共享，必须重置，否则跨文件串味。
  tearDown(() {
    TwitterApi.resetForTests();
    StorageService.resetForTests();
  });

  /// 有界推进（**不用** `pumpAndSettle`：默认列表的 `_SkeletonCircle` 是
  /// `AnimationController..repeat(reverse: true)` 常驻动画，`pumpAndSettle`
  /// 永远等不到「无待处理帧」，会一直转到超时）。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
  }

  testWidgets('标签页每行不再单独拉元数据（N+1 消除）', (tester) async {
    // api 建在**用例体内**（不是 setUp），dispose 交给 addTearDown：
    // 与 add_user_flow_test.dart / tag_rule_consistency_test.dart 保持同一结构。
    //
    // ⚠️ 本文件**不在 pumpWidget 之前 await 任何真实 future**。
    // `hydrateUsernames` 会 await 一串 Dio 请求，而 `flutter_test` 用**假异步
    // 时钟**：pump 之前挂着的未完成任务会让框架判定「测试没结束」，
    // 整包跑到 `TimeoutException after 0:10:00`——而**逐文件跑却全绿**，
    // 两者结论相反，只能靠整包闸门抓到。
    // 见 KB facts-flutter-test-whole-suite-hangs-while-per-file-passes。
    //
    // 所以 hydrate 不在这里手动调：它由 UserListScreen 自己在 pump 周期里驱动。
    final api = TwitterApi(adapter: adapter);
    addTearDown(api.dispose);

    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: UserListScreen(proxy: ProxyManager(), api: api))));
    await settle(tester);

    // 选标签，走标签反查那条路。
    //
    // 用 find.descendant(of: ListView) 限定作用域，与 tag_rule_consistency_test
    // 一致：`女性` 这个字符串在标签栏、结果区等多处都会出现，裸
    // find.text(...).first 可能点中一个不可点的静态 Text。
    await tester.tap(find.descendant(
      of: find.byType(ListView),
      matching: find.text('女性'),
    ));
    await settle(tester);

    // 前置 + 反向断言：**行确实渲染出来了**。没有这两条，后面的
    // 「请求数不增加」会在「整页啥都没渲染」时假通过——
    // 这正是 findsNothing 也算通过的坑。
    expect(find.text('@user0'), findsOneWidget,
        reason: '前置：标签页必须真的渲染出这些行，否则请求数断言是空转');
    expect(find.text('昵称-user0'), findsOneWidget,
        reason: '前置：必须用 hydrateUsernames 取回的昵称渲染，而不是退化成用户名');

    // 判据：**每个账号的元数据至多被拉一次**。
    //
    // 改之前：hydrateUsernames 拉一遍（25 次）+ 每行 _UserTile.initState 再拉一遍
    // （25 次）= 每个账号 2 次。改之后每行直接复用上游数据，只有 1 次。
    for (final n in names) {
      expect(adapter.metaRequestsFor(n), lessThanOrEqualTo(1),
          reason: '$n 的元数据被拉了 ${adapter.metaRequestsFor(n)} 次；'
              '超过 1 次说明列表行在重复拉上游已经取好的数据。');
    }

    // 总量判据：25 个账号，逐行重拉会变成 ~50 次。
    final total = names.fold<int>(0, (a, n) => a + adapter.metaRequestsFor(n));
    expect(total, lessThanOrEqualTo(names.length),
        reason: '逐账号元数据请求共 $total 次，超过人数上限 ${names.length} '
            '说明仍有逐行重复拉取。');
  });

  // 2026-10-06 回归：N+1 那条 commit（f80cd94）顺手把 `_adopt()` 写成
  // `accountInfo: u`，于是首屏**完全不加载任何头像**。见下方长注释。
  testWidgets('复用上游对象时头像不能丢（首屏头像回归）', (tester) async {
    final api = TwitterApi(adapter: adapter);
    addTearDown(api.dispose);

    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: UserListScreen(proxy: ProxyManager(), api: api))));
    await settle(tester);

    // ⚠️ 这条断言的根据是 `_metaFor` 给了 `profile_image`，而
    // **`/?list=users` 那个路由返回的是空数组**——所以首屏本来就没有行。
    // 于是这里必须切到标签页才有行可断言（标签页走 hydrate，头像有来源）。
    await tester.tap(find.descendant(
      of: find.byType(ListView),
      matching: find.text('女性'),
    ));
    await settle(tester);

    // 前置：行确实渲染了。否则下面的头像断言会在「整页没渲染」时假通过。
    expect(find.text('@user0'), findsOneWidget,
        reason: '前置：必须先有行渲染，否则头像断言是空转');

    // 判据：头像用的是 `profile_image` 的 URL，不是首字母占位。
    //
    // 修之前的 `accountInfo: u` 之所以丢头像：`u` 来自 hydrate 时**确实**
    // 带了 avatar，但 `_adopt` 把整个对象当 accountInfo 用，而
    // `UserMetaData` 是从 `account_info` 这个 **Map** 建的——从对象直接塞进去
    // 就绕过了「字段齐全」这个前提。首屏那种「u 由 list=users 构造、
    // 压根没有 avatar 键」的情况于是全渲染成占位。
    final avatars = tester
        .widgetList<ProxyAvatar>(find.byType(ProxyAvatar))
        .map((a) => a.url)
        .toList();
    expect(avatars, isNotEmpty, reason: '前置：页面上必须真的有 ProxyAvatar 节点');
    for (final url in avatars) {
      expect(url, isNotNull,
          reason: 'ProxyAvatar.url 为 null ⇒ 该行渲染的是首字母占位，不是真头像');
      expect(url, contains('example.test'),
          reason: '头像 URL 期望来自 _metaFor 的 profile_image，实际是 $url');
    }
  });

  // 2026-10-06 用户报「首页、搜索页的 list 依然只有 id，没有头像和昵称」。
  // 上面那条「复用上游对象时头像不能丢」只测了**标签路径**（tap 女性）——
  // 首页默认列表路径当时完全是裸的：`getUserList` 只返
  // `username/last_modify/tags/status`，没有昵称/头像，而列表行直接把它
  // 渲染出来（`_adopt` 拷贝的也是 null）。
  //
  // 修法在**数据进列表前**统一 hydrate：`_hydrateListUsers` 对
  // `getUserList`/搜索的裸结果调 `hydrateUsernames`（每账号一次元数据请求，
  // 补上昵称/头像），行内 `_adopt` 直接复用、零请求。本用例钉住的是：
  //  ① 首页默认列表**真的渲染出昵称**（而不是退化成用户名）；
  //  ② 头像 URL 非 null（用 profile_image，不是首字母占位）；
  //  ③ 每账号元数据请求 ≤ 1 次 —— hydrate 是列表层一次，行内不重复。
  testWidgets('首页默认列表：hydrate 后昵称与头像都渲染，且每账号只请求一次',
      (tester) async {
    // 裸用户列表：只带 username/status/tags，**没有 nick/avatar 键**
    // （线上实测 /?list=users 的 keys 就是这四个）。
    final bareUsers = jsonEncode(<dynamic>[
      for (final n in names)
        <String, dynamic>{
          'username': n,
          'last_modify': '2026-10-06T00:00:00Z',
          'tags': <String, int>{},
          'status': 'SUCCESS',
        },
    ]);
    final homeAdapter = _RouteAdapter(<String, Object>{
      // 首页第一屏就是这条：裸用户列表。
      '/api/twitter/': bareUsers,
      // hydrate 会打权重批量（getTagWeightsBatch）与每账号元数据。
      '/api/tags': jsonEncode(<String, dynamic>{
        for (final n in names) n: <String, int>{'女性': 1},
      }),
      for (final n in names) '/api/twitter/$n.json.gz': _metaFor(n),
      // 标签栏数据源（UserListScreen 启动时会拉 tag-cloud）。
      '/api/tag-cloud': jsonEncode(<dynamic>[
        {'Tag': '女性', 'Count': 100},
        {'Tag': '自拍', 'Count': 80},
      ]),
    });
    final api = TwitterApi(adapter: homeAdapter);
    addTearDown(api.dispose);

    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: UserListScreen(proxy: ProxyManager(), api: api))));
    await settle(tester);

    // 前置：默认列表真的渲染出这些行。
    expect(find.text('@user0'), findsOneWidget,
        reason: '前置：首页默认列表必须渲染出 user0 这一行');
    expect(find.text('昵称-user0'), findsOneWidget,
        reason: '判据①：昵称必须来自 hydrate（_metaFor 的 nick），'
            '不能退化成只显示用户名 —— 用户报的就是这个');

    // 判据②：头像 URL 来自 profile_image，非 null（不是首字母占位）。
    final avatars = tester
        .widgetList<ProxyAvatar>(find.byType(ProxyAvatar))
        .map((a) => a.url)
        .toList();
    expect(avatars, isNotEmpty, reason: '前置：首页必须真的有 ProxyAvatar 节点');
    for (final url in avatars) {
      expect(url, isNotNull,
          reason: 'ProxyAvatar.url 为 null ⇒ 首页渲染的是占位，不是真头像（用户报的症状）');
      expect(url, contains('example.test'),
          reason: '首页头像 URL 应来自 _metaFor 的 profile_image，实际是 $url');
    }

    // 判据③：每账号元数据至多一次 —— hydrate 在列表层收起，行内不再拉。
    for (final n in names) {
      final hits = homeAdapter.metaRequestsFor(n);
      expect(hits, lessThanOrEqualTo(1),
          reason: '默认列表里 $n 被拉了 $hits 次元数据；'
              '超过 1 次说明列表行在 hydrate 之外又重复拉（N+1 复活）');
    }
  });
}
