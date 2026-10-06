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
      // 首屏 `GET /?list=users`（注意 path 就是 `/`，不带 /api/twitter——
      // twitter_api.dart:207）。回**空数组**：这一档要的是列表形态，
      // 回 `{}` 会让 _decodeUserList 抛 UnexpectedResponseException，
      // 于是 _error 永久非空、后续分支全部走不到。
      // （与 tag_rule_consistency_test.dart:85 同一个坑。）
      '/': jsonEncode(<dynamic>[]),
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
    // 诊断：把实际渲染出来的文本与请求路径打出来，别再靠猜。
    // eslint 意义上这是「失败时给出可行动信息」——前几轮我连猜三次都错，
    // 就是因为报错只说「没找到 @user0」，看不出到底渲染出了什么。
    final rendered = tester.widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .where((d) => d != null && d.isNotEmpty)
        .toList();
    final selectable = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((t) => t.data)
        .toList();
    final paths = adapter.seen.map((u) => '${u.path}?${u.query}').toList();
    fail('诊断：\n错误文本=$selectable\n渲染文本=${rendered.take(25).toList()}\n'
        '请求=${paths.take(15).toList()}\n'
        '已注册路由=${adapter.routes.keys.toList()}');
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
}
