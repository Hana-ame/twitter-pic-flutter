// 回归测试：Dio 拼接 baseUrl 与 path 时**不会**自动补斜杠。
//
// 曾经的真实故障：baseUrl = 'https://x.moonchan.xyz/api/twitter' 配 path =
// 'alice.json.gz'，实际请求成了 'https://x.moonchan.xyz/api/twitteralice.json.gz'。
// 后端是 gin，这个路径匹配不到路由 → NoRoute → STATIC_ROOT 未设置时直接
// AbortWithStatus(403)，于是 metadata / tags / emojis 全部 403，
// 表现为"详情页暂无内容、头像全空"，而 getUserList 因为用了 '/' 一直正常。
//
// 这个测试逐接口断言最终请求的**绝对路径**，用假适配器实现，不需要网络。

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/api/twitter_api.dart';

/// 记录每个请求最终解析出的 URL，并返回一份最小可解析的假响应。
class _RecordingAdapter implements HttpClientAdapter {
  final List<RequestOptions> seen;

  _RecordingAdapter() : seen = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    // 列表接口要 JSON 数组，其余接口要 JSON 对象。
    final body = options.uri.path.endsWith('/') ? '[]' : '{}';
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

/// 固定返回给定原始 JSON body 的假适配器。
///
/// _RecordingAdapter 的 body 由路径是否以 / 结尾决定（'[]' 或 '{}'），
/// 无法精确构造"200 + body null"这类畸形响应，body 契约用例用它。
class _FixedBodyAdapter implements HttpClientAdapter {
  final String body;

  _FixedBodyAdapter(this.body);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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

void main() {
  late _RecordingAdapter adapter;
  late TwitterApi api;

  setUp(() {
    adapter = _RecordingAdapter();
    api = TwitterApi(adapter: adapter);
  });

  // 元数据缓存是 static final、全实例共享。不重置的话本文件写进去的
  // 'alice'/'bob' 会被其它测试文件（fav_list_test 用 getMetaData('alice')）
  // 直接命中 —— 现在两边都碰巧拿到 {} 才没炸。Dart 不保证测试文件的执行顺序。
  tearDown(() {
    api.dispose();
    TwitterApi.resetForTests();
  });

  test('每个接口都拼出正确的绝对路径（baseUrl 与 path 之间必须有 /）', () async {
    await api.getUserList();
    await api.searchUserList('username', 'a');
    await api.searchUsersByTag('女性');
    await api.getMetaData('alice', forceRefresh: true);
    await api.getTags('alice');
    await api.getEmojis('alice');
    await api.voteUpEmoji('alice', 'x');
    await api.getRanking();
    await api.createMetaData('alice', tags: const {'原创': 1});

    expect(
      adapter.seen.map((o) => '${o.method} ${o.uri.path}').toList(),
      <String>[
        'GET /api/twitter/',
        'GET /api/twitter/',
        'GET /api/twitter/',
        'GET /api/twitter/alice.json.gz',
        'GET /api/twitter/tags/alice',
        'GET /api/twitter/emojis',
        'POST /api/twitter/emojis',
        'GET /api/twitter/emojis.json.gz',
        'POST /api/twitter/alice',
      ],
    );
  });

  test('列表/搜索三类查询的 query 参数（含 by=tag 新契约）', () async {
    await api.getUserList();
    await api.getUserList(after: 'bob');
    await api.searchUserList('nick', '昵称');
    await api.searchUsersByTag('女性');

    expect(adapter.seen[0].uri.queryParameters, {'list': 'users'});
    expect(adapter.seen[1].uri.queryParameters, {'list': 'users', 'after': 'bob'});
    expect(adapter.seen[2].uri.queryParameters, {'by': 'nick', 'search': '昵称'});
    expect(adapter.seen[3].uri.queryParameters, {'by': 'tag', 'search': '女性'});
  });

  test('searchUsersByTag 空 tag 早退返回 []，不发请求（与 searchUserList 同语义）', () async {
    await expectLater(api.searchUsersByTag(''), completion(isEmpty));
    expect(adapter.seen, isEmpty, reason: '空 tag 不应产生网络请求');
  });

  test('200 + body null → 抛 UnexpectedResponseException（旧二进制对未知 by 静默回 null）', () async {
    // ⚠️ 线上未升级时 GET /?by=tag 返回的就是 200 null。解码层若把它吞成
    // 空列表，UI 会假绿成"这个标签没人"。三种列表查询同一口径。
    final broken = TwitterApi(adapter: _FixedBodyAdapter('null'));
    addTearDown(broken.dispose);
    await expectLater(
        broken.searchUsersByTag('女性'), throwsA(isA<UnexpectedResponseException>()));
    await expectLater(
        broken.searchUserList('username', 'x'), throwsA(isA<UnexpectedResponseException>()));
    await expectLater(broken.getUserList(), throwsA(isA<UnexpectedResponseException>()));
  });

  test('200 + body [] → 正常返回空列表（新版空结果契约）', () async {
    final empty = TwitterApi(adapter: _FixedBodyAdapter('[]'));
    addTearDown(empty.dispose);
    expect(await empty.searchUsersByTag('女性'), isEmpty);
    expect(await empty.searchUserList('nick', 'x'), isEmpty);
    expect(await empty.getUserList(), isEmpty);
  });

  test('200 + 非 null 非数组 body 同样抛错，不吞成空列表', () async {
    final obj = TwitterApi(adapter: _FixedBodyAdapter('{"error":"boom"}'));
    addTearDown(obj.dispose);
    await expectLater(
        obj.getUserList(), throwsA(isA<UnexpectedResponseException>()));
    await expectLater(
        obj.searchUsersByTag('女性'), throwsA(isA<ApiException>()));
  });

  test('by=tag 的 []User 同构响应逐项解析（含 tags、字符串数、负权重）', () async {
    final ok = TwitterApi(adapter: _FixedBodyAdapter(
      '[{"username":"alice","last_modify":"2026-09-15T10:00:00Z",'
      '"tags":{"女性":5,"自拍":"3","COS":-1,"坏值":"x"},"status":"SUCCESS"},'
      '{"username":"bob"}]',
    ));
    addTearDown(ok.dispose);
    final users = await ok.searchUsersByTag('女性');
    expect(users, hasLength(2));
    expect(users[0].username, 'alice');
    expect(users[0].tags, {'女性': 5, '自拍': 3, 'COS': -1, '坏值': 0});
    // 第二项无任何可选字段：tags 必须是空 Map 而非 null/崩溃。
    expect(users[1].username, 'bob');
    expect(users[1].tags, isEmpty);
  });

  test('getTagWeights 把 /tags/<user> 响应的 tags 解成 Map<String,int>', () async {
    final typed = TwitterApi(adapter: _FixedBodyAdapter(
      '{"username":"alice","last_modify":"2026-09-15T10:00:00Z",'
      '"tags":{"女性":5,"自拍":"3","COS":-1,"零":0,"坏值":"x"},"status":"SUCCESS"}',
    ));
    addTearDown(typed.dispose);
    // 服务端不过滤 0/负数，客户端原样保留；字符串数兼容；解析失败兜 0。
    expect(await typed.getTagWeights('alice'),
        {'女性': 5, '自拍': 3, 'COS': -1, '零': 0, '坏值': 0});
  });

  test('所有请求的绝对 URL 都落在 kApiBase/ 之下', () async {
    await api.getUserList();
    await api.searchUserList('username', 'a');
    await api.searchUsersByTag('女性');
    await api.getMetaData('alice', forceRefresh: true);
    await api.getTags('alice');
    await api.getEmojis('alice');
    await api.getRanking();
    await api.createMetaData('alice', tags: const {'原创': 1});

    for (final o in adapter.seen) {
      // 少了斜杠会变成 'https://x.moonchan.xyz/api/twitteralice.json.gz'。
      expect(o.uri.toString(), startsWith('$kApiBase/'),
          reason: '${o.method} ${o.uri} 没有落在 $kApiBase 下');
    }
  });

  test('getMetaData 的查询参数与缓存行为', () async {
    await api.getMetaData('bob', t: '2026-09-10', forceRefresh: true);
    expect(adapter.seen.single.uri.queryParameters['t'], '2026-09-10');

    // 第二次命中 10 分钟缓存，不再发请求。
    await api.getMetaData('bob');
    expect(adapter.seen.length, 1);

    // forceRefresh 绕过缓存。
    await api.getMetaData('bob', forceRefresh: true);
    expect(adapter.seen.length, 2);
  });

  test('静态缓存跨实例共享；resetForTests 让它失效', () async {
    final a = TwitterApi(adapter: adapter);
    await a.getMetaData('carol');
    expect(adapter.seen.length, 1);

    // 新实例命中同一个静态缓存 —— 这是设计意图（并发 miss 复用同一个
    // in-flight 请求，避免重复流量），不是缺陷。
    final b = TwitterApi(adapter: adapter);
    await b.getMetaData('carol');
    expect(adapter.seen.length, 1, reason: '第二个实例应复用缓存，不再发请求');

    // 有了这个入口，测试之间才可能隔离。
    TwitterApi.resetForTests();
    await b.getMetaData('carol');
    expect(adapter.seen.length, 2, reason: 'resetForTests 之后缓存必须失效');

    a.dispose();
    b.dispose();
  });

  // ─── 添加用户必须带标签（v0.6.3）────────────────────────────────────────
  //
  // 服务端 `POST /api/twitter/:username` 的「首次添加」分支（两个 flag 都不传）
  // 会解 body：解不出 → 400，解出空 map → 400「你没加tag，这是不行的」。
  // 实测生产：无 body 直接 POST → 400 {"error":"EOF"}。
  //
  // 所以这条约束由**必填命名参数**在编译期保证，并额外在本地拦一次空标签，
  // 不白跑一次往返。

  group('createMetaData：标签必填契约', () {
    test('首次添加带标签：POST 到 :username 且不传任何 flag', () async {
      await api.createMetaData('alice', tags: const {'原创': 1});
      final o = adapter.seen.last;
      expect(o.method, 'POST');
      expect(o.uri.path, '/api/twitter/alice');
      // 两个 flag 都不能带：带了会走另外的分支（do_not_tag / do_not_renew）
      expect(o.uri.queryParameters, isEmpty,
          reason: '首次添加不能带 flag：${o.uri.query}');
    });

    test('首次添加带空标签：本地就抛 ArgumentError，不发请求', () async {
      final before = adapter.seen.length;
      await expectLater(
        api.createMetaData('alice', tags: const {}),
        throwsA(isA<ArgumentError>()),
      );
      expect(adapter.seen.length, before,
          reason: '空标签服务端必然 400，不该浪费一次网络往返');
    });

    test('do_not_tag 分支允许空标签（只重抓数据，与标签无关）', () async {
      await api.createMetaData('alice', tags: const {}, doNotTag: true);
      final o = adapter.seen.last;
      expect(o.method, 'POST');
      expect(o.uri.queryParameters['do_not_tag'], 'true');
    });

    test('do_not_renew 分支：带标签补标签，不重抓', () async {
      await api.createMetaData('alice',
          tags: const {'女性': 1}, doNotRenew: true);
      final o = adapter.seen.last;
      expect(o.uri.path, '/api/twitter/alice');
      expect(o.uri.queryParameters['do_not_renew'], 'true');
      expect(o.uri.queryParameters.containsKey('do_not_tag'), isFalse);
    });

    test('带标签时 body 真的发出去了（不是空 body）', () async {
      await api.createMetaData('alice', tags: const {'女性': 1});
      // Dio 会把 Map 序列化成 JSON 字符串放进 data。
      expect(adapter.seen.last.data, isNotNull,
          reason: '标签必须真发出去，否则服务端拿到空 map 照样 400');
    });

    test('写入成功后清掉该用户的元数据缓存', () async {
      await api.getMetaData('carol', forceRefresh: true);
      final before = adapter.seen.length;
      await api.createMetaData('carol', tags: const {'原创': 1});
      // 缓存被清了，所以再读一次必须真的发请求。
      await api.getMetaData('carol');
      expect(adapter.seen.length, before + 2,
          reason: '写操作后缓存应失效，重新读要发新请求');
    });
  });
}
