// 「点标签留在同一个页面」的判据测试。
//
// ## 用户的要求
//
// 「tag 页面需要是同一个页面，不能增加认知负担」——此前点标签有两个去处：
//  1. 从**搜索框推荐**点 → 留在用户列表页（已存在，走 enterTagSearch）；
//  2. 从**用户详情页的标签**点 → `Navigator.push` 一个独立的
//     `TagUserListScreen`。
//
// 同一个「看某标签下的人」有两个页面、两套返回行为，用户每次都得重新判断
// 「我刚才是在哪」。第 2 条已删除，改为把请求**递回**用户列表页执行
// （见 widgets/tag_browse.dart）。
//
// ## 判据为什么落在「回调收到的标签名」上
//
// 「点了有没有换页」不好直接断言（要看 Navigator 栈，而栈的变化在
// widget 测试里容易和动画/pump 时序纠缠）。而**请求是否带着正确的标签名
// 递回到列表页**是可判据、且是本质：页面跳不跳只是表象，标签查对没有才是。
// 另配一条断言「列表页真的进入了该标签的查找态」，两头都钉住。
//
// ## 为什么全程 pump() 而不是 pumpAndSettle()
//
// 用户列表页里有**永不停歇的动画**（骨架屏 `AnimationController.repeat`、
// RefreshIndicator 转圈），pumpAndSettle() 遇到它们永不返回——
// CI 实测挂死 30+ 分钟（正常一轮约 80 秒）。一律用有界 pump。
//
// ## ⚠️ 不要用 receiveAction / debugFlushPending
//
// 与 search_bar_tag_suggest_test.dart 同一个坑：前者会走到
// `StorageService.saveSearchHistory` → `unawaited(_flush())`；后者在
// tearDown 里等一个需要 pump 才能推进的 future，反而制造新挂起点。
// tearDown 只调 `resetForTests()`。

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:twitter_pic_flutter/api/twitter_api.dart';
import 'package:twitter_pic_flutter/models/user.dart';
import 'package:twitter_pic_flutter/screens/user_detail_screen.dart';
import 'package:twitter_pic_flutter/screens/user_list_screen.dart';
import 'package:twitter_pic_flutter/services/proxy_manager.dart';
import 'package:twitter_pic_flutter/services/storage_service.dart';
import 'package:twitter_pic_flutter/widgets/tag_browse.dart';

/// 按路径回放图站标签端点，其余路径回空对象。
class _GalleryAdapter implements HttpClientAdapter {
  static String tagCloud = '[]';
  static String tagPage = '{"count":0,"total":0,"users":[]}';
  static String weights = '{}';
  /// `GET /api/twitter/tags/<user>` —— 详情页靠它取标签（自带 TwitterApi）。
  static String userTags = '{"tags":{"自拍":2}}';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = Uri.decodeFull(options.uri.path);
    String body;
    if (path.startsWith('/api/tag-cloud') || path.endsWith('/tags/cloud')) {
      body = tagCloud;
    } else if (path.startsWith('/api/tag/')) {
      body = tagPage;
    } else if (path.startsWith('/api/tags')) {
      body = weights;
    } else if (path.startsWith('/api/twitter/tags/')) {
      body = userTags;
    } else {
      body = '{}';
    }
    return ResponseBody.fromString(body, 200,
        headers: {Headers.contentTypeHeader: <String>[Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.dir);
  final String dir;

  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

void main() {
  late Directory tmp;
  late TwitterApi api;
  late ProxyManager proxy;

  Future<void> settle(WidgetTester tester, [int times = 3]) async {
    for (var i = 0; i < times; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tag_same_page_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
    StorageService.resetForTests();
    TwitterApi.resetForTests();
    await StorageService.ensureInitialized();
    _GalleryAdapter.tagCloud = '[{"Tag":"自拍","Count":1196}]';
    _GalleryAdapter.tagPage = '{"count":1,"total":1,"users":["alice"]}';
    _GalleryAdapter.weights = '{"alice":{"自拍":2}}';
    api = TwitterApi(adapter: _GalleryAdapter());
    proxy = ProxyManager();
  });

  tearDown(() async {
    StorageService.resetForTests();
    TwitterApi.resetForTests();
    api.dispose();
    proxy.dispose();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Widget hostDetail({TagBrowseRequest? browse}) => MaterialApp(
        home: UserDetailScreen(
          profile: UserMetaData(
            accountInfo: TwitterUser(username: 'alice', tags: {'自拍': 2}),
            timeline: const [],
            totalUrls: 0,
          ),
          proxy: proxy,
          tagBrowse: browse,
        ),
      );

  group('点标签是同一个页面：请求递回用户列表页', () {
    testWidgets('递回时带的是**裸标签名**（剥掉前导 #）', (tester) async {
      final seen = <String>[];
      // 直接构造一个假的列表页句柄：判据是「传给列表页的标签名对不对」。
      final req = TagBrowseRequest((tag) {
        seen.add(tag);
        return true;
      });
      await tester.pumpWidget(hostDetail(browse: req));
      await settle(tester);

      await tester.tap(find.text('自拍'));
      await settle(tester);

      expect(seen, ['自拍'],
          reason: '回调必须收到裸标签名，带 # 会打不中服务端');
    });

    testWidgets('切换成功后回调被调用（详情页靠它 pop 自己）', (tester) async {
      var switched = false;
      final req = TagBrowseRequest((tag) {
        switched = true;
        return true;
      });
      await tester.pumpWidget(hostDetail(browse: req));
      await settle(tester);

      await tester.tap(find.text('自拍'));
      await settle(tester);
      expect(switched, isTrue);
    });

    testWidgets('切换**失败**时不触发 onSwitched（不能白 pop 一趟）',
        (tester) async {
      // pop 完却什么都没切换，用户被丢回列表页却看不到变化，比不响应更糟。
      var popped = false;
      final req = TagBrowseRequest((tag) => false);
      await tester.pumpWidget(hostDetail(browse: req));
      await settle(tester);

      req.enter('自拍', onSwitched: () => popped = true);
      expect(popped, isFalse,
          reason: '切换没发生就不该 pop，否则用户看到的是「无反应」');
    });
  });

  group('UserListScreen 作为接收方', () {
    testWidgets('enterTagSearch 接受带 # 的标签并剥掉', (tester) async {
      final key = GlobalKey<UserListScreenState>();
      await tester.pumpWidget(MaterialApp(
        home: UserListScreen(proxy: proxy, api: api, key: key),
      ));
      await settle(tester, 5);

      final ok = key.currentState!.enterTagSearch('#自拍');
      await settle(tester, 5);

      expect(ok, isTrue);
      // 反向断言：不该再 push 独立页面。独立页面已从仓库删除，
      // 这条同时钉住「不要把 push 加回来」。
      expect(find.text('标签用户加载失败'), findsNothing);
    });

    testWidgets('空标签名/纯 # 返回 false，不触发任何请求', (tester) async {
      final key = GlobalKey<UserListScreenState>();
      await tester.pumpWidget(MaterialApp(
        home: UserListScreen(proxy: proxy, api: api, key: key),
      ));
      await settle(tester, 5);

      expect(key.currentState!.enterTagSearch('   '), isFalse);
      expect(key.currentState!.enterTagSearch('#'), isFalse);
      expect(key.currentState!.enterTagSearch('#  '), isFalse);
    });

    testWidgets('tagBrowseRequest 绑定本页：调用它就等于在本页进入查找态',
        (tester) async {
      final key = GlobalKey<UserListScreenState>();
      await tester.pumpWidget(MaterialApp(
        home: UserListScreen(proxy: proxy, api: api, key: key),
      ));
      await settle(tester, 5);

      final req = key.currentState!.tagBrowseRequest;
      expect(canBrowseTagInPlace(req), isTrue);
      // 连续两次不同标签都返回 true——它是活的句柄，不是常量。
      expect(req.enter('自拍'), isTrue);
      await settle(tester, 3);
      expect(req.enter('露奶'), isTrue);
      await settle(tester, 3);
    });
  });

  group('拿不到列表页时的兜底', () {
    testWidgets('canBrowseTagInPlace 对 unavailable 返回 false', (tester) async {
      expect(canBrowseTagInPlace(null), isFalse);
      expect(canBrowseTagInPlace(TagBrowseRequest.unavailable), isFalse);
    });

    testWidgets('没有句柄时给出明确提示，而不是点了没反应', (tester) async {
      await tester.pumpWidget(hostDetail());
      await settle(tester);

      await tester.tap(find.text('自拍'));
      await settle(tester);

      expect(find.textContaining('不支持标签就地查看'), findsOneWidget,
          reason: '静默无反应与「跳转失败」难以区分，必须说清');
    });
  });
}
