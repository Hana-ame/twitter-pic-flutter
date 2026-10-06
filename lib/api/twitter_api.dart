// 与后端交互的 API 客户端，提供用户信息、标签、投票等接口。
//
// 使用 Dio 替代原生 HttpClient，获得：
//   - 明确的 connectTimeout / receiveTimeout（15s）
//   - 结构化异常（DioException），可区分网络错误 vs HTTP 错误
//   - 全局拦截器支持（认证、日志、重试）
//   - 自动 JSON 反序列化

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/user.dart';

/// API 与媒体分流：JSON/API **直连** x.moonchan.xyz（自建域名，可正常访问，
/// 无需 ECH）；只有 twimg 媒体（pbs/video(.cf).twimg.com）才经本机
/// ProxyManager + EchUrl.rewrite 走 ECH。
const kApiBase = 'https://x.moonchan.xyz/api/twitter';

/// 图站（gallery）的 origin —— **与 [kApiBase] 不是同一个 base**。
///
/// 为什么必须单独一个 base：`/api/twitter` 这组路由是 gin 的
/// `r.Group("/api/twitter")` + `twitter.AddToGroup`（go/server/main.go），
/// 它只注册了 `GET /`、`GET /:fn`、`GET /tags/:username`、`GET /emojis*` 等
/// **固定几条**路由；而 `/api/tag/{tag}`、`/api/tag-cloud` 这些反查/标签云端点
/// 注册在 **gallery 自己的 `http.ServeMux`** 上（go/gallery/main.go 的
/// `galleryMux`）。`setupRouter` 用 `r.NoRoute` 把所有 API 之外的路径交回
/// gallery handler，所以图站端点真实路径是 `/api/tag/<tag>`、
/// **不带** `/api/twitter` 前缀。
///
/// ⚠️ 实测（2026-10-05，线上 `x.moonchan.xyz`）：
/// ```
/// GET /api/twitter/tag/%E5%A5%B3%E6%80%A7?limit=5   → 404 page not found
/// GET /api/twitter/tag-cloud?limit=3               → 404 {"error":"查询用户失败: 没有进入 rows.Next()"}
/// GET /api/tag/%E5%A5%B3%E6%80%A7?limit=5           → 200 {"count":5,"total":7580,"users":[...]}
/// GET /api/tag-cloud?limit=3                       → 200 [{"Tag":"女性","Count":7580}, ...]
/// ```
/// 也就是说把图站端点挂在 [kApiBase] 下会**静默 404**：gin 先在
/// `/api/twitter` 组里找不到匹配路由，落到 `NoRoute` 再交给 gallery，
/// 而 gallery 的 mux 又匹配不上 `/api/twitter/...`，最终 404。
const kGalleryBase = 'https://x.moonchan.xyz';

/// 画廊端点 `GET /api/tag/<tag>` 的一页结果。
///
/// 实测 `users` 是**裸用户名字符串数组**（不是 `[]User`），且 `page` 参数是
/// 摆设（page=1/2/3 回的数组一模一样，只有 `offset` 生效），所以翻页**只能**
/// 靠 offset 递增。
class TagUserPage {
  /// 本页的裸用户名。
  final List<String> usernames;

  /// 本页的 offset，便于调用方继续翻页。
  final int offset;

  /// 这个标签下总共多少个用户（与标签云里的 Count 同源）。
  ///
  /// 实测 `女性` 的 total=7591，与 tag-cloud 的 `Count`=7591 相等，即**人数**
  /// 口径。`by=tag` 对同一标签只回 15 条是**分页上限**，不能拿它反推口径。
  final int? total;

  const TagUserPage({
    required this.usernames,
    required this.offset,
    this.total,
  });

  /// 本页是否已到末尾（返回条数 < 请求 limit 即认为结束）。
  ///
  /// 画廊端点**不返回** hasMore 字段，只能拿条数与请求 limit 比；满页时
  /// 上层继续请求一次，拿到空页（0 < limit）后由这条判定收住，不会死循环。
  ///
  /// ⚠️ 这条判定**只能在服务端按稳定全序返回时**成立。反查 SQL 是
  /// `ORDER BY cnt DESC, username ASC`（go/tags/tags.go 的
  /// `UsersForTagPaged`），username 唯一所以确实是全序；实测把 offset=0…725
  /// 逐页拉过一遍，每页都是满 25 条且与相邻页首尾不重叠，无空洞也无重复。
  /// 真正的兜底在 UI 侧：跨页按 username 去重（`_loadMoreTagUsers`）。
  bool isLastPage(int requested) => usernames.length < requested;
}

/// 结构化 API 异常，包装 Dio 错误供 UI 层使用。
sealed class ApiException implements Exception {
  final String message;
  const ApiException(this.message);

  @override
  String toString() => message;
}

class NetworkException extends ApiException {
  const NetworkException(super.message);
}

class HttpException extends ApiException {
  final int statusCode;
  const HttpException(this.statusCode, super.message);
}

class UnknownException extends ApiException {
  const UnknownException(super.message);
}

/// 服务端返回了 200，但响应体形态不符合契约（期望 JSON 数组却拿到 `null` 等）。
///
/// 关键背景：**线上（未升级到 6261e29 的）旧二进制不认识 `by=tag` 这类未知
/// `by` 值，会静默返回 `200 + body null`，而不是 400/404。** 若把"非列表"
/// 一律读成空列表，服务端没升级就表现为"这个标签没人"——静默假绿。
/// 因此列表类解码点必须区分 `null` 与 `[]`：`[]` 才是"确实没有结果"，
/// `null` 抛本异常，让 UI 至少能说"服务端未就绪"。
class UnexpectedResponseException extends ApiException {
  const UnexpectedResponseException(super.message);
}

/// 从抛出的对象里取出真正的 [ApiException]（可能裹在 `DioException.error` 里）。
///
/// ⚠️ **调用方判断 HTTP 状态码必须走这个函数**，不能直接 `e is HttpException`：
///
/// 异常映射拦截器（[TwitterApi] 构造里那个 `mapErrors()`）做的是
/// `handler.reject(DioException(..., error: _mapDioErrorToException(e)))` ——
/// 它把 [HttpException] 塞进 `DioException.error`，而 Dio **不会**把它拆出来重抛。
/// 于是 `catch (e) { if (e is HttpException && e.statusCode == 404) … }`
/// 永远为假：判据静默失效，功能看起来「没生效」但没有任何报错。
///
/// （我 2026-10-06 的 404 负缓存第一版就是这么写的：三条用例全红，
///  `Expected: throws HttpException with statusCode 404` / `Actual: <Closure>`，
///  因为闭包返回的是 `DioException`。既有代码 settings_screen.dart 也是用
///  `e.error` 解包的，那才是这个仓库的既定写法。）
///
/// 返回 null 表示这压根不是 HTTP 层异常（超时、连接失败等）。
HttpException? asHttpException(Object? e) {
  if (e is HttpException) return e;
  if (e is DioException) {
    final inner = e.error;
    if (inner is HttpException) return inner;
  }
  return null;
}

class TwitterApi {
  // 缓存存 Future<UserMetaData> 而非结果：同一用户并发 getMetaData 复用
  // 同一个 in-flight 请求，避免并发 miss 全部各自拉取（重复流量）。
  static final Map<String, Future<UserMetaData>> _metaCache = {};
  // 缓存写入时间，配合 _kCacheTtl 过期——原静态缓存无 TTL 无上限，
  // 进程内无限增长且永不失效。
  static final Map<String, DateTime> _metaCacheTime = {};
  static const Duration _kCacheTtl = Duration(minutes: 10);

  // ── 幽灵账号负缓存（2026-10-06）────────────────────────────────────────
  //
  // 标签反查 `/api/tag/<tag>` 会发出一批**点进去必然 404** 的账号：它们在标签
  // 索引里，却不在服务端的 users 表里。实测一页 25 人里 13~15 个如此（失败率
  // 29%~60%，随 offset 变化）。
  //
  // 原来的行为是「失败不进缓存」（见 [getMetaData] 的 catch），本意是让临时
  // 故障能自愈；但对这类账号它是**纯浪费**：每次翻页都把同一批注定失败的请求
  // 重打一遍 —— 这就是「下一页极慢」的机制。一页 25 人 × 15 次注定失败 ×
  // 每次 1~3 秒，且 hydrate 还要等它们全部超时。
  //
  // 所以这里**只对 404 做负缓存**：这类失败是账号自身的状态（不在库里），
  // 不会因为重试而改变；TTL 取得比正缓存短（账号可能被补录进来）。
  // 其他失败（超时/5xx/网络）仍然不进缓存，保持可自愈。
  static final Set<String> _metaMissing = {};
  static final Map<String, DateTime> _metaMissingTime = {};
  static const Duration _kMissingTtl = Duration(minutes: 30);

  /// 该账号是否**确定**不存在（404 负缓存命中）。
  ///
  /// 供列表层过滤掉注定失败的行，也供 hydrate 跳过它们——这样既不再发请求，
  /// 也不会在列表里留下一个点进去就报错的行。
  @visibleForTesting
  static bool isKnownMissing(String username) {
    final at = _metaMissingTime[username];
    if (!_metaMissing.contains(username) || at == null) return false;
    if (DateTime.now().difference(at) >= _kMissingTtl) {
      _metaMissing.remove(username);
      _metaMissingTime.remove(username);
      return false;
    }
    return true;
  }

  static void _markMissing(String username) {
    _metaMissing.add(username);
    _metaMissingTime[username] = DateTime.now();
  }

  /// 仅供测试：清掉静态元数据缓存。
  ///
  /// 缓存是 static final、全实例共享，没有这个入口的话测试之间会互相命中
  /// 别人的缓存 —— api_url_test 用 `getMetaData('alice', forceRefresh: true)`
  /// 写进去的内容，会被 fav_list_test 里不带 forceRefresh 的 `getMetaData('alice')`
  /// 直接读走。现在两边都碰巧拿到 `{}` 才没炸；Dart 不保证测试文件的执行
  /// 顺序，这是埋着的一颗雷。
  @visibleForTesting
  static void resetForTests() {
    _metaCache.clear();
    _metaCacheTime.clear();
    _metaMissing.clear();
    _metaMissingTime.clear();
  }

  late final Dio _dio;

  /// 图站专用客户端：base 是**站点 origin**（[kGalleryBase]），不带
  /// `/api/twitter` 前缀。见 [kGalleryBase] 的路由说明与实测记录。
  ///
  /// 与 [_dio] 共用同一套拦截器（路径归一化 + 异常映射），所以注入测试用的
  /// 假适配器时**两个实例都要注入**，否则图站请求会真发出去。
  late final Dio _gallery;

  /// [adapter] 仅供测试注入假适配器（不发真实请求），生产代码不传。
  TwitterApi({HttpClientAdapter? adapter}) {
    _dio = Dio(BaseOptions(
      baseUrl: kApiBase,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      headers: {'User-Agent': 'TwitterPic/1.0'},
    ));
    _gallery = Dio(BaseOptions(
      baseUrl: kGalleryBase,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 15),
      headers: {'User-Agent': 'TwitterPic/1.0'},
    ));
    if (adapter != null) {
      _dio.httpClientAdapter = adapter;
      _gallery.httpClientAdapter = adapter;
    }

    // 路径归一化：拼到两个实例上，图站端点同样受益。
    //
    // Dio 拼接 baseUrl 与 path 时**不会**自动补斜杠：
    // baseUrl = 'https://x.moonchan.xyz/api/twitter' + path = 'x.json.gz'
    // → 'https://x.moonchan.xyz/api/twitterx.json.gz'（少了 /）。
    // 后端 gin 里这个路径匹配不到任何路由，落到 NoRoute，而 NoRoute 在
    // STATIC_ROOT 未设置时直接 AbortWithStatus(403) —— 于是 metadata / tags /
    // emojis 全部 403。之前只有 getUserList 用了 '/' 所以只有它正常，
    // 详情页"暂无内容"、头像全空、标签空都是这一个原因。
    // 这里统一补前导斜杠，避免以后新增调用再次踩坑。
    InterceptorsWrapper normalize() => InterceptorsWrapper(
      onRequest: (options, handler) {
        final p = options.path;
        final absolute = p.startsWith('http://') || p.startsWith('https://');
        if (!absolute && !p.startsWith('/')) {
          options.path = '/$p';
        }
        handler.next(options);
      },
    );
    _dio.interceptors.add(normalize());
    _gallery.interceptors.add(normalize());

    // 统一异常映射（两个实例共用同一个映射函数）。
    InterceptorsWrapper mapErrors() => InterceptorsWrapper(
      onError: (e, handler) {
        if (e.error is ApiException) {
          handler.reject(e);
        } else {
          handler.reject(DioException(
            requestOptions: e.requestOptions,
            type: e.type,
            error: _mapDioErrorToException(e),
          ));
        }
      },
    );
    _dio.interceptors.add(mapErrors());
    _gallery.interceptors.add(mapErrors());
  }

  Future<List<TwitterUser>> getUserList({String? after}) async {
    final resp = await _dio.get(
      '/',
      queryParameters: {
        'list': 'users',
        if (after != null) 'after': after,
      },
    );
    return _decodeUserList(resp.data, 'getUserList');
  }

  /// 标签云：`GET /api/tag-cloud?limit=N`（别名 `/api/tags/cloud`）。
  ///
  /// **公开接口，不要 auth。** 实测返回 `[{"Tag":"女性","Count":7579}, ...]`，
  /// 键是**大写** `Tag`/`Count`（Go 结构体没写 json tag），由
  /// [TagCount.fromJson] 大小写不敏感地解析。
  ///
  /// [TagCount.count] 是**人数**（该标签下的账号数），不是票数。
  ///
  /// 实测三路一致（2026-10-05）：
  /// - tag-cloud `女性` 的 `Count` = 7591；
  /// - `/api/tag/女性` 的 `total`（该标签下账号列表总数）= **7591**，与前者相等；
  /// - 图站首页自述「显示 120 / 16427 个账号」，而 178 个标签计数总和
  ///   = 23895 ≈ 1.45 × 账号数——正是「一个账号有多个标签就被各计一次」。
  ///
  /// ⚠️ 此前这里写的是「票数/热度，不是用户数」，**那是错的**：把标签计数
  /// 和 emoji poll 的投票数混为一谈了（`by=tag` 只回 15 个用户，是**分页
  /// 上限**，不能反推计数口径）。UI 应当标「N 人」。
  ///
  /// 按 Count **降序**返回（人数多的在前），调用方拿到的顺序可以直接渲染；
  /// 返回顺序本身没有产品含义，排稳只是为了渲染不抖。
  ///
  /// ⚠️ 走 [_gallery]（图站 origin），**不是** [_dio]：这个端点注册在
  /// gallery 自己的 mux 上，挂在 `/api/twitter` 下实测 404。
  Future<List<TagCount>> getTagCloud({int limit = 100}) async {
    final resp = await _gallery.get(
      '/api/tag-cloud',
      queryParameters: {'limit': limit},
    );
    // 展示序（人数降序）是**这个调用点**的决定，不是解析的副作用。
    return sortedByCountDesc(TagCount.listFromJson(resp.data));
  }

  /// 某个标签下的**完整**用户名单（分页）：`GET /api/tag/<tag>?limit=&offset=`。
  ///
  /// 为什么要它而不是 [searchUsersByTag]：`by=tag` 硬上限 15 且**无游标**
  /// （见 [kTagSearchLimit]），拿它当"这个标签下的用户"会静默只显示前 15 个
  /// 却让人以为已经看全。画廊端点能一直翻到 total（实测 女性 total=7580）。
  ///
  /// ⚠️ 走 [_gallery]（图站 origin），**不是** [_dio]：`/api/twitter/tag/<tag>`
  /// 实测 404（见 [kGalleryBase]）。
  ///
  /// 三个实测到的坑，写在这里免得下一个人再踩：
  ///  1. **`page` 参数是摆设**：传 page=1/2/3 回的 `users` 一模一样，只有
  ///     `offset` 真正生效（`offset` 是 0 起的行偏移：offset=24 与 offset=25
  ///     返回的首个用户不同）。所以翻页**只能**用 offset。
  ///  2. **`users` 是裸用户名字符串数组**，不是 `[]User` 对象 —— 没有 tags、
  ///     nick、avatar。要权重/昵称还得另查（见 [hydrateUsernames]）。
  ///  3. **`total` 与标签云 Count 同源，是人数口径**（实测 `女性` 两者均为
  ///     7591），可以直接当"N 人"显示。
  ///
  /// [offset] 是条数偏移，[limit] 是本页条数上限。
  Future<TagUserPage> getUsersByTagPage(
    String tag, {
    int limit = 25,
    int offset = 0,
  }) async {
    if (tag.isEmpty) {
      return const TagUserPage(usernames: <String>[], offset: 0);
    }
    final resp = await _gallery.get(
      // 标签名含中文/空格等必须按 UTF-8 百分号编码 —— Dio 不会替你转义
      // 路径段里的 query 参数，这里手动拼 Uri.encodeComponent。
      '/api/tag/${Uri.encodeComponent(tag)}',
      queryParameters: {'limit': limit, 'offset': offset},
    );
    final data = _asJsonMap(resp.data, 'getUsersByTagPage($tag)');
    final usernames = _asStringList(data['users']);
    return TagUserPage(
      usernames: usernames,
      total: _asInt(data['total']),
      offset: offset,
    );
  }

  /// 把 [getUsersByTagPage] 给的裸用户名补成带 `tags` 的 [TwitterUser]。
  ///
  /// 画廊端点只给名字，而本地过滤**必须**看 `tags` 键才能判定命中，所以
  /// 选中标签后需要把用户补齐。
  ///
  /// ## 两段式补齐，各走最便宜的那个端点
  ///
  /// 1. **权重**走批量 `GET /api/tags?keys=a,b,c`（图站，别名 `/api/account-tags`），
  ///    **一次请求拿整页**。实测响应是 `{"Puppy_yua":{"女性":4,...}, ...}`，
  ///    被封账号会被服务端直接从 map 里省略（等价于"没有这个账号"）。
  /// 2. **昵称/头像**走 `GET /api/twitter/<user>.json.gz` 逐个（`account_info`
  ///    **没有** tags 字段——实测只有 name/nick/date/followers/friends/
  ///    profile_image/statuses_count，所以权重必须另找接口，不能拿它顶）。
  ///
  /// ⚠️ 这一步是**旧实现最贵的部分**：原 `hydrateUsernames` 对每个用户名发
  /// **两个**请求（元数据 + `getTagWeights`），一页 25 个用户名就是 50 次往返；
  /// 而列表行 `_UserTile` 还会**各自再拉一次** `getMetaData`（有 10 分钟进程内
  /// 缓存兜底，但首屏仍是 25 次）。权重改批量后，每页从 50 次降到 25 次，
  /// 且这一步现在是唯一还需要的逐个请求。
  ///
  /// 逐项吞错：某个用户的元数据 404/500 不该让整页白拉，失败的那个直接跳过
  /// （标签页列表只需要能渲染用户名 + 标签）。返回值因此可能**短于**输入长度
  /// —— 调用方必须以返回值为准。
  ///
  /// [concurrency] 是逐个元数据请求的并发度，默认 6。
  Future<List<TwitterUser>> hydrateUsernames(
    List<String> usernames, {
    int concurrency = 6,
  }) async {
    if (usernames.isEmpty) return const <TwitterUser>[];
    // 去重后再发：反查分页可能跨页重复（服务端排序在同权重时按 username，
    // 但并发写入会让 offset 分页漏/重），重复的 key 只会白占批量请求长度。
    final unique = <String>[];
    final seen = <String>{};
    for (final u in usernames) {
      if (u.isNotEmpty && seen.add(u)) unique.add(u);
    }

    // ① 批量取权重。失败不致命：退化成"没有 tags"，此时标签过滤会因
    //    `tags` 为空而过滤不出任何人 —— 所以要把失败如实抛给 UI，
    //    否则表现为"选了这个标签但一条都搜不到"，静默假空。
    Map<String, Map<String, int>> weights;
    try {
      weights = await getTagWeightsBatch(unique);
    } catch (e) {
      // ⚠️ 必须抛**具体**子类：ApiException 是 sealed class，不能直接实例化。
      throw UnknownException('批量取标签权重失败：$e');
    }

    // ② 逐个取昵称/头像，失败降级为只有用户名 + 权重。
    //
    // ⚠️ 但**404（账号不存在）不再降级**，直接剔除该行（2026-10-06）。
    // 原来这里是 `catch (_) {}` 一律吞掉，于是「在标签索引里、却不在服务端
    // users 表里」的幽灵账号照样进列表：点进去必然 404，而用户看到的只是一个
    // 点了就报错的行。判据是 `e is HttpException && e.statusCode == 404`
    // —— 只有「这个账号不存在」才剔除，超时/5xx 仍按原样降级保留行，
    // 避免临时故障把整页洗白。
    final out = <TwitterUser>[];
    var dropped = 0;
    for (var i = 0; i < unique.length; i += concurrency) {
      final chunk = unique.skip(i).take(concurrency);
      final settled = await Future.wait(chunk.map((name) async {
        UserMetaData? meta;
        var gone = false;
        try {
          meta = await getMetaData(name);
        } catch (e) {
          // ⚠️ 同上：必须解包 DioException，否则这个判据永远为假，
          // 幽灵账号会照旧进列表。
          if (asHttpException(e)?.statusCode == 404) gone = true;
        }
        final info = meta?.accountInfo;
        return (
          gone: gone,
          user: TwitterUser(
            username: name,
            nick: info?.nick,
            avatar: info?.avatar,
            totalUrls: info?.totalUrls,
            // 键存在即命中的口径下，服务端省略的键（被封 / 不存在）与"权重 0"
            // 都只能读成"没有这个标签"，用空表兜住，不让它去读 undefined。
            tags: weights[name] ?? const <String, int>{},
          ),
        );
      }));
      for (final r in settled) {
        if (r.gone) {
          dropped++;
          continue;
        }
        out.add(r.user);
      }
    }
    if (dropped > 0) {
      // 一并记进诊断日志，便于核对「服务端标签索引里有、users 表里没有」的规模。
      debugPrint('[hydrate] 剔除 $dropped 个 404 账号（本批 ${unique.length} 个）');
    }
    return out;
  }

  /// 批量取多个账号的标签权重：`GET /api/tags?keys=a,b,c`（图站）。
  ///
  /// 实测响应 `{"userA":{"tag":w,...}, "userB":{...}}`；**被封账号的键会被服务端
  /// 直接省略**（go/gallery/main.go 的 `handleGetAccountTags` 调
  /// `cfg.vis.hidden(u)` 跳过），所以查不到的键一律回落空表，不当成错误。
  ///
  /// 分批以免 URL 过长：每批 [chunk] 个 key（默认 50），批次之间串行，
  /// 避免把 URL 顶到几 KB——那既可能撞服务端/网关上限，也让 Cloudflare 缓存
  /// 命中率崩掉。
  Future<Map<String, Map<String, int>>> getTagWeightsBatch(
    List<String> usernames, {
    int chunk = 50,
  }) async {
    final out = <String, Map<String, int>>{};
    if (usernames.isEmpty) return out;
    final size = chunk <= 0 ? usernames.length : chunk;
    for (var i = 0; i < usernames.length; i += size) {
      final part = usernames.skip(i).take(size).toList();
      final resp = await _gallery.get(
        '/api/tags',
        // keys 是逗号分隔的**用户名**。Twitter 用户名只含 [A-Za-z0-9_]，
        // 拼进 query 不会引入分隔符歧义；仍交给 Dio 做编码。
        queryParameters: {'keys': part.join(',')},
      );
      final raw = _asJsonMap(resp.data, 'getTagWeightsBatch');
      raw.forEach((k, v) => out[k] = parseTagWeights(v));
    }
    return out;
  }

  /// 搜索用户：`GET /?by=<by>&search=<search>`（by 现有取值：username / nick / tag）。
  Future<List<TwitterUser>> searchUserList(String by, String search) async {
    if (search.isEmpty) return [];
    final resp = await _dio.get(
      '/',
      queryParameters: {'by': by, 'search': search},
    );
    return _decodeUserList(resp.data, 'searchUserList($by)');
  }

  /// 按标签查用户：`GET /?by=tag&search=<tag>`，响应与 by=username|nick 完全同构
  /// （`[]User`，每项带 `tags: {标签: 权重}`）。
  ///
  /// 新版服务端契约：精确匹配标签、权重降序、同权重按 username 升序、只回
  /// status='SUCCESS'、LIMIT 15 且**无游标**；空结果回 `[]`。
  /// 线上旧二进制不认识 by=tag，会返回 `200 + body null`——经 [_decodeUserList]
  /// 抛 [UnexpectedResponseException]，调用方（UI）据此提示"服务端未就绪"，
  /// 而不是误报"这个标签下没人"。
  Future<List<TwitterUser>> searchUsersByTag(String tag) async {
    if (tag.isEmpty) return [];
    final resp = await _dio.get(
      '/',
      queryParameters: {'by': 'tag', 'search': tag},
    );
    return _decodeUserList(resp.data, 'searchUsersByTag($tag)');
  }

  Future<UserMetaData> getMetaData(String username, {String? t, bool forceRefresh = false}) async {
    // 负缓存命中：直接抛，不再发那个注定 404 的请求。
    // 抛的是 [HttpException] 404，与真实请求失败的形态**一致**——这样
    // hydrate 的 `catch (_) {}` 照旧能吞掉它，行为差异只有「少一次往返」。
    if (!forceRefresh && isKnownMissing(username)) {
      throw HttpException(404, '账号 $username 不存在（已知 404 负缓存命中）');
    }
    if (!forceRefresh) {
      final cached = _metaCache[username];
      final cachedAt = _metaCacheTime[username];
      if (cached != null &&
          cachedAt != null &&
          DateTime.now().difference(cachedAt) < _kCacheTtl) {
        return cached;
      }
      // 过期丢弃，重新拉取。
      // 注意：这里**故意不** remove 那个过期 future —— 它可能还在飞，一旦它的
      // catch 无条件 remove，就会把下面刚写入的新 future 一起删掉（stale
      // callback）。清缓存的动作交给 catch 里的身份判定。
    }

    final inFlight = _fetchMetaData(username, t);
    _metaCache[username] = inFlight;
    _metaCacheTime[username] = DateTime.now();
    try {
      return await inFlight;
    } catch (e) {
      // **只有 404 进负缓存**（见 [_metaMissing] 的说明）：这类失败是账号自身的
      // 状态，重试不会改变；超时/5xx/网络失败仍然不进缓存，保持可自愈。
      // ⚠️ 必须走 asHttpException：拦截器把 HttpException 裹在
      // DioException.error 里，直接 `e is HttpException` 永远为假。
      final http = asHttpException(e);
      if (http != null && http.statusCode == 404) {
        _markMissing(username);
      }
      // 失败不进缓存，下次调用重试。
      // 只在"缓存里还是我自己"时才清：TTL 过期时会写入新 future，旧 future
      // 的失败回调若无条件 remove 会把新 future 误删，表现为偶发的重复拉取
      // 与 UI 闪烁。
      if (identical(_metaCache[username], inFlight)) {
        _metaCache.remove(username);
        _metaCacheTime.remove(username);
      }
      rethrow;
    }
  }

  /// 把响应体解析成 `Map<String, dynamic>`。
  ///
  /// Dio 在不同平台把 JSON 对象解成 `Map<String, dynamic>`、
  /// `Map<dynamic, dynamic>` 或（content-type 未识别时）未解码的 String。
  /// Dart 的泛型判定是严格的：`Map<dynamic, dynamic> is Map<String, dynamic>`
  /// 为 false，所以 `is! Map<String, dynamic>` 会把前两类误判成"非 JSON 响应"，
  /// 导致 metadata 全部失败——详情页显示"暂无内容"且头像全缺。
  /// （列表接口历史上用宽松的 `is! List` 判定不受该坑影响，但会把 200 null
  /// 吞成空列表，现已收紧，见 [_decodeUserList]。）
  static Map<String, dynamic> _asJsonMap(dynamic raw, String context) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return Map<String, dynamic>.from(raw);
    if (raw is String) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    throw UnknownException(
    '$context 返回非 JSON 响应（实际类型 ${raw.runtimeType}）',
    );
  }

  /// 取字符串列表：`users` 字段实测是裸用户名字符串数组。缺字段/类型不符
  /// 走空列表，绝不抛异常打乱整页渲染。
  static List<String> _asStringList(dynamic raw) {
    if (raw is! List) return const <String>[];
    final out = <String>[];
    for (final e in raw) {
      if (e is String && e.isNotEmpty) out.add(e);
    }
    return out;
  }

  /// 取可空 int（缺失时返回 null，允许上游用 0 兜底）。
  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v');
  }

  /// 解析用户列表类响应（getUserList / searchUserList / searchUsersByTag 共用）。
  ///
  /// 只有 JSON 数组才是合法结果，`[]` 表示"确实没有结果"；`null` 或非数组
  /// 抛 [UnexpectedResponseException]——线上旧二进制对未知 by（如尚未上线的
  /// by=tag）静默返回 `200 + body null`，绝不能被吞成空列表造成"服务端未就绪"
  /// 被显示成"查无此人/这个标签没人"的假绿。
  static List<TwitterUser> _decodeUserList(dynamic decoded, String context) {
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((e) => TwitterUser.fromJson(_asJsonMap(e, '$context entry')))
          .toList();
    }
    if (decoded == null) {
      throw UnexpectedResponseException(
        '$context 返回 body null：服务端可能不认识该查询'
        '（线上旧二进制对未知 by 静默返回 200 null），这不代表"没有结果"',
      );
    }
    throw UnexpectedResponseException(
      '$context 返回非数组 JSON 响应（实际类型 ${decoded.runtimeType}）',
    );
  }

  Future<UserMetaData> _fetchMetaData(String username, String? t) async {
    final resp = await _dio.get(
      '/$username.json.gz',
      queryParameters: {
        't': t ?? DateTime.now().toIso8601String().split('T')[0],
      },
    );
    return UserMetaData.fromJson(_asJsonMap(resp.data, 'getMetaData($username)'));
  }

  /// 添加/更新一个用户的元数据。
  ///
  /// ── 为什么 [tags] 是必填、而不是可选 ──────────────────────────────────────
  ///
  /// 服务端 `POST /api/twitter/:username` 在**不带** `do_not_tag` /
  /// `do_not_renew` 时（即"首次添加"这条分支）会：
  ///  1. 已经有标签就返回 `200 {"message":"already has tags, skipped"}`；
  ///  2. 解 body 失败 → 400；解出**空 map** → 400 `"你没加tag，这是不行的"`。
  ///
  /// 也就是说**不带标签必然被拒**。实测生产：
  /// ```
  /// POST /api/twitter/<user>（无 body）→ 400 {"error":"EOF"}
  /// ```
  /// 所以这里用必填命名参数把这条约束**编译进调用点**——以前两处
  /// `createMetaData(username)` 光秃秃地调用，服务端只会回一句
  /// 「你没加tag」，用户看到的是「添加失败: HTTP 400」。
  ///
  /// [tags] 为空会在本地先抛 [ArgumentError]，不白跑一次网络请求。
  ///
  /// 三个分支（服务端语义，别搞混）：
  /// | 参数 | 语义 |
  /// |---|---|
  /// | 默认（都不传） | **首次添加**：必须有标签，写完排队抓取 |
  /// | `doNotTag: true` | 只重抓数据，不动标签（用户必须已存在，否则 403） |
  /// | `doNotRenew: true` | 只补标签，不重抓（用于给已有账号加标签） |
  Future<void> createMetaData(
    String username, {
    required Map<String, int> tags,
    bool doNotTag = false,
    bool doNotRenew = false,
  }) async {
    // 本地先拦：空标签服务端一定 400，没必要浪费一次往返。
    if (!doNotTag && !doNotRenew && tags.isEmpty) {
      throw ArgumentError(
        '添加用户必须带标签：服务端首次添加分支会拒绝空标签'
        '（400「你没加tag，这是不行的」）。',
      );
    }
    final body = tags.isEmpty ? null : tags;
    await _dio.post(
      '/$username',
      data: body,
      queryParameters: {
        if (doNotTag) 'do_not_tag': 'true',
        if (doNotRenew) 'do_not_renew': 'true',
      },
    );
    // 写操作成功后清缓存：标签/屏蔽/内容更新后 UI 读缓存会得到脏数据。
    _metaCache.remove(username);
    _metaCacheTime.remove(username);
  }

  Future<Map<String, dynamic>> getTags(String username) async {
    final resp = await _dio.get('/tags/$username');
    return _asJsonMap(resp.data, 'getTags($username)');
  }

  /// [getTags] 的 typed 读法：取 `GET /tags/<username>` 响应里的 `tags` 字段
  /// 解析成 `Map<String, int>`。
  ///
  /// 契约要点：端点形态不变；权重**可为负**且服务端目前不过滤 0，客户端原样
  /// 保留键；**不存在的用户返回 500（HttpException），不是 404**——别按 404
  /// 判"无此人"。[getTags] 原样透传裸 Map 的旧签名保持不变，调用点按需迁移。
  Future<Map<String, int>> getTagWeights(String username) async {
    final data = await getTags(username);
    return parseTagWeights(data['tags']);
  }

  Future<Map<String, dynamic>> getEmojis(String username) async {
    final resp = await _dio.get(
      '/emojis',
      queryParameters: {'username': username},
    );
    return _asJsonMap(resp.data, 'getEmojis($username)');
  }

  Future<void> voteUpEmoji(String username, String emoji) async {
    await _dio.post(
      '/emojis',
      queryParameters: {'username': username, 'emoji': emoji},
    );
  }

  Future<Map<String, EmojiPeriodData>> getRanking() async {
    final resp = await _dio.get('/emojis.json.gz');
    final raw = _asJsonMap(resp.data, 'getRanking');
    return raw.map((k, v) =>
        MapEntry(k, EmojiPeriodData.fromJson(_asJsonMap(v, 'ranking[$k]'))));
  }

  /// 将 DioException 映射为结构化 ApiException。
  ApiException _mapDioErrorToException(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return const NetworkException('连接超时');
      case DioExceptionType.receiveTimeout:
        return const NetworkException('响应超时');
      case DioExceptionType.connectionError:
        return const NetworkException('网络不可达');
      case DioExceptionType.badResponse:
        // **必须带上服务端给的那段文字。**
        //
        // 服务端所有可执行的提示都放在响应体的 error/message 字段里：
        //   400 「你没加tag，这是不行的」/ 「invalid tags body」
        //   403 「Access Denied」（ipban）
        //   429 「too many requests」（limit/middleware.go）
        // 而 statusMessage 对这些响应**永远是空串**，于是原实现拼出来的
        // 文案是 `HTTP 429: ` —— 冒号后面什么都没有。429 限流、400 没带标签、
        // 403 被封禁，三种完全不同的原因在用户眼里长得一模一样。
        return HttpException(
            e.response?.statusCode ?? 0,
            _describeHttpFailure(e.response));
      default:
        return UnknownException(e.message ?? '未知错误');
    }
  }

  void dispose() {
    _dio.close(force: true);
    // 图站客户端也是这个实例建的，不关就是漏一个连接池（测试里逐例 new 一个
    // api 时尤其明显）。
    _gallery.close(force: true);
  }



  /// 把一次 HTTP 失败渲染成**人话**：状态码 + 服务端正文里的 error/message。
  ///
  /// 服务端用 `gin.H{"error": ...}` 或 `{"message": ...}` 回话，正文可能是
  /// String，也可能是嵌套结构或列表，所以逐层往下挖，取到第一段非空文本。
  /// 全挖不到就退回 statusMessage，再退回一句通用文案 —— 绝不让用户看到
  /// 裸的 `HTTP 429: `。
  static String _describeHttpFailure(Response<dynamic>? resp) {
    final code = resp?.statusCode ?? 0;
    var detail = _firstText(resp?.data);
    if (detail.isEmpty) {
      final sm = resp?.statusMessage?.trim() ?? '';
      detail = sm.isEmpty ? _fallbackHttpText(code) : sm;
    }
    return 'HTTP $code: $detail';
  }

  static String _fallbackHttpText(int code) {
    switch (code) {
      case 400:
        return '请求被拒绝（参数不合法，例如添加用户时没带标签）';
      case 403:
        return '被拒绝访问（IP 被限流或已封禁）';
      case 404:
        return '资源不存在';
      case 429:
        return '操作过于频繁，已被限流，请稍后再试';
      default:
        return code >= 500 ? '服务端错误，请稍后再试' : '请求失败';
    }
  }

  /// 从可能是 String / Map / List 的响应体里取出第一段非空文本。
  static String _firstText(dynamic data, [int depth = 0]) {
    if (depth > 4) return '';
    if (data == null) return '';
    if (data is String) {
      final t = data.trim();
      return t.isEmpty ? '' : t;
    }
    if (data is Map) {
      // 优先 error / message —— 服务端所有可执行提示都在这两个键里。
      for (final k in const ['error', 'message', 'detail', 'msg']) {
        final v = data[k];
        if (v != null) {
          final t = _firstText(v, depth + 1);
          if (t.isNotEmpty) return t;
        }
      }
      for (final v in data.values) {
        final t = _firstText(v, depth + 1);
        if (t.isNotEmpty) return t;
      }
      return '';
    }
    if (data is Iterable) {
      for (final v in data) {
        final t = _firstText(v, depth + 1);
        if (t.isNotEmpty) return t;
      }
    }
    return '';
  }
}
