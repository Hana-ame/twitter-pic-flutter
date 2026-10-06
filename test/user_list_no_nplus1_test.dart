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
  late TwitterApi api;

  final names = List<String>.generate(25, (i) => 'user$i');

  setUp(() {
    adapter = _RouteAdapter(<String, Object>{
      '/api/tag/女性': _tagPage(names),
      '/api/tags': jsonEncode(<String, dynamic>{
        for (final n in names) n: <String, int>{'女性': 1},
      }),
      '/api/twitter/users': jsonEncode(<dynamic>[]),
      for (final n in names) '/api/twitter/$n.json.gz': _metaFor(n),
    });
    api = TwitterApi(adapter: adapter);
  });

  // TwitterApi 的元数据缓存是 static 全实例共享，必须重置，否则跨文件串味。
  tearDown(() {
    api.dispose();
    TwitterApi.resetForTests();
    StorageService.resetForTests();
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('标签页每行不再单独拉元数据（N+1 消除）', (tester) async {
    // 先把标签页的数据喂到位：hydrateUsernames 已经把元数据取回来了。
    final hydrated = await api.hydrateUsernames(names);
    expect(hydrated.length, 25);
    expect(hydrated.every((u) => u.nick != null && u.nick!.isNotEmpty), isTrue,
        reason: '前置：hydrateUsernames 必须真的取到了昵称，否则本用例是空转');

    // 记住 hydrate 阶段的请求数，作为基线。
    final afterHydrate = adapter.seen.length;

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: UserListScreen(proxy: ProxyManager(), api: api))));
    await settle(tester);

    // 再点进标签筛选，走标签页那条路。
    await tester.tap(find.text('女性').first);
    await settle(tester);

    final metaAfterTag = names.fold<int>(
        0, (sum, n) => sum + adapter.metaRequestsFor(n));

    // 判据：**渲染列表行不应该新增任何**逐账号元数据请求。
    expect(metaAfterTag, lessThanOrEqualTo(afterHydrate),
        reason: '标签页渲染新增了 $metaAfterTag 次逐账号元数据请求；'
            '这些数据 hydrateUsernames 已经取过，逐行重拉就是每页多 25 次往返，'
            '而失败的那些（404）因为不进缓存会被反复重打。');

    // 反向断言：确实**渲染出了**这些行（否则上面的断言会空转——整页没渲染
    // 当然也就没有请求，这正是「findsNothing 也算通过」的坑）。
    expect(find.text('@user0'), findsOneWidget);
    expect(find.text('昵称-user0'), findsOneWidget);
  });
}