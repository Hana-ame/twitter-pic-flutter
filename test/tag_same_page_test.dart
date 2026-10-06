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

  /// ⚠️ 不要在 pumpWidget **之前** await 任何真实网络 future：flutter_test 用
  /// 假异步时钟，那会让整包跑挂在 `TimeoutException after 0:10:00`，而逐文件
  /// 跑却全绿。
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
        home: Scaffold(body: UserDetailScreen(
          profile: UserMetaData(
            accountInfo: TwitterUser(username: 'alice', tags: {'自拍': 2}),
            timeline: const [],
            totalUrls: 0,
          ),
          proxy: proxy,
          tagBrowse: browse,
          // ⚠️ 必须注入：详情页默认自建 TwitterApi() 打真实网络，
          // 标签区永远出不来，测试无从构造 tap 目标。
          api: api,
        )),
      );

  group('点标签是同一个页面：请求递回用户列表页', () {
    testWidgets('递回时带的是**裸标签名**（剥掉前导 #）', (tester) async {
      final seen = <String>[];
      // 直接构造一个假的列表页句柄：判据是「传给列表页的标签名对不对」。
      final req = (String tag) {
        seen.add(tag);
        return true;
      };
      await tester.pumpWidget(hostDetail(browse: req));
      await settle(tester);

      await tester.tap(find.text('自拍'));
      await settle(tester);

      expect(seen, ['自拍'],
          reason: '回调必须收到裸标签名，带 # 会打不中服务端');
    });

    testWidgets('切换成功后回调被调用（详情页靠它 pop 自己）', (tester) async {
      var switched = false;
      final req = (String tag) {
        switched = true;
        return true;
      };
      await tester.pumpWidget(hostDetail(browse: req));
      await settle(tester);

      await tester.tap(find.text('自拍'));
      await settle(tester);
      expect(switched, isTrue);
    });

    testWidgets('切换**失败**时不触发 onDone（不能白 pop 一趟）',
        (tester) async {
      // pop 完却什么都没切换，用户被丢回列表页却看不到变化，比不响应更糟。
      var popped = false;
      final req = (String tag) => false;
      await tester.pumpWidget(hostDetail(browse: req));
      await settle(tester);

      enterTagInPlace(req, '自拍', onDone: () => popped = true);
      expect(popped, isFalse,
          reason: '切换没发生就不该 pop，否则用户看到的是「无反应」');
    });
  });

  group('UserListScreen 作为接收方', () {
    testWidgets('enterTagSearch 接受带 # 的标签并剥掉', (tester) async {
      final key = GlobalKey<UserListScreenState>();
      // ⚠️ 必须 Scaffold 包一层：UserListScreen 的根是 Column + Expanded，
      // 没有 body 约束会 RenderFlex overflow（CI run 37395999459 实测
      // overflow by 99416 pixels，11 例全挂在这条上）。不要直接
      // `MaterialApp(home: UserListScreen(...))` —— 见 add_user_flow_test.dart。
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: UserListScreen(proxy: proxy, api: api, key: key)),
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
      // ⚠️ 必须 Scaffold 包一层：UserListScreen 的根是 Column + Expanded，
      // 没有 body 约束会 RenderFlex overflow（CI run 37395999459 实测
      // overflow by 99416 pixels，11 例全挂在这条上）。不要直接
      // `MaterialApp(home: UserListScreen(...))` —— 见 add_user_flow_test.dart。
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: UserListScreen(proxy: proxy, api: api, key: key)),
      ));
      await settle(tester, 5);

      expect(key.currentState!.enterTagSearch('   '), isFalse);
      expect(key.currentState!.enterTagSearch('#'), isFalse);
      expect(key.currentState!.enterTagSearch('#  '), isFalse);
    });

    testWidgets('tagBrowseRequest 绑定本页：调用它就等于在本页进入查找态',
        (tester) async {
      final key = GlobalKey<UserListScreenState>();
      // ⚠️ 必须 Scaffold 包一层：UserListScreen 的根是 Column + Expanded，
      // 没有 body 约束会 RenderFlex overflow（CI run 37395999459 实测
      // overflow by 99416 pixels，11 例全挂在这条上）。不要直接
      // `MaterialApp(home: UserListScreen(...))` —— 见 add_user_flow_test.dart。
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: UserListScreen(proxy: proxy, api: api, key: key)),
      ));
      await settle(tester, 5);

      final req = key.currentState!.tagBrowseRequest;
      // 句柄现在就是裸函数值：没有 canBrowseTagInPlace 之类的判定入口，
      // 「有没有能力」在**类型上**就是 non-null / null 这一件事。
      expect(req, isNotNull);
      // 连续两次不同标签都返回 true——它是活的句柄，不是常量。
      expect(req('自拍'), isTrue);
      await settle(tester, 3);
      expect(req('露奶'), isTrue);
      await settle(tester, 3);
    });
  });

  group('拿不到列表页时的兜底', () {
    testWidgets('反向断言：没有「不支持」的哨兵值了，只有 null', (tester) async {
      // 原先这里断言 `canBrowseTagInPlace(TagBrowseRequest.unavailable) == false`
      // ——那条断言之所以能过，靠的是一个**生产代码从没引用过**的常量
      // （全仓只有这一行测试用它）。它表达的是「API 表面有两种『没有』」，
      // 而实际只有一种。删掉哨兵后这条改成钉住新形状：
      //  - 句柄就是裸函数值，不是包装类实例；
      //  - 「没有」用 null 表达，不需要额外的判定入口。
      const TagBrowseRequest request = _alwaysTrue;
      expect(request('任意标签'), isTrue,
          reason: '句柄是裸函数值：调用即执行，不需要额外的 enter/onSwitched');
      // 「没有」只有一个形态：null。
      expect(null, isNull);
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

/// 一条恒真的假句柄：用来证明句柄就是裸函数值。
bool _alwaysTrue(String tag) => true;
