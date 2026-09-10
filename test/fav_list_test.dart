// 收藏夹回归测试。
//
// 真实故障：FavList 内部是纵向 ListView，而它的父级（FavoritesTab）也是纵向
// ListView —— 纵向嵌套纵向，内层拿到无界高度后渲染失败，表现为"收藏夹标题在、
// 收藏的条目全空"。这个测试按真实结构（父级可滚动列表 + FavList）搭，旧代码会
// 在 pump 时直接抛 "Vertical viewport was given unbounded height"。

import 'dart:async';
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

class _FakePathProvider extends PathProviderPlatform {
  final String dir;
  _FakePathProvider(this.dir);

  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

/// getMetaData 返回空对象：模型容错，账号信息为空但用户仍应显示出来。
class _StubAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: <String>[Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Widget _host(TwitterApi api, ProxyManager proxy) {
  // 复刻 FavoritesTab 的结构：外层一个纵向可滚动的 ListView，FavList 在其中。
  return MaterialApp(
    home: Scaffold(
      body: ListView(
        children: [FavList(api: api, proxy: proxy)],
      ),
    ),
  );
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fav_list_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    StorageService.resetForTests();
    await StorageService.ensureInitialized();
  });

  tearDown(() async {
    StorageService.resetForTests();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  testWidgets('收藏的用户真的渲染出来（父级已是可滚动列表）', (tester) async {
    StorageService.toggleFav('alice');

    final api = TwitterApi(adapter: _StubAdapter());
    await tester.pumpWidget(_host(api, ProxyManager()));
    await tester.pumpAndSettle();

    expect(find.text('@alice'), findsOneWidget);
    expect(find.text('收藏夹为空'), findsNothing);
    api.dispose();
  });

  testWidgets('导出/导入入口也一起渲染出来', (tester) async {
    StorageService.toggleFav('bob');

    final api = TwitterApi(adapter: _StubAdapter());
    await tester.pumpWidget(_host(api, ProxyManager()));
    await tester.pumpAndSettle();

    expect(find.text('导出'), findsOneWidget);
    expect(find.text('导入'), findsOneWidget);
    api.dispose();
  });

  testWidgets('没有收藏时显示空状态', (tester) async {
    final api = TwitterApi(adapter: _StubAdapter());
    await tester.pumpWidget(_host(api, ProxyManager()));
    await tester.pumpAndSettle();

    expect(find.text('收藏夹为空'), findsOneWidget);
    api.dispose();
  });

  testWidgets('取消收藏后列表里不再有它', (tester) async {
    StorageService.toggleFav('carol');

    final api = TwitterApi(adapter: _StubAdapter());
    await tester.pumpWidget(_host(api, ProxyManager()));
    await tester.pumpAndSettle();
    expect(find.text('@carol'), findsOneWidget);

    // 模拟在别处取消收藏后重建（FavoritesTab 用 key 重建）
    StorageService.toggleFav('carol');
    await tester.pumpWidget(_host(api, ProxyManager()));
    await tester.pumpAndSettle();

    expect(find.text('@carol'), findsNothing);
    expect(find.text('收藏夹为空'), findsOneWidget);
    api.dispose();
  });
}
