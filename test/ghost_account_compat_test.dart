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

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/api/twitter_api.dart';
import 'package:twitter_pic_flutter/services/storage_service.dart';

/// 会记录命中次数、并按用户名决定返回 200 还是 404 的适配器。
class _CountingAdapter implements HttpClientAdapter {
  _CountingAdapter(this.ghost);

  /// 判定为「幽灵」的账号集合：这些名字打元数据必然 404。
  final Set<String> ghost;

  final Map<String, int> metaHits = <String, int>{};
  final List<String> paths = <String>[];

  /// `/api/tags` 的权重响应。真实服务端**不区分**幽灵与正常账号
  /// （实测 vivi1213813 在 /api/tags 里同样有权重），所以这里给所有人同一份。
  late final String weights = jsonEncode({
    for (final n in allNames) n: <String, int>{'女性': 1},
  });

  late final List<String> allNames;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.path;
    paths.add(path);

    ResponseBody ok(String body) => ResponseBody.fromString(
          body,
          200,
          headers: <String, List<String>>{
            'content-type': <String>['application/json; charset=utf-8'],
          },
        );

    if (path.contains('/api/tags?') || path.contains('/api/tags&')) {
      return ok(weights);
    }

    // 元数据：路径形如 /api/twitter/<name>.json.gz
    final m = RegExp(r'/api/twitter/([^/?]+)\.json\.gz').firstMatch(path);
    if (m != null) {
      final name = Uri.decodeComponent(m.group(1)!);
      metaHits[name] = (metaHits[name] ?? 0) + 1;
      if (ghost.contains(name)) {
        // 与线上实测一致：200 之外是带 error 字段的 JSON 404。
        return ResponseBody.fromString(
          jsonEncode({'error': '查询用户失败: 没有进入 rows.Next()'}),
          404,
          headers: <String, List<String>>{
            'content-type': <String>['application/json; charset=utf-8'],
          },
        );
      }
      return ok(jsonEncode({
        'total_urls': 3,
        'timeline': <dynamic>[],
        'account_info': <String, dynamic>{
          'name': name,
          'nick': '昵称-$name',
          'profile_image': 'https://example.test/$name.jpg',
        },
      }));
    }

    return ResponseBody.fromString(
      jsonEncode({'error': 'no route registered for $path'}),
      500,
      headers: <String, List<String>>{
        'content-type': <String>['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  // TwitterApi 的元数据缓存与 404 负缓存都是 static 全实例共享，必须重置。
  tearDown(() {
    TwitterApi.resetForTests();
    StorageService.resetForTests();
  });

  test('① 404 进负缓存：第二次调用不再发请求', () async {
    const name = 'vivi1213813';
    final adapter = _CountingAdapter(<String>{name});
    adapter.allNames = <String>[name];
    final api = TwitterApi(adapter: adapter);
    addTearDown(api.dispose);

    // 第一次：真发一次，拿到 404。
    await expectLater(
      () => api.getMetaData(name),
      throwsA(isA<HttpException>().having((e) => e.statusCode, 'statusCode', 404)),
    );
    expect(adapter.metaHits[name], 1,
        reason: '第一次必须真发请求');
    expect(TwitterApi.isKnownMissing(name), isTrue,
        reason: '404 之后应被标记为「已知不存在」');

    // 第二次：**不应**再发请求 —— 这正是「下一页极慢」的修复点。
    await expectLater(
      () => api.getMetaData(name),
      throwsA(isA<HttpException>().having((e) => e.statusCode, 'statusCode', 404)),
    );
    expect(adapter.metaHits[name], 1,
        reason: '负缓存命中后不该再发第 2 次请求，实际发了 '
            '${adapter.metaHits[name]} 次 —— 「下一页极慢」没修好');

    // 形态一致性：负缓存抛的仍是 404 HttpException，hydrate 的
    // `e is HttpException && statusCode == 404` 才能同样识别它。
  });

  test('①b 非 404 失败不进负缓存（保持可自愈）', () async {
    final adapter = _CountingAdapter(<String>{});
    adapter.allNames = <String>['alice'];
    final api = TwitterApi(adapter: adapter);
    addTearDown(api.dispose);

    // 未注册路由 → 适配器回 500。
    await expectLater(
      () => api.getMetaData('alice'),
      throwsA(isA<HttpException>()),
    );
    expect(TwitterApi.isKnownMissing('alice'), isFalse,
        reason: '5xx 是临时故障，不该被当成「账号不存在」永久记住');
  });

  test('② hydrate 把 404 账号从结果里剔除，且只请求一次', () async {
    final ghosts = <String>{'ghost0', 'ghost1', 'ghost2'};
    final alive = <String>['user0', 'user1'];
    final names = <String>[...alive, ...ghosts];

    final adapter = _CountingAdapter(ghosts);
    adapter.allNames = names;
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
    final before = adapter.metaHits.length;
    final totalBefore =
        adapter.metaHits.values.fold<int>(0, (a, b) => a + b);
    await api.hydrateUsernames(ghosts.toList());
    final totalAfter = adapter.metaHits.values.fold<int>(0, (a, b) => a + b);
    expect(totalAfter, totalBefore,
        reason: '已 404 的账号在负缓存 TTL 内不该再发请求；'
            '新发次数=${totalAfter - totalBefore}');
    expect(adapter.metaHits.length, before,
        reason: '负缓存内的账号不该出现新的命中记录');
  });
}
