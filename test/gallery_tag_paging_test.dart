// 「标签反查全量 + 翻页」的路由与分页判据测试。
//
// ## 这组测试拦的是哪条真实故障（2026-10-05 实测线上）
//
// 标签反查端点注册在 **gallery 自己的 http.ServeMux** 上（go/gallery/main.go
// 的 `galleryMux`：`GET /api/tag/{tag}`、`GET /api/tag-cloud`、`GET /api/tags`），
// 而根 API 是 gin 的 `r.Group("/api/twitter")`（go/server/main.go）。两者不是
// 一个 base：`setupRouter` 只用 `r.NoRoute` 把 API 之外的路径交回 gallery。
//
// 原实现把图站端点挂在了 [kApiBase] 下，于是：
// ```
// GET /api/twitter/tag/<tag>   → 404 {"error":"page not found"}
// GET /api/twitter/tag-cloud   → 404 {"error":"查询用户失败: 没有进入 rows.Next()"}
// GET /api/tag/<tag>           → 200 {"count":25,"total":7580,"users":[...]}
// GET /api/tag-cloud           → 200 [{"Tag":"女性","Count":7580}, ...]
// ```
// 表现是「标签筛选条永远是空的 / 一选标签就报错」——**静默 404**，因为 UI 那层
// 把标签云加载失败直接 catch 掉不提示（"标签云挂了就当没有筛选条"）。
//
// ## 钉住的每一条都是可证伪的行为契约
//
//  1. **图站端点的绝对路径不带 `/api/twitter`**（根 API 的仍在）——路由判据。
//  2. 标签名必须百分号编码（中文标签不进 URL 原文）。
//  3. 翻页**只发 `offset`**，不发 `page`（服务端 `page` 是摆设，见下面）。
//  4. `TagUserPage.isLastPage` 的判定口径：条数 < 请求 limit 即末页。
//  5. 批量权重 `GET /api/tags?keys=a,b,c` 一次拿整页，且**未知键回落空表**
//     （服务端把被封账号直接从 map 里省略，不是报错）。
//  6. `hydrateUsernames` 去重后再发请求，不因重复键多花往返。
//
// ## 为什么不测「真的翻到底」
//
// 那是集成测试，既慢又不稳定（线上有并发写入，total 每次都在动）。这里的
// 分页判据用**构造的响应**逐页喂进去，覆盖满页 / 短页 / 空页三种收口形态；
// 「服务端 offset 确实生效」这件事已由线上实测取证（offset=0…725 逐页拉过，
// 每页满 25 条、相邻页首尾不重叠），记在 [kGalleryBase] 与
// `TagsForTagPaged` 的注释里，不在本文件重复依赖网络。

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/api/twitter_api.dart';

/// 按路径回放预置响应，并记录每个请求的绝对 URI。
///
/// 路由（path 不含 host）→ body。未登记的 path 直接返回 500，这样"请求打错
/// 路径"会变成一次响亮的失败，而不是被某个宽松的默认响应吞掉。
///
/// body 可以是字符串，也可以是**按当次请求生成的函数** —— 翻页那组用例必须
/// 让同一个路径在不同 `offset` 下回不同的 `users`，否则"翻页不重复"这条断言
/// 是拿三份一模一样的数据自证的，等于没测。
/// 把路径统一成**解码形态**再查表。
///
/// 为什么要规范化：注册用的 key 是人写的解码形态（`/api/tag/女性`），而查表用的
/// 是 `Uri.path`。Dart 的 `Uri.path` 是**解码后**的路径，但适配器最终看到的是
/// Dio 交下来的 `options.uri`，其解码/编码形态不该成为这些用例的成败条件 ——
/// 否则同一个路由行为换个 Uri 语义就红。两侧都过一遍 [Uri.decodeFull]，
/// 两种形态都能对上。
String _canonPath(String p) {
  try {
    return Uri.decodeFull(p);
  } catch (_) {
    // 本来就是解码形态（含裸中文）时 decodeFull 无需处理，直接返回。
    return p;
  }
}

class _RouteAdapter implements HttpClientAdapter {
  /// body：`String` 固定响应，`String Function(Uri)` 按当次请求生成。
  final Map<String, Object> routes;
  final List<Uri> seen = <Uri>[];

  _RouteAdapter(this.routes);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    seen.add(uri);
    final entry = routes[_canonPath(uri.path)];
    final bool isFailure = entry == null;
    final String body;
    if (entry == null) {
      body = '{"error":"no route registered for ${uri.path}"}';
    } else if (entry is String) {
      body = entry;
    } else if (entry is String Function(Uri)) {
      body = entry(uri);
    } else {
      body = jsonEncode(entry);
    }
    return ResponseBody.fromString(
      body,
      isFailure ? 500 : 200,
      headers: {
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// 一页反查结果：`names` 按顺序给，total 固定。
String tagPage(List<String> names, {int total = 100}) =>
    jsonEncode({'count': names.length, 'total': total, 'users': names});

/// 一页的元数据（`account_info` 里**没有** tags —— 这是本次补齐的实测依据）。
String metaFor(String name, {String? nick}) => jsonEncode({
      'total_urls': 3,
      'timeline': <dynamic>[],
      'account_info': <String, dynamic>{
        'name': name,
        'nick': nick ?? '昵称-$name',
        'profile_image': 'https://example.test/$name.jpg',
      },
    });

/// 一批权重：`{name: {tag: weight}}`。未列出的用户名不在响应里（= 服务端
/// 把被封账号省略的那种形态）。
String weightsFor(Map<String, Map<String, int>> m) => jsonEncode(m);

void main() {
  late _RouteAdapter adapter;
  late TwitterApi api;

  setUp(() {
    adapter = _RouteAdapter(<String, Object>{});
    api = TwitterApi(adapter: adapter);
  });

  // TwitterApi 的元数据缓存是 static 全实例共享，必须重置，否则跨文件串味
  // （CI 有专门的闸门查「写了 static 却没 resetForTests」）。
  tearDown(() {
    api.dispose();
    TwitterApi.resetForTests();
  });

  group('图站端点的路由（不带 /api/twitter 前缀）', () {
    test('标签云打在站点 origin 的 /api/tag-cloud', () async {
      adapter.routes['/api/tag-cloud'] = '[{"Tag":"女性","Count":7580}]';
      final cloud = await api.getTagCloud(limit: 3);

      final uri = adapter.seen.single;
      expect(uri.scheme, 'https');
      expect(uri.host, 'x.moonchan.xyz');
      // path 里**绝不能**出现 /api/twitter，否则线上 404。
      expect(_canonPath(uri.path), '/api/tag-cloud');
      expect(_canonPath(uri.path), isNot(contains('/api/twitter')));
      expect(uri.queryParameters['limit'], '3');
      expect(cloud.single.tag, '女性');
      expect(cloud.single.count, 7580);
    });

    test('标签反查打在 /api/tag/<百分号编码后的标签>', () async {
      adapter.routes['/api/tag/女性'] = tagPage(['a', 'b'], total: 2);
      final page = await api.getUsersByTagPage('女性', limit: 2, offset: 0);

      final uri = adapter.seen.single;
      // 断言用解码形态（_canonPath），不依赖 Uri.path 是编码前还是编码后。
      expect(_canonPath(uri.path), '/api/tag/女性');
      expect(_canonPath(uri.path), isNot(contains('/api/twitter')));
      // 完整 URL 里中文必须是百分号编码，不能裸拼。
      expect(uri.toString(), contains('/api/tag/%E5%A5%B3%E6%80%A7'));
      expect(page.usernames, ['a', 'b']);
      expect(page.total, 2);
    });

    test('根 API 端点仍带 /api/twitter 前缀（两条 base 互不污染）', () async {
      adapter.routes['/api/twitter/'] = '[]';
      await api.getUserList();
      final uri = adapter.seen.single;
      expect(_canonPath(uri.path), '/api/twitter/');
      expect(uri.host, 'x.moonchan.xyz');
    });
  });

  group('翻页只用 offset（page 是摆设）', () {
    test('请求参数含 offset、不含 page', () async {
      adapter.routes['/api/tag/女性'] = tagPage(['a'], total: 100);
      await api.getUsersByTagPage('女性', limit: 1, offset: 50);

      final q = adapter.seen.single.queryParameters;
      expect(q['offset'], '50');
      expect(q['limit'], '1');
      // 实测服务端 page=1/2/3 回的数组一模一样（go/gallery/main.go 的
      // handleTagUsers 里 page 换算成 offset 后又被 offset 覆盖）。
      // 客户端发它只会误导下一个人以为两个参数都能翻页。
      expect(q.containsKey('page'), isFalse);
    });

    test('不同 offset 连续翻页，数据不重复也不丢失', () async {
      // 同一个路径按 offset 回放不同数据 —— 这才是真在验「offset 生效」。
      adapter.routes['/api/tag/女性'] = (Uri u) {
        final off = int.parse(u.queryParameters['offset']!);
        return tagPage(
          ['u$off', 'u${off + 1}', 'u${off + 2}'],
          total: 9,
        );
      };

      final collected = <String>[];
      for (var offset = 0; offset < 9; offset += 3) {
        final page = await api.getUsersByTagPage('女性', limit: 3, offset: offset);
        expect(page.offset, offset, reason: '页对象要记住自己的 offset，供上层续翻');
        collected.addAll(page.usernames);
      }

      expect(collected,
          ['u0', 'u1', 'u2', 'u3', 'u4', 'u5', 'u6', 'u7', 'u8']);
      expect(collected.toSet().length, 9, reason: '翻页不得产生重复用户');
    });

    test('空标签名不发请求（避免打服务端一个必然 400 的 URL）', () async {
      final page = await api.getUsersByTagPage('', limit: 25, offset: 0);
      expect(adapter.seen, isEmpty);
      expect(page.usernames, isEmpty);
      expect(page.total, isNull);
      // 空页恒为末页，否则 UI 的「加载更多」会永远亮着。
      expect(page.isLastPage(25), isTrue);
    });
  });

  group('isLastPage 的末页收口', () {
    test('满页 = 还有下一页', () async {
      adapter.routes['/api/tag/t'] = tagPage(['a', 'b'], total: 10);
      final page = await api.getUsersByTagPage('t', limit: 2, offset: 0);
      expect(page.isLastPage(2), isFalse);
    });

    test('短页 = 末页', () async {
      adapter.routes['/api/tag/t'] = tagPage(['a'], total: 10);
      final page = await api.getUsersByTagPage('t', limit: 2, offset: 0);
      expect(page.isLastPage(2), isTrue);
    });

    test('空页 = 末页（翻过 total 之后的兜底收口）', () async {
      adapter.routes['/api/tag/t'] = tagPage(const [], total: 10);
      final page = await api.getUsersByTagPage('t', limit: 25, offset: 999);
      expect(page.usernames, isEmpty);
      expect(page.isLastPage(25), isTrue);
    });

    test('响应缺 users 字段时给空页而不是抛异常', () async {
      // 降级形态：cfg.tags == nil 时服务端回 {"users":null,...}。
      adapter.routes['/api/tag/t'] = jsonEncode({'total': 0, 'users': null});
      final page = await api.getUsersByTagPage('t', limit: 25, offset: 0);
      expect(page.usernames, isEmpty);
      expect(page.isLastPage(25), isTrue);
    });
  });

  group('批量取权重（hydrate 的第一步）', () {
    test('一次请求拿整页 keys，不逐个发', () async {
      adapter.routes['/api/tags'] = weightsFor({
        'a': {'女性': 4},
        'b': {'女性': 1, '自拍': 2},
      });

      final w = await api.getTagWeightsBatch(['a', 'b']);

      expect(adapter.seen.length, 1);
      expect(adapter.seen.single.path, '/api/tags');
      expect(adapter.seen.single.queryParameters['keys'], 'a,b');
      expect(w['a'], {'女性': 4});
      expect(w['b'], {'女性': 1, '自拍': 2});
    });

    test('服务端省略的键（被封账号）回落空表，不抛异常', () async {
      // 实测 handleGetAccountTags 对被封 key 直接 continue，响应里就没有它。
      adapter.routes['/api/tags'] = weightsFor({'a': {'女性': 1}});
      final w = await api.getTagWeightsBatch(['a', 'banned']);
      expect(w.containsKey('a'), isTrue);
      expect(w['banned'], isNull);
    });

    test('空输入不发请求', () async {
      final w = await api.getTagWeightsBatch(const []);
      expect(adapter.seen, isEmpty);
      expect(w, isEmpty);
    });

    test('超过一批上限时按批切开，每批一个请求', () async {
      adapter.routes['/api/tags'] = weightsFor(const {});
      final names = List<String>.generate(120, (i) => 'u$i');
      await api.getTagWeightsBatch(names, chunk: 50);

      // 120 个 → 50 + 50 + 20 = 3 个请求（URL 长度有上限，不能一次全塞）。
      expect(adapter.seen.length, 3);
      expect(adapter.seen[0].queryParameters['keys']!.split(',').length, 50);
      expect(adapter.seen[2].queryParameters['keys']!.split(',').length, 20);
    });
  });

  group('hydrateUsernames：权重批量 + 元数据逐个', () {
    test('权重只发 1 个批量请求，元数据逐个发', () async {
      adapter.routes['/api/tags'] =
          weightsFor({'a': {'女性': 1}, 'b': {'女性': 3}});
      adapter.routes['/api/twitter/a.json.gz'] = metaFor('a', nick: '阿A');
      adapter.routes['/api/twitter/b.json.gz'] = metaFor('b', nick: '阿B');

      final users = await api.hydrateUsernames(['a', 'b']);

      expect(users.map((u) => u.username), ['a', 'b']);
      expect(users[0].nick, '阿A');
      expect(users[0].tags, {'女性': 1});
      expect(users[1].tags, {'女性': 3});

      // 请求账：1 次批量权重 + 2 次元数据 = 3。旧实现是每个用户名 2 次
      // （元数据 + getTagWeights），同样的输入要 4 次，一页 25 人就是 50 次。
      final weightsCalls =
          adapter.seen.where((u) => u.path == '/api/tags').length;
      final metaCalls = adapter.seen
          .where((u) => u.path.endsWith('.json.gz'))
          .length;
      expect(weightsCalls, 1);
      expect(metaCalls, 2);
      expect(adapter.seen.length, 3);
    });

    test('重复用户名只 hydrate 一次', () async {
      adapter.routes['/api/tags'] = weightsFor({'a': {'女性': 1}});
      adapter.routes['/api/twitter/a.json.gz'] = metaFor('a');

      final users = await api.hydrateUsernames(['a', 'a', 'a']);

      expect(users.length, 1);
      expect(adapter.seen.where((u) => u.path == '/api/twitter/a.json.gz').length, 1);
    });

    test('元数据失败降级为「只有用户名 + 权重」，不整页白拉', () async {
      adapter.routes['/api/tags'] =
          weightsFor({'a': {'女性': 1}, 'b': {'女性': 2}});
      adapter.routes['/api/twitter/a.json.gz'] = metaFor('a');
      // b 的元数据没有路由 → 适配器回 500。

      final users = await api.hydrateUsernames(['a', 'b']);

      expect(users.length, 2, reason: '一个用户取不到昵称不该让他消失');
      expect(users[1].username, 'b');
      expect(users[1].nick, isNull);
      expect(users[1].tags, {'女性': 2}, reason: '权重仍要拿到，否则筛不出人');
    });

    test('权重端点失败必须抛出，不能静默筛出空列表', () async {
      // 故意**不**登记 /api/tags：适配器对未登记路径回 500。
      adapter.routes['/api/twitter/a.json.gz'] = metaFor('a');

      await expectLater(
        api.hydrateUsernames(['a']),
        throwsA(isA<ApiException>()),
      );
      // 失败时不该先花一轮元数据请求（那 25 次往返就是白烧）。
      expect(adapter.seen.every((u) => u.path != '/api/twitter/a.json.gz'), isTrue);
    });
  });
}
