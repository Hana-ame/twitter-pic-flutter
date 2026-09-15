// 搜索合并与 tag 模式的回归测试。
//
// 覆盖三层：
//   1. mergeSearchResults 纯函数：三路（username > nick > tag）优先级拼接、
//      按 username 保序去重、路内保持服务端顺序；
//   2. runMergedSearch：逐项吞错（单路失败不影响其余路）+ 失败计数/首个异常，
//      供 UI 区分「出错 / 部分失败 / 真·空」；
//   3. widget 级：`#词` 语法只走 tag 路、tag 模式下隐藏"添加此用户"、
//      200+null（旧服务端不认识 by=tag）必须渲染成错误态而不是空列表、
//      TagUserListScreen 的三态与截断说明。
//
// 网络全部走假适配器（骨架仿 api_url_test.dart / fav_list_test.dart），
// 不发真实请求；setUp/tearDown 成对调 TwitterApi.resetForTests() 隔离静态缓存。

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:twitter_pic_flutter/api/twitter_api.dart';
import 'package:twitter_pic_flutter/models/user.dart';
import 'package:twitter_pic_flutter/screens/tag_user_list_screen.dart';
import 'package:twitter_pic_flutter/screens/user_list_screen.dart';
import 'package:twitter_pic_flutter/services/proxy_manager.dart';
import 'package:twitter_pic_flutter/services/storage_service.dart';

TwitterUser u(String username) => TwitterUser(username: username);

// ─── 假适配器：按 query 参数 by= 路由不同的响应体 ────────────────────────────

class _ByRouteAdapter implements HttpClientAdapter {
  /// key = `by` 参数值（username / nick / tag），value = 响应体。
  /// 特殊值 'null' 会让 Dio 解出 `null`，模拟线上旧二进制对未知 by 的
  /// `200 + body null`。未配置的路由回退 '[]'。
  final Map<String, String> by;
  final List<RequestOptions> seen = <RequestOptions>[];

  _ByRouteAdapter({this.by = const <String, String>{}});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    final key = options.uri.queryParameters['by'];
    final String body;
    if (key != null && by.containsKey(key)) {
      body = by[key]!;
    } else if (options.uri.path.endsWith('.json.gz')) {
      body = '{}'; // getMetaData：可解析的空对象（模型容错走占位路径）
    } else {
      body = '[]';
    }
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);

  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

/// 输入搜索词并越过 300ms 防抖 + 若干轮假异步网络。
/// 不用 pumpAndSettle：结果未出前页面上有无限动画（骨架圆点 repeat），
/// pumpAndSettle 会永转。
Future<void> _typeAndSettle(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).first, text);
  await tester.pump(const Duration(milliseconds: 400)); // 触发防抖 + 起请求
  await tester.pump(const Duration(milliseconds: 100)); // FutureBuilder 落结果
  await tester.pump(const Duration(milliseconds: 100)); // 每行 getMetaData 落结果
  await tester.pump(const Duration(milliseconds: 100)); // 再落一次 setState
}

void main() {
  group('mergeSearchResults（纯函数：优先级拼接 + 按 username 保序去重）', () {
    test('三路顺序固定 username > nick > tag，跨路按 username 去重首次胜出', () {
      final merged = mergeSearchResults([
        [u('alice'), u('bob')],           // username 路
        [u('carol'), u('alice')],         // nick 路：alice 重复 → 丢弃
        [u('dave'), u('bob'), u('eve')],  // tag 路：bob 重复 → 丢弃
      ]);
      expect(merged.map((e) => e.username).toList(),
          <String>['alice', 'bob', 'carol', 'dave', 'eve']);
    });

    test('同一路内部保持服务端返回顺序（tag 路权重降序不被重排）', () {
      final merged = mergeSearchResults([
        <TwitterUser>[],
        <TwitterUser>[],
        [u('heavy'), u('light')],
      ]);
      expect(merged.map((e) => e.username).toList(),
          <String>['heavy', 'light']);
    });

    test('单路退化（tag 模式等价于单路合并）仍去重', () {
      final merged = mergeSearchResults([
        [u('a'), u('a'), u('b')],
      ]);
      expect(merged.map((e) => e.username).toList(), <String>['a', 'b']);
    });

    test('空输入：零路 / 全空路 → 空结果', () {
      expect(mergeSearchResults([]), isEmpty);
      expect(mergeSearchResults([<TwitterUser>[], <TwitterUser>[]]), isEmpty);
    });
  });

  group('runMergedSearch（并发 + 逐项吞错 + 失败计数）', () {
    test('单路失败只置空该路，其余路照常合并；partialFailure=true', () async {
      final r = await runMergedSearch([
        Future.value([u('alice')]),
        Future.error(const UnexpectedResponseException('body null')),
        Future.value([u('carol'), u('alice')]),
      ]);
      expect(r.users.map((e) => e.username).toList(),
          <String>['alice', 'carol']);
      expect(r.totalRoutes, 3);
      expect(r.failedRoutes, 1);
      expect(r.partialFailure, isTrue);
      expect(r.allRoutesFailed, isFalse);
      expect(r.firstError, isA<UnexpectedResponseException>());
    });

    test('全部路失败 → users 空但 allRoutesFailed=true（UI 必须显示错误态）', () async {
      final r = await runMergedSearch([
        Future.error(Exception('r1-fail')),
        Future.error(Exception('r2-fail')),
        Future.error(Exception('r3-fail')),
      ]);
      expect(r.users, isEmpty);
      expect(r.allRoutesFailed, isTrue);
      expect(r.partialFailure, isFalse);
      // firstError 取路优先级最靠前的失败路的异常。
      expect('${r.firstError}', contains('r1-fail'));
    });

    test('firstError 按路顺序取最靠前的失败路', () async {
      final r = await runMergedSearch([
        Future.value([u('a')]),
        Future.error(Exception('nick-fail')),
        Future.error(Exception('tag-fail')),
      ]);
      expect('${r.firstError}', contains('nick-fail'));
      expect(r.failedRoutes, 2);
    });

    test('全部成功 → 无失败信息', () async {
      final r = await runMergedSearch([
        Future.value([u('alice')]),
        Future.value([u('bob')]),
        Future.value([u('carol')]),
      ]);
      expect(r.failedRoutes, 0);
      expect(r.firstError, isNull);
      expect(r.allRoutesFailed, isFalse);
      expect(r.partialFailure, isFalse);
      expect(r.users.map((e) => e.username).toList(),
          <String>['alice', 'bob', 'carol']);
    });

    test('username 路失败时，nick 命中仍排在 tag 命中前（优先级由路序决定）', () async {
      final r = await runMergedSearch([
        Future.error(Exception('down')),
        Future.value([u('from-nick')]),
        Future.value([u('from-tag')]),
      ]);
      expect(r.users.map((e) => e.username).toList(),
          <String>['from-nick', 'from-tag']);
    });
  });

  group('UserListScreen `#` 语法（tag 模式三态）', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('search_merge_test');
      PathProviderPlatform.instance = _FakePathProvider(tmp.path);
      StorageService.resetForTests();
      TwitterApi.resetForTests();
      await StorageService.ensureInitialized();
    });

    tearDown(() async {
      StorageService.resetForTests();
      TwitterApi.resetForTests();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Widget host(TwitterApi api, ProxyManager proxy) => MaterialApp(
          home: Scaffold(body: UserListScreen(proxy: proxy, api: api)),
        );

    testWidgets('#词只走 tag 路，且隐藏"添加此用户"', (tester) async {
      final adapter = _ByRouteAdapter(by: {
        'tag': '[{"username":"alice","tags":{"自拍":3}}]',
      });
      final api = TwitterApi(adapter: adapter);
      await tester.pumpWidget(host(api, ProxyManager()));
      await tester.pump(const Duration(milliseconds: 100));

      await _typeAndSettle(tester, '#自拍');

      // 只发出 by=tag 一路搜索（不是三路）。
      final searchReqs = adapter.seen
          .where((o) => o.uri.queryParameters['by'] != null)
          .toList();
      expect(searchReqs.length, 1);
      expect(searchReqs.single.uri.queryParameters['by'], 'tag');
      expect(searchReqs.single.uri.queryParameters['search'], '自拍');
      // 结果渲染，且 tag 模式下没有"添加 @自拍"tile。
      expect(find.text('@alice'), findsOneWidget);
      expect(find.textContaining('添加 @'), findsNothing);
      api.dispose();
    });

    testWidgets('旧服务端 200+null → 错误态，而不是"没有用户命中"', (tester) async {
      final adapter = _ByRouteAdapter(by: {'tag': 'null'});
      final api = TwitterApi(adapter: adapter);
      await tester.pumpWidget(host(api, ProxyManager()));
      await tester.pump(const Duration(milliseconds: 100));

      await _typeAndSettle(tester, '#自拍');

      expect(find.text('标签搜索失败：服务端可能未就绪'), findsOneWidget);
      expect(find.text('该标签下没有用户命中'), findsNothing);
      expect(find.textContaining('添加 @'), findsNothing);
      api.dispose();
    });

    testWidgets('200+[] 是真·空结果：显示空态而非错误', (tester) async {
      final adapter = _ByRouteAdapter(by: {'tag': '[]'});
      final api = TwitterApi(adapter: adapter);
      await tester.pumpWidget(host(api, ProxyManager()));
      await tester.pump(const Duration(milliseconds: 100));

      await _typeAndSettle(tester, '#不存在');

      expect(find.text('该标签下没有用户命中'), findsOneWidget);
      expect(find.textContaining('标签搜索失败'), findsNothing);
      api.dispose();
    });

    testWidgets('普通三路：tag 路失败被吞、结果照常 + 部分失败横幅', (tester) async {
      final adapter = _ByRouteAdapter(by: {
        'username': '[{"username":"alice"}]',
        'nick': 'null', // 模拟旧二进制不认识 by=nick? 一样被吞成空路
        'tag': 'null',
      });
      final api = TwitterApi(adapter: adapter);
      await tester.pumpWidget(host(api, ProxyManager()));
      await tester.pump(const Duration(milliseconds: 100));

      await _typeAndSettle(tester, 'alice');

      expect(find.text('@alice'), findsOneWidget);
      expect(find.text('添加 @alice'), findsOneWidget); // 非 tag 模式保留
      expect(find.textContaining('部分搜索失败（2/3 路）'), findsOneWidget);
      api.dispose();
    });

    testWidgets('普通三路全挂 → 错误态而非空结果', (tester) async {
      final adapter = _ByRouteAdapter(by: {
        'username': 'null',
        'nick': 'null',
        'tag': 'null',
      });
      final api = TwitterApi(adapter: adapter);
      await tester.pumpWidget(host(api, ProxyManager()));
      await tester.pump(const Duration(milliseconds: 100));

      await _typeAndSettle(tester, 'alice');

      expect(find.text('搜索失败'), findsOneWidget);
      expect(find.text('没有匹配的用户'), findsNothing);
      api.dispose();
    });

    testWidgets('只输入 # 不发请求，退回默认列表', (tester) async {
      final adapter = _ByRouteAdapter(by: {'tag': 'null'});
      final api = TwitterApi(adapter: adapter);
      await tester.pumpWidget(host(api, ProxyManager()));
      await tester.pump(const Duration(milliseconds: 100));

      await _typeAndSettle(tester, '#');

      expect(
        adapter.seen
            .where((o) => o.uri.queryParameters['by'] != null)
            .toList(),
        isEmpty,
      );
      expect(find.text('还没有用户'), findsOneWidget); // 默认列表空态
      api.dispose();
    });
  });

  group('TagUserListScreen', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('search_merge_test_tag');
      PathProviderPlatform.instance = _FakePathProvider(tmp.path);
      StorageService.resetForTests();
      TwitterApi.resetForTests();
      await StorageService.ensureInitialized();
    });

    tearDown(() async {
      StorageService.resetForTests();
      TwitterApi.resetForTests();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Widget host(String tag, TwitterApi api, void Function(UserMetaData) onSelect) =>
        MaterialApp(
          home: TagUserListScreen(
            tag: tag,
            api: api,
            proxy: ProxyManager(),
            onSelectUser: onSelect,
          ),
        );

    testWidgets('200+null → 错误态；重试可再发请求', (tester) async {
      final adapter = _ByRouteAdapter(by: {'tag': 'null'});
      final api = TwitterApi(adapter: adapter);
      await tester.pumpWidget(host('自拍', api, (_) {}));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('标签用户加载失败：服务端可能未就绪'), findsOneWidget);
      expect(find.textContaining('没有用户命中'), findsNothing);

      final tagReqsBefore =
          adapter.seen.where((o) => o.uri.queryParameters['by'] == 'tag').length;
      await tester.tap(find.text('重试'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      final tagReqsAfter =
          adapter.seen.where((o) => o.uri.queryParameters['by'] == 'tag').length;
      expect(tagReqsAfter, greaterThan(tagReqsBefore));
      api.dispose();
    });

    testWidgets('传入带 # 的标签会被归一化后精确查询', (tester) async {
      final adapter = _ByRouteAdapter(by: {'tag': '[]'});
      final api = TwitterApi(adapter: adapter);
      await tester.pumpWidget(host('#自拍', api, (_) {}));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      final req = adapter.seen
          .firstWhere((o) => o.uri.queryParameters['by'] == 'tag');
      expect(req.uri.queryParameters['search'], '自拍');
      expect(find.textContaining('没有用户命中'), findsOneWidget);
      api.dispose();
    });

    testWidgets('命中列表：用户行显示命中标签；满 15 个如实标注截断且无加载更多',
        (tester) async {
      final users = <String>[
        for (var i = 1; i <= kTagSearchLimit; i++)
          '{"username":"u$i","tags":{"自拍":${kTagSearchLimit - i}}}',
      ].join(',');
      final adapter = _ByRouteAdapter(by: {'tag': '[$users]'});
      final api = TwitterApi(adapter: adapter);
      UserMetaData? selected;
      await tester.pumpWidget(host('自拍', api, (m) => selected = m));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('@u1'), findsOneWidget);
      expect(find.text('#自拍'), findsWidgets); // 至少首行的命中标签 chip
      // 没有任何"加载更多"按钮。
      expect(find.text('加载更多'), findsNothing);

      // 点用户 → 外注回调收到已拉好的 UserMetaData。
      // （必须在 scrollUntilVisible 之前：ListView 懒建，滚到尾部后 u2 行会被回收。）
      await tester.tap(find.text('@u2'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(selected, isNotNull);

      await tester.scrollUntilVisible(
        find.textContaining('已达服务端返回上限'),
        100,
      );
      expect(find.textContaining('其余命中已被截断'), findsOneWidget);
      api.dispose();
    });
  });
}
