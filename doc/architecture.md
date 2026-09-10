# 架构

本文写清楚三条链路：**媒体**（走 ECH）、**API**（直连）、**本机代理内部**，
以及几条不能碰的红线。相关事故案例见 [troubleshooting.md](troubleshooting.md)。

## 1. 媒体链路：Dart → 本机代理 → ECH → video-cf.twimg.com

```
┌─ Dart（Flutter 进程）───────────────────────────────────────────────┐
│                                                                    │
│  Image(image: ProgressiveImageProvider(url))                       │
│  VideoPlayerController.networkUrl(uri)                             │
│            │                                                       │
│            │ EchUrl.rewrite(url, port)                             │
│            │   丢掉 scheme/host，只留 path + query                  │
│            ▼                                                       │
│  http://127.0.0.1:<port>/media/<id>?format=jpg&name=medium         │
└────────────┬───────────────────────────────────────────────────────┘
             │ 明文 HTTP（本机回环）
┌────────────▼─ Go 代理（同一进程，c-shared）─────────────────────────┐
│  net/http 监听 127.0.0.1:8443（占用则回退 :0 随机端口）             │
│  路由：/ → 内置说明页；/logs → Go 日志；/api/ → 自建后端；其余 → 媒体 │
│                                                                    │
│  echProxyHandler:                                                  │
│    Referer: https://x.com                                          │
│    User-Agent: Mozilla/5.0 (TwitterPic)                            │
│    Accept-Encoding: identity        ← 否则 Go 自动 gzip 会删掉长度   │
│    Range: <透传>                    ← ExoPlayer 必需               │
│            │                                                       │
│            ▼ cloudflare_ech.Do()                                   │
└────────────┬───────────────────────────────────────────────────────┘
             │ TLS 1.3 + ECH（外层 SNI = cloudflare-ech.com）
┌────────────▼───────────────────────────────────────────────────────┐
│ https://video-cf.twimg.com/media/<id>?format=jpg&name=medium       │
│ （pbs.twimg.com 与 video.twimg.com 是同一 CDN 后端，改域名即可命中） │
└────────────────────────────────────────────────────────────────────┘
```

### 为什么必须挡一层本机代理

Dart 的 `SecureSocket` 不暴露 ECH config 注入接口，Dart 层做不了 ECH；而播放器
（ExoPlayer / video_player_win）只会说标准 HTTP。于是：Go 负责 ECH，Dart 侧只跟
`http://127.0.0.1:<port>` 说话。**代理必须是明文 HTTP**——Dart 侧写的永远是 `http://`。

### URL 改写规则（`lib/utils/ech_url.dart`）

```dart
// https://pbs.twimg.com/media/ID?format=jpg&name=orig
//   → http://127.0.0.1:8443/media/ID?format=jpg&name=orig
static String rewrite(String url, int port, {String host = '127.0.0.1'}) =>
    'http://$host:$port${uri.path}${uri.hasQuery ? '?${uri.query}' : ''}';
```

- **必须丢域名**：代理把所有请求都拼到 `https://video-cf.twimg.com` 上，原始域名留在
  path 里会变成 `video-cf.twimg.com/pbs.twimg.com/media/...` → 404。
- **必须保留 query**：`?format=jpg&name=orig` 丢了就是 404（历史上真丢过）。
- **`port == null` 时不要退化成直连**：墙内直连 twimg 必死（实测 000），退化成直连
  只会得到一个超时，不如明确显示"代理未启动"。

## 2. API 链路：直连，绝不进代理

```
Dio(baseUrl: 'https://x.moonchan.xyz/api/twitter')
  → 用户列表 / 元数据 / 标签 / emoji / 排行
```

- 自建域名可直接访问，不需要 ECH，多一跳没有收益。
- 代理里虽然有 `/api/` 路由（给内置演示页用），但 Flutter 的 API **不走它**。
- Dio 拼接 `baseUrl + path` **不会补斜杠**，所有 path 必须自己以 `/` 开头；
  构造函数里加了 `onRequest` 拦截器兜底归一化（事故见 troubleshooting 案例 1）。

## 3. 本机代理内部（`ech-proxy/cmd/ech-flutter-shared/main.go`）

导出符号（12 个，Dart 侧在 `lib/services/proxy_manager.dart` 按名字绑定）：

| 分类 | 符号 |
| --- | --- |
| 初始化 | `ECHSetDohURL` `ECHInit` `ECHInitWithBootstrap` `ECHInitReady` `ECHInitLastError` |
| 代理生命周期 | `StartProxy` `StopProxy` `GetProxyPort` `IsEchReady` |
| 日志 | `ECHGetLogCount` `ECHGetLog` `FreeCString` |

启动顺序（`ProxyManager.start`）：
`_loadLib()` → `_initEch()`（可带 bootstrap IP）→ `_waitForInit()`（轮询 `ECHInitReady`）
→ `_startProxyFfi(bootstrapIp)` → 端口写进 `portNotifier`。

### 三条红线

1. **cgo 导出函数内 panic 会 abort 整个进程**。所有导出都 `defer guardPanic(...)` +
   具名返回值；`ECHInit` 的子 goroutine、`Serve()` 的每个连接 goroutine 也各自 recover。
   `logBuffer` 的追加与清空必须在 `logMu` 内（曾因无锁 `logBuffer = nil` 撕裂 slice
   header，导致 `ECHGetLog` 越界 panic → 启动偶发闪退）。
2. **`Accept-Encoding: identity`**：不让 Go transport 自动 gzip。自动压缩会顺手删掉
   `Content-Length`/`Content-Encoding`，播放器估不出长度就不播。
3. **`Range` 透传 + 206**：MP4 的 `moov` 常在文件尾，ExoPlayer 必须先分段拿到它。
   不透传则上游回整包 200，视频永远停在"加载中"。

### 日志

代理对每条媒体请求写两行，是排查"到底走没走 ECH"的唯一权威依据：

```
→ https://video-cf.twimg.com/media/xxx?format=jpg&name=medium (from 127.0.0.1:34567)
← 200 https://video-cf.twimg.com/media/xxx?format=jpg&name=medium (182042 B)
```

Dart 侧通过 `ECHGetLogCount`/`ECHGetLog` 读同一个环形缓冲（设置页「调试日志」），
`/logs` 端点也返回它。

## 4. Dart 侧的关键组件

### `ProgressiveImageProvider`（`lib/widgets/progressive_image.dart`）

Flutter 的 `NetworkImage` 会先 `consolidateHttpClientResponseBytes`（读完整包）再解码，
所以慢网络下只能给一块空白。这里自己读流：

- 每收一块就 `ui.ImmutableBuffer.fromUint8List(当前缓冲)` → `decode()` → `setImage()`，
  已下载部分立刻可见；JPEG 不完整数据 Skia 会部分解码，未下载区域填中性灰。
- 节流（`ProgressiveDecodeThrottle`）：增量 ≥24KB、增量 ≥ 已解码量的 1/4、间隔 ≥120ms。
  部分解码＝整张重解，不节流会打满 CPU。
- 完整数据必须再解一次（PNG 只在数据齐全时可解），失败才 `reportError`。
- `==`/`hashCode` 只按 URL，因此仍命中 `ImageCache`：滚回来不重新下载。
- 缓存淘汰时 `dispose()` 不在本版本可用（`ImageStreamCompleter` 无公开 `dispose`），
  所以下载不取消，改为 30s 无数据中断 + 空响应报错。

### `MediaUrl`（`lib/utils/media_url.dart`）

线上数据形态（抽查 6 用户 / 2209 条）：图片 `pbs.twimg.com/media/<id>?format=jpg&name=orig`，
视频 `video.twimg.com/.../<id>.mp4?tag=29`（238 条连 query 都没有）。

- `gridFor(url, neededPixels)`：按卡片实际像素宽度取最小够用档（≤680 `small`、
  ≤1200 `medium`、否则 `large`），`neededPixels = MediaQuery 逻辑宽 × 设备像素比`。
- 视频（`video.twimg.com`）**一律不改写**。判定只看域名，不要求已有 `name=` 参数。
- 缩略图若取不到，`TwitterImage` 的错误重试会回退到原图再试一次。

### 图片/视频渲染的红线

| 场景 | 不能做 | 原因 |
| --- | --- | --- |
| 列表里的图片 | 用 `Stack(fit: StackFit.expand)` 自适应高度 | ListView item 高度无界，expand 把 `height=∞` 当紧约束传下去 → 渲染失败、整片空白 |
| 视频画面 | 用 `FittedBox` 量 `VideoPlayer` | `VideoPlayer` 是 `Texture`，`TextureBox.sizedByParent`（取 `constraints.biggest`），无界约束下尺寸为 `∞` → 全屏黑屏 |
| 全屏视频 | 卡片和全屏同时挂 `VideoPlayer(同一个 controller)` | 同一 texture 渲染两次 → 鬼影 / 全屏全黑 |
| 全屏图片 | 在 `PageView` 里放 `InteractiveViewer` | 它的 scale 识别器会抢走单指拖动，翻页永远失效 |

正确写法：图片用 `AspectRatio` 给确定高度；视频用 `Center + AspectRatio + VideoPlayer`；
全屏图片用 `PageView`（左右滑）+ 竖直拖动检测（上下滑）+ 双击缩放。

## 5. 缓存层次

| 层 | 位置 | 说明 |
| --- | --- | --- |
| 元数据 | `TwitterApi._metaCache` | 10 分钟 TTL + in-flight 去重，写操作后失效 |
| 解码位图 | Flutter `ImageCache` | 启动时放宽到 160MB / 1500 张 |
| 站点数据 | `StorageService` | 收藏 / 屏蔽标签 / 自定义标签规则 |
| 下载文件 | `Download/<用户名>/` | 批量下载的落盘结果 |

## 6. 构建流水线

`.github/workflows/build.yml`：

```
push(tag v*) ─┬─ flutter_test    (analyze + test，不过则不发版)
              ├─ build_android   (Go→libechproxy.so → flutter build apk)
              ├─ build_windows   (Go→echproxy.dll   → flutter build windows)
              └─ create_release  (汇总 APK + zip 上传)
```

版本号：tag 推送时用 tag（日期 tag 转三段式），main/workflow_dispatch 时回退 pubspec。
Android 侧 CI 会注入 `usesCleartextTraffic="true"`（本机 HTTP 代理必需）并以 grep 校验，
注入失败直接让 CI 红——这类"静默导致全网不通"的配置必须硬校验。
