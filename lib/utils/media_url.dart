// media_url.dart
// 媒体 URL：列表用 twimg 档位缩略图，详情/预览用原图 origin。
//
// ── 为什么 v0.6.1 又把 name= 档位捡回来了 ────────────────────────────────
//
// 历史：这里曾经按「卡片像素宽度 × 设备像素比」挑 small/medium/large 档，
// 动机是列表按原图拉会白屏（见 README 的实测表与 git历史）。后来改为全部
// origin，理由是"同一张图只对应一个 canonical URL，缓存 key 唯一"。那个理由
// 对**图站 SSR** 成立（每个访客只请求自己要渲染的那几张），对移动端 feed 不成立：
// 一屏十几张卡片 × 2MB 原图，墙内经 ECH 慢慢下，就是"列表半天出不来画面"。
//
// 所以这一版把职责切开：
//   * **列表**（[thumbOf]）→ 小档位，一屏的字节数掉到 1/20，秒出；
//   * **详情与全屏预览**（原 URL）→ 仍是 origin，看清画质不受影响。
//
// 两个缓存不是浪费：缩略图是卡片用的，原图是预览/下载用的，尺寸与用途都不同。
//
// 口径与图站 JS 保持一致（app.js 的 thumbURL）：只替换 `name=` 这一**个**
// query 参数的值，其余（`format=`、`token=`、`?tag=`）原样保留 —— 这一点是
// 硬要求，见 [rewriteName] 下方注释。
//
// 唯一保留下来的判断是"能不能预取"：视频动辄几 MB，预热它们只会把流量打爆，
// 所以预取前先用 [isImage] 过滤。

class MediaUrl {
  MediaUrl._();

  /// 是否是 pbs 图片（可以预取；视频不在预取范围内）。
  ///
  /// 按 **host** 精确判定，不用子串匹配：`contains('pbs.twimg.com')` 会被
  /// `https://evil.com/pbs.twimg.com/stolen.jpg` 和
  /// `https://pbs.twimg.com.evil.com/x.jpg` 骗过，让非 CDN 资源走预取路径
  /// 白白吃流量（这条预取链走的是本机代理，多拉一份就是多一分带宽）。
  ///
  /// 只判定原始 twimg 域名：调用方拿的是后端返回的原始 URL，
  /// 重写成本机代理地址是在调用点之后才发生的。
  static bool isImage(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    // video / video-cf / amplify 都是视频 CDN（视频动辄几 MB，预热会打爆流量）。
    if (uri.host == 'video.twimg.com' ||
        uri.host == 'video-cf.twimg.com' ||
        uri.host == 'abs.twimg.com') return false;
    return uri.host == 'pbs.twimg.com';
  }

  // ─── 缩略图档位 ──────────────────────────────────────────────────────────

  /// 列表卡片用的缩略图档位。
  ///
  /// `small`（约 480px 宽）是列表的甜点：手机上一张卡片约 350~400 物理像素宽，
  /// `small` 放大后仍够清晰，却只有原图 1/10 左右的字节。更大的 `large` 对列表
  /// 是浪费（多一倍字节换肉眼几乎看不出差别）。
  ///
  /// 这是**显示用**的 URL，不要拿它下载/分享 —— 那会拿到缩略图。
  static const String kListThumbName = 'small';

  /// 原图档位。twimg 的 origin 就是最大尺寸，保持既有口径不变。
  static const String kOriginName = 'orig';

  /// 把图片 URL 换成给定 twimg 档位；非 twimg 图片原样返回。
  ///
  /// [name] 见 [kListThumbName] / [kOriginName]。
  static String thumbOf(String url, {String name = kListThumbName}) {
    if (!isImage(url)) return url;
    return rewriteName(url, name) ?? url;
  }

  /// 把 URL 的 `name=` 参数换成 [name]。**只动这一个参数**，其余原样保留。
  ///
  /// 返回 null 表示这个 URL 改不动（解析失败、或 query 里有重复键），调用方应
  /// 回退到原 URL —— 不要退化成"整条 query 重写"，那会连 `token=` 一起弄丢，
  /// 而 token 丢了 CDN 会 403（表现是"所有图都加载失败"）。
  ///
  /// 刻意**不**自己拼 `?name=xxx`：现有 URL 可能带 `?format=jpg&name=orig`
  /// （无 `?` 只有 `&`）、或什么都不带。三种形态分别处理，且都不动其他参数。
  static String? rewriteName(String url, String name) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    // queryParameters 会把重复键压成一个（取最后一个）。twimg 的 URL 里
    // 重复键只可能出现在 token 这类签名参数上，丢掉前一个会直接 403，
    // 所以碰到重复键就不改这个 URL —— 宁可继续用原图，也不要弄出坏签名。
    if (_hasDuplicateQueryKey(uri)) return null;

    final params = <String, String>{
      ...uri.queryParameters,
      'name': name,
    };
    final rebuilt = uri.replace(queryParameters: params);
    // params 里一定含 name，所以 query 段不会为空；这里仍判一次是为了防止
    // 未来有人改动 params 后产出 `...jpg?` 这种畸形 URL 而没人发现。
    if (rebuilt.query.isEmpty) return null;
    return rebuilt.toString();
  }

  /// URI 的 query 里是否有重复键。
  static bool _hasDuplicateQueryKey(Uri uri) {
    if (uri.query.isEmpty) return false;
    final seen = <String>{};
    for (final pair in uri.query.split('&')) {
      if (pair.isEmpty) continue;
      final key = pair.split('=').first;
      if (!seen.add(key)) return true;
    }
    return false;
  }

  // ─── 视频封面 ────────────────────────────────────────────────────────────

  /// 从视频 URL 推导 Twitter 的封面图 URL；推不出来返回 null。
  ///
  /// ── 为什么需要推导 ──────────────────────────────────────────────────────
  ///
  /// 实测生产数据（`GET /api/twitter/<user>.json.gz`）里timeline 项只有
  /// `url` / `date` / `tweet_id` / `type` 四个字段，**没有 poster**；
  /// gallery_dl 的 twitter extractor 也**根本不产出poster**（全文件 0 处
  /// "poster"）。所以服务端与抓取链都不提供封面 URL，只能从视频 URL 里的
  /// 视频 id 推导。
  ///
  /// twimg 的封面约定：
  /// ```
  /// amplify_video/<id>/vid/... .mp4  →  /amplify_video_thumb/<id>/img/photo1.jpg
  /// ext_tw_video/<id>/...    .mp4  →  /ext_tw_video_thumb/<id>/img/photo1.jpg
  /// ```
  ///
  /// **推不出来时必须返回 null**（调用方退回原路径），绝不能拼一个看起来
  /// 像那么回事的 URL —— 错的 URL 会 404，而"404 之后还占着解码器槽位等重试"
  /// 比直接用原路径更糟。
  ///
  /// 这条推导**未在本机实测**（本机所有 twimg 域名都不通，这正是 ECH 代理的
  /// 存在理由）。所以调用方必须容忍它失败：加载不出就退回"用解码器抓一帧"
  /// 的旧路径（见 twitter_video.dart）。这是本项目一贯的兜底纪律。
  static String? videoPosterOf(String videoUrl) {
    final uri = Uri.tryParse(videoUrl);
    if (uri == null) return null;
    final m = RegExp(r'/(amplify_video|ext_tw_video)/(\d+)/').firstMatch(uri.path);
    if (m == null) return null;

    final id = m.group(2)!;
    final prefix = '${m.group(1)}_thumb';
    // name=small：封面只是卡片上的一小块，没必要按原图拉。
    return 'https://pbs.twimg.com/$prefix/$id/img/photo1.jpg?format=jpg&name=small';
  }
}
