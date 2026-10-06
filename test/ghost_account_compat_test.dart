// 客户端兼容层：服务端标签反查会发出一批「点进去必然 404」的账号。
//
// 背景（2026-10-06 线上实测，x.moonchan.xyz）：
//
//     GET /api/tag/女性?limit=25&offset=0 → users=25, total=7596
//     这 25 人逐个 GET /api/twitter/<u>.json.gz → 200:10 / 404:15（60%）
//     GET /api/twitter/vivi1213813.json.gz → {"error":"查询用户失败: 没有进入 rows.Next()"}
//
// 三源交叉确认：这些账号在**标签索引**里有（`/api/tags` 能查到权重），
// 却不在服务端 users 表里，所以点进去必然 404。
//
// 本文件钉的是**客户端自己的两条兜底**，与服务端是否已升级无关：
//   ① 404 进负缓存 —— 第二次不再发那个注定失败的请求（「下一页极慢」的机制）；
//   ② hydrate 遇到 404 把该行剔除 —— 不给用户一个「点了就报错」的行。
//
// ⚠️ 与 `user_list_no_nplus1_test.dart` 同样的约束：
//   - 不用 `pumpAndSettle`（`_SkeletonCircle` 常驻 `repeat(reverse: true)`）；
//   - `pumpWidget` 之前不 await 真实网络 future（假异步时钟 → 整包超时）。

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/api/twitter_api.dart';
import 'package:twitter_pic_flutter/services/storage_service.dart';

/// 会记录命中次数、并按用户名决定返回 200 还是 404 的适配器。
///
/// ⚠️ 必须用 `options.uri.path`（含 base URL 前缀），不能用 `options.path`
/// （那是不带 base 的裸路径）。否则 `/api/twitter/...` 与 `/api/tags` 全都
/// 匹配不到，所有请求都掉进 500 兜底。
class _CountingAdapter implements HttpClientAdapter {
  _CountingAdapter(this.ghost, {this.fail500 = const <String>{}});

  /// 判定为「幽灵」的账号集合：这些名字打元数据必然 404。
  final Set<String> ghost;

  /// 强制返回 500 的账号（模拟临时故障，用来验证不进负缓存）。
  final Set<String> fail500;

  /// 用户名 → 元数据被请求的次数。
  final Map<String, int> metaHits = <String, int>{};

  /// 记录所有请求（用于诊断）。
  final List<String> paths = <String>[];

  /// `/api/tags` 的权重响应。真实服务端**不区分**幽灵与正常账号
  /// （实测 vivi1213813 在 /api/tags 里同样有权重），所以这里给所有人同一份。
  String weights = '{}';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    final full = uri.toString();
    paths.add(full);

    ResponseBody json(int code, String body) => ResponseBody.fromString(
          body,
          code,
          headers: <String, List<String>>{
            'content-type': <String>['application/json; charset=utf-8'],
          },
        );

    // 权重端点在 gallery 客户端上（base 是站点 origin，不带 /api/twitter 前缀）。
    if (uri.path == '/api/tags' || uri.path == '/api/account-tags') {
      return json(200, weights);
    }

    // 元数据端点在 twitter 客户端上（base 含 /api/twitter 前缀）。
    final m = RegExp(r'^/api/twitter/([^/?]+)\.json\.gz$').firstMatch(uri.path);
    if (m != null) {
      final name = Uri.decodeComponent(m.group(1)!);
      metaHits[name] = (metaHits[name] ?? 0) + 1;
      if (ghost.contains(name)) {
        // 与线上实测一致：200 之外是带 error 字段的 JSON 404。
        return json(404, jsonEncode({'error': '查询用户失败: 没有进入 rows.Next()'}));
      }
      if (fail500.contains(name)) {
        // 模拟临时故障：500 + error。不进负缓存（只有 404 进）。
        return json(500, jsonEncode({'error': '模拟服务器内部错误'}));
      }
      return json(200, jsonEncode({
        'total_urls': 3,
        'timeline': <dynamic>[],
        'account_info': <String, dynamic>{
          'name': name,
          'nick': '昵称-$name',
          'profile_image': 'https://example.test/$name.jpg',
        },
      }));
    }

    return json(500, jsonEncode({'error': 'no route registered for $full'}));
  }

  @override
  void close({bool force = false}) {}
}

/// 构造一个 `/api/tags` 的权重响应，覆盖 [names] 里的所有人。
String _weightsFor(Iterable<String> names) => jsonEncode({
  for (final n in names) n: <String, int>{'女性': 1},
});

void main() {
  // TwitterApi 的元数据缓存与 404 负缓存都是 static 全实例共享，必须重置。
  tearDown(() {
    TwitterApi.resetForTests();
    StorageService.resetForTests();
  });

  test('① 404 进负缓存：第二次调用不再发请求', () async {
    const name = 'vivi1213813';
    final adapter = _CountingAdapter(<String>{name});
    adapter.weights = _weightsFor(<String>[name]);
    final api = TwitterApi(adapter: adapter);
    addTearDown(api.dispose);

    // 第一次：真发一次，拿到 404。
    await expectLater(
      () => api.getMetaData(name),
      throwsA(isA<DioException>().having(
        (e) => asHttpException(e)?.statusCode,
        'statusCode',
        404,
      )),
    );
    expect(adapter.metaHits[name], 1,
        reason: '第一次必须真发请求');
    expect(TwitterApi.isKnownMissing(name), isTrue,
        reason: '404 之后应被标记为「已知不存在」');

    // 第二次：**不应**再发请求 —— 这正是「下一页极慢」的修复点。
    await expectLater(
      () => api.getMetaData(name),
      throwsA(isA<DioException>().having(
        (e) => asHttpException(e)?.statusCode,
        'statusCode',
        404,
      )),
    );
    expect(adapter.metaHits[name], 1,
        reason: '负缓存命中后不该再发第 2 次请求，实际发了 '
            '${adapter.metaHits[name]} 次 —— 「下一页极慢」没修好');
  });

  test('①b 非 404 失败不进负缓存（保持可自愈）', () async {
    final adapter = _CountingAdapter(<String>{}, fail500: <String>{'alice'});
    adapter.weights = _weightsFor(<String>['alice']);
    final api = TwitterApi(adapter: adapter);
    addTearDown(api.dispose);

    // 未注册路由 → 适配器回 500。
    await expectLater(
      () => api.getMetaData('alice'),
      throwsA(isA<DioException>().having(
        (e) => asHttpException(e)?.statusCode,
        'statusCode',
        500,
      )),
    );
    expect(TwitterApi.isKnownMissing('alice'), isFalse,
        reason: '5xx 是临时故障，不该被当成「账号不存在」永久记住');
  });

  test('② hydrate 把 404 账号从结果里剔除，且只请求一次', () async {
    final ghosts = <String>{'ghost0', 'ghost1', 'ghost2'};
    final alive = <String>['user0', 'user1'];
    final names = <String>[...alive, ...ghosts];

    final adapter = _CountingAdapter(ghosts);
    adapter.weights = _weightsFor(names);
    final api = TwitterApi(adapter: adapter);
    addTearDown(api.dispose);

    final out = await api.hydrateUsernames(names);

    // 幽灵账号**不该**出现在结果里 —— 留着就是一个「点了就 404」的行。
    expect(out.map((u) => u.username), isNot(contains('ghost0')),
        reason: '404 账号必须被剔除，否则用户点进去必然报错');
    expect(out.map((u) => u.username), isNot(contains('ghost2')));
    // 正常账号一个都不能少。
    expect(out.map((u) => u.username), containsAll(alive));

    // 每个账号至多请求一次。
    for (final n in names) {
      expect(adapter.metaHits[n] ?? 0, lessThanOrEqualTo(1),
          reason: '$n 被请求了 ${adapter.metaHits[n]} 次');
    }

    // 第二次 hydrate（模拟翻页再遇到同一批人）：幽灵账号已在负缓存里，
    // **一个请求都不该再发**。
    final totalBefore = adapter.metaHits.values.fold<int>(0, (a, b) => a + b);
    await api.hydrateUsernames(ghosts.toList());
    final totalAfter = adapter.metaHits.values.fold<int>(0, (a, b) => a + b);
    expect(totalAfter, totalBefore,
        reason: '已 404 的账号在负缓存 TTL 内不该再发请求；'
            '新发次数=${totalAfter - totalBefore}');
  });
}