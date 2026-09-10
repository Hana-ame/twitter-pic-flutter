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

void main() {
  late _RecordingAdapter adapter;
  late TwitterApi api;

  setUp(() {
    adapter = _RecordingAdapter();
    api = TwitterApi(adapter: adapter);
  });

  tearDown(() => api.dispose());

  test('每个接口都拼出正确的绝对路径（baseUrl 与 path 之间必须有 /）', () async {
    await api.getUserList();
    await api.searchUserList('username', 'a');
    await api.getMetaData('alice', forceRefresh: true);
    await api.getTags('alice');
    await api.getEmojis('alice');
    await api.voteUpEmoji('alice', 'x');
    await api.getRanking();
    await api.createMetaData('alice');

    expect(
      adapter.seen.map((o) => '${o.method} ${o.uri.path}').toList(),
      <String>[
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

  test('所有请求的绝对 URL 都落在 kApiBase/ 之下', () async {
    await api.getUserList();
    await api.searchUserList('username', 'a');
    await api.getMetaData('alice', forceRefresh: true);
    await api.getTags('alice');
    await api.getEmojis('alice');
    await api.getRanking();
    await api.createMetaData('alice');

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
}
