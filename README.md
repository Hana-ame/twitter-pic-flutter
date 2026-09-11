# Twitter Pic Flutter

> 浏览 Twitter（X）图片与视频的 Flutter 客户端。墙内直连 `*.twimg.com` 必死，
> 媒体统一经**本机 Go ECH 代理**转发到 `video-cf.twimg.com`；API/JSON 直连自建后端。

当前版本 **v0.5.1**（Android arm64 + Windows x64）。分支上还有一个未发布的
「媒体一律 origin」重构（`v0.5.1` 之后一个提交，见更新日志）。

| 平台 | 产物 |
| --- | --- |
| Android | `app-release.apk`（包名 `xyz.moonchan.twitterpic`，仅 arm64-v8a） |
| Windows | `twitter_pic_flutter_windows_amd64.zip` |

## 网络架构：两条通道，别混

```
① 控制面（JSON / API）—— 直连，不走代理
   Dio → https://x.moonchan.xyz/api/twitter/...

② 数据面（媒体）—— 必须走 ECH
   Image/ExoPlayer → http://127.0.0.1:<port>/<path>?<query>
                          │  本机 Go 代理（纯 HTTP 监听）
                          ▼
                   cloudflare_ech.Do()
                          │  TLS 1.3 + ECH，外层 SNI=cloudflare-ech.com
                          ▼
                   https://video-cf.twimg.com/<path>?<query>
```

设计要点：

- **API 直连**：`x.moonchan.xyz` 是自建域名，无需 ECH。把 API 塞进代理只会多一跳、
  还容易因为前缀处理出错（历史事故见 `doc/troubleshooting.md`）。
- **媒体走代理**：`EchUrl.rewrite()` 丢掉原始域名，只保留 path + query，代理统一拼上
  `https://video-cf.twimg.com`。`pbs.twimg.com`（图片/头像）与 `video.twimg.com`（视频）
  是同一个 CDN 后端，改域名即可命中 ECH 路径（已实测，见下）。
- **代理只监听明文 HTTP**：Dart 侧写的是 `http://127.0.0.1:<port>`。代理一旦开 TLS
  （历史上有过一版），每个请求都会得到 `400 Client sent an HTTP request to an HTTPS server`，
  表现为"从来没成功访问过"。

### 实测数据（经 ECH 打真实 URL）

用 `github.com/Hana-ame/wintools/pkg/ech` 直连 `video-cf.twimg.com`，图片 URL 取自线上 API：

| `name=` 档位 | 图 1 | 图 2 |
| --- | --- | --- |
| `orig` | 200 · 371,715 B | 200 · 195,640 B |
| `large` | 200 · 371,715 B | 200 · 195,640 B |
| `medium` | 200 · **182,042 B** | 200 · **89,352 B** |
| `small` | 200 · **74,563 B** | 200 · **34,328 B** |

- 四档全部可用；`medium` ≈ `orig` 的 46~49%，`small` ≈ 18~20%。
- 这两张图的 `large == orig`（原图未超过 2048，`large` 返回同一份字节）。
- **App 现在不使用这些档位**（一律 origin，见「媒体 URL 一律 origin」一节）：同一张图只对应
  一个 canonical URL，缓存 key 不再被打散；代价是列表带宽变大，由预取与逐块解码承担。
- 视频 `Range: bytes=0-1023` → **206 + Content-Range**（ExoPlayer 起播的前提）。
- 新进程里第一次 ECH 请求要 7~11s（先 DoH 取 ECH 配置），之后 0.4~1.5s —— 所以
  App 启动即拉起代理，进画廊时已经在热路径上。

## 功能

- 用户列表 / 搜索（按用户名、昵称）
- 用户详情：媒体时间线（图片 + 视频）、标签、emoji 投票
- 图片全屏预览：**左右滑动或上下滑动翻页**、双击放大、逐块解码（下到哪显示到哪）
- 视频：Range 边下边播、缓冲进度、倍速、全屏、下载分享
- 收藏 / 屏蔽标签 / 批量下载（三个入口：流式下载、兼容下载、应急下载）
- 设置页：代理状态、**10 项网络诊断**（可一键复制）、Go 侧调试日志、清缓存
- **日志落盘 + 异常退出提示**：Dart 错误与 Go 日志持续写到 `logs/`；上次没正常
  结束（闪退/被强行结束）时，下次启动直接提示**加群反馈**并一键复制日志包

## 目录结构

```
lib/
├── api/twitter_api.dart           # Dio 客户端（kApiBase、路径归一化、元数据缓存）
├── models/user.dart               # 容错 JSON 模型（缺字段不炸）
├── screens/
│   ├── user_list_screen.dart      # 用户列表 / 搜索 / 收藏入口
│   ├── user_detail_screen.dart    # 详情页：时间线、标签、emoji、批量下载
│   ├── settings_screen.dart       # 设置 + 10 项网络诊断 + 日志
│   └── ranking_screen.dart        # emoji 排行
├── services/
│   ├── proxy_manager.dart         # FFI 生命周期（12 个导出符号）
│   ├── log_service.dart           # 日志落盘 / 异常退出判定 / 反馈包
│   └── storage_service.dart       # 收藏 / 屏蔽 / 标签规则持久化
├── utils/
│   ├── ech_url.dart               # 媒体 URL → 本机代理 URL
│   ├── media_url.dart             # 图片判定（预取时跳过视频）
│   ├── video_failure.dart         # 播放失败分类（解码器 / 网络 / 代理未就绪）
│   └── doh_resolver.dart          # DoH 自举 IP 解析
├── widgets/
│   ├── progressive_image.dart     # 逐块解码 ImageProvider（核心）
│   ├── twitter_image.dart         # 图片卡片 + 全屏画廊
│   ├── twitter_video.dart         # 视频卡片 + 全屏播放
│   ├── proxy_avatar.dart          # 头像
│   ├── fav_list.dart              # 收藏列表（导出/导入）
│   ├── report_help.dart           # 反馈弹窗（加群 / 复制日志包）
│   └── tag_*.dart                 # 标签选择/展示/高亮
└── main.dart                      # 入口、全局错误捕获、ImageCache、底部导航

ech-proxy/cmd/ech-flutter-shared/main.go   # 代理唯一实现（供 CI 编 .so/.dll）
.github/workflows/build.yml                # 测试 → 双平台构建 → 发 Release
test/                                      # 12 个测试文件，CI 全跑
doc/architecture.md                        # 架构细节
doc/troubleshooting.md                     # 症状 → 根因 → 怎么确认
```

## 关键实现

### 1. 本机代理（Go，唯一真源）

`ech-proxy/cmd/ech-flutter-shared/main.go` 导出 12 个符号给 Dart（FFI）：

| 符号 | 用途 |
| --- | --- |
| `ECHSetDohURL` / `ECHInit` / `ECHInitWithBootstrap` / `ECHInitReady` / `ECHInitLastError` | ECH 初始化 |
| `StartProxy` / `StopProxy` / `GetProxyPort` / `IsEchReady` | 代理生命周期 |
| `ECHGetLogCount` / `ECHGetLog` / `FreeCString` | 日志回传 |

路由：`/` 内置说明页，`/logs` Go 日志，`/api/` 转发自建后端（仅演示用），
其余一律 `echProxyHandler` → `https://video-cf.twimg.com/<path>`。

三个必须保留的细节：

- **透传 `Range`** 并回 `206` + `Content-Range` + `Accept-Ranges`：ExoPlayer 靠它找 moov。
- **强制 `Accept-Encoding: identity`**：否则 Go transport 自动 gzip 会删掉 `Content-Length`，
  播放器估不出长度就不放。
- **转发 query**：`?format=jpg&name=orig` 丢了就是 404。

> cgo 规则：导出函数里 panic 会**直接 abort 整个进程**。所有导出都包了 `guardPanic()`
> 并使用具名返回值，`logBuffer` 的读写都在锁内（历史上正是这里撕裂 slice 导致偶发闪退）。

### 2. 图片逐块解码

`Image.network`/`NetworkImage` 会**先把整个响应体读完再解码**，一张几百 KB 的图在墙内
慢慢下的时候屏幕上只能是一大片空白。`ProgressiveImageProvider` 直接读 HTTP 流，
每收到一块就尝试解码当前缓冲并 `setImage`：已下载的部分立刻画出来，未下载到的区域
是 Skia 的中性灰。

- 节流三条规则：增量 ≥24KB、增量 ≥ 已解码量 1/4、间隔 ≥120ms（越往后越稀疏）。
- 按 URL 命中 `ImageCache`，滚回来不重新下载；30s 无数据才中断。
- PNG 等不支持部分解码的格式自动退化为"下完再显示"，不报错。

### 3. 媒体 URL 一律 origin（不做档位）

线上 API 抽查 6 个用户、2209 条：图片全是 `pbs.twimg.com/media/<id>?format=jpg&name=orig`，
视频是 `video.twimg.com/.../<id>.mp4?tag=29`（其中 238 条连查询参数都没有）。

**App 不改写 `name=`**：API 给什么 URL 就加载什么 URL，同一张图只对应一个 canonical URL。

- 理由：档位会让同一张图产生 4 个 URL（缓存 key 被打散），并且把"客户端该选哪一档"变成
  一条必须三端对齐的规则——历史上就分叉过（App 按 DPR 选档、gallery 固定 `small`、
  网页端完全不选）。现在这条规则不存在了。
- 代价：列表按最大字节数加载（实测 `small` 只有 `orig` 的 18~20%）。补偿手段是
  `cacheExtent` 提前构建 + 进页面/续载预取 + 放宽 `ImageCache`（见下一节）。
- 唯一保留的判定是"能不能预取"：`MediaUrl.isImage()` 只认 `pbs.twimg.com`，
  视频（动辄几 MB）不预热。

### 4. 列表性能

- `cacheExtent: 1800`：视口外两三张卡片提前构建并发起下载。
- 进页面预热 6 张图片（视频不预热），每次续载再预热 4 张；滚到底自动 +10（无限滚动）。
- `ImageCache` 放宽到 160MB / 1500 张（默认 100MB / 1000），滚过去的图尽量留在内存。

### 5. 视频

`VideoPlayerController.networkUrl(EchUrl.rewriteToUri(...))`，靠代理的 Range 支持边下边播；
控制栏是一根条三态（已播放/已缓冲/未缓冲），缓冲量画在滑块轨道底下。

**同一个 controller 同一时刻只能有一个 `VideoPlayer` 在渲染**，否则 texture 被渲染两次
（鬼影，全屏那侧往往是黑的）——进全屏时卡片侧换成纯黑占位。

全屏用 `Center + AspectRatio + VideoPlayer`，**不能用 `FittedBox`**：`VideoPlayer` 渲染的是
`Texture`，`TextureBox` 是 `sizedByParent`（尺寸取 `constraints.biggest`），而 `FittedBox`
会用无界约束去量孩子 → 高度 `∞` → 整层渲染失败 → 全屏黑屏（见 `doc/troubleshooting.md`）。

#### 解码器上限：为什么必须有播放器池

Android 的**硬件** AVC 解码器实例是稀缺资源（常见只有 2~4 个，720p60 High profile 往往
只吃得下 2 个）。而详情页 `cacheExtent` 是 1800px、卡片高约 200px，一次能构建十几张卡片；
**每张 `TwitterVideo` 在 `initState` 里就 `initialize()`** —— 哪怕它在屏幕外、也没人按播放
（卡片不自动播放，它只是为了显示一张静帧）。十几路 initialize 必然撞上解码器上限，报出来
的就是 `MediaCodecVideoRenderer error ... format_supported=YES`：格式是支持的，只是没有空闲
解码器。

`_PlayerPool`（`twitter_video.dart`）因此给**同时存活**的播放器设上限（`max = 2`）：超出就
回收最久未用的那个，被回收的卡片回到「点按加载视频」**待机态**（不是错误态——主动让位不是
失败）。手动重试前会先 `freeAllExcept(this)` 腾位，否则重试必然以同样的错误再失败。

> 副作用：视频密集的时间线上，同时只有 2 张卡片显示静帧，其余是「点按加载」。
> 想多保留静帧就调大 `_PlayerPool.max`，代价是更容易撞上限。

#### 重试手段

| 场景 | 处理 |
| --- | --- |
| 加载卡住 | 看门狗 15s（> ECH 冷启动 7~11s）→ 转错误态 + 重试；**不打断**底层 initialize，真慢但能成会自动切回播放器 |
| 首次失败 | 自动重试一次（1.2s 后），ECH 冷启动与抖动多为一次性 |
| 代理刚重启 | 监听 `portNotifier`，端口一出现就自动重试（否则卡片会一直停在错误态） |
| 解码器类失败 | 重试前先放掉其它播放器腾解码器槽位 |
| 代理未就绪 | 不退回直连 URL（墙内必死），直接给「代理未就绪」的明确提示 |
| 出错后想看原因 | 错误卡片「详情」显示 URL / 端口 / 同时存活播放器数 + 原始异常，可一键复制 |

另外 `_initSeq` + `_scheduleInit()` 负责初始化去重：端口变化时 `portNotifier` 与
`didUpdateWidget` 会各触发一次，不合并就会同帧起两个播放器、两个解码器。

## 构建与发布

CI 全程云端（本地无需 SDK）：`.github/workflows/build.yml`

1. `flutter_test`：`flutter analyze --no-fatal-infos --no-fatal-warnings` + `flutter test`
   —— 不过不发版（`create_release` 依赖它）。
2. `build_android`：Go 交叉编译 `libechproxy.so`（NDK r27，arm64-v8a）→ 注入包名
   `xyz.moonchan.twitterpic`、`INTERNET`、`android:usesCleartextTraffic="true"`（本机 HTTP 代理必需）、
   应用名"推图" → 签名 → `flutter build apk --release`。
3. `build_windows`：Go 编 `echproxy.dll` → `flutter build windows --release` → 打 zip。
4. `create_release`：上传 APK + zip。

**版本号跟着 tag 走**：推 `v*` tag 时把 tag 名写进 `pubspec.yaml` 的 `version`
（日期 tag `vYYYYMMDD.HHMMSS` 会转成三段式 `YYYYMMDD.0.HHMMSS`）；推 main 分支时
回退用 pubspec 里的版本，避免写出非法版本号。

发布：`git tag -a vX.Y.Z -m "..." && git push origin vX.Y.Z`

## 自查：诊断与日志

设置页 →「运行全部通道测试」共 10 项，出结果后点「复制」可直接贴出来：

1. API 直连（Dio 实际通道） 2. 用户 JSON 编码与字段 2b. `getMetaData` 经 Dio+模型解析
3. API 原始探测（不经 Dio） 4. video-cf 经 ECH 代理 5. video-cf 直连（预期失败）
6. 真实头像经代理 7. 头像 widget 栈解码 8. 真实图片 widget 栈解码
9. 真实视频 Range 探测 10. **ECH 代理转发记录**（各类型多少条经 video-cf、多少条 200/206）

设置页 →「调试日志」是 Go 侧日志，代理对每条请求都会写：

```
→ https://video-cf.twimg.com/media/xxx?format=jpg&name=orig (from 127.0.0.1:xxxxx)
← 200 https://video-cf.twimg.com/media/xxx?format=jpg&name=orig (371715 B)
```

**想知道媒体到底有没有走 ECH**：看这两行即可 —— 上游是 `video-cf.twimg.com` 就说明走了 ECH；
`← 200/206` 说明取到了。媒体走没走代理不靠猜，日志里一目了然。

### 闪退了怎么查：日志落盘 + 异常退出提示

`Go 日志` 那个面板是**内存态环形缓冲**（500 行），进程一旦 abort 就跟着消失 ——
这正是「有人报闪退、但手里什么都没有」的原因。现在补了三层：

| 层 | 位置 | 作用 |
| --- | --- | --- |
| Dart 全局错误捕获 | `main.dart` 的 `runZonedGuarded` + `FlutterError.onError` + `PlatformDispatcher.onError` | 未捕获错误进内存缓冲**并立刻落盘** |
| Go 日志落盘 | `lib/services/log_service.dart` 每 2s 轮询 `ECHGetLog*`，增量追加 | 环形缓冲被裁剪/清空都能对齐（按上一行 tail 定位） |
| Go 侧 stderr tee | `main.go` 的 `logWriter.Write` | 进程被 abort 时，最后几行至少还留在 stderr（桌面端控制台/CI 可见） |

文件都在应用支持目录的 `logs/` 下：`app.log`（超 512KB 轮转成 `app.log.1`）、
`session.json`（会话标记）、`incidents.json`（异常结束历史）。

**异常退出判定**：启动时写 `session.json`（`cleanExit=false`），生命周期走到
`detached` 才打上 `cleanExit=true`。下次启动读不到这个标记 → 判定「上次没有正常结束」，
弹窗提示**加群反馈**并给一键「复制日志」。判定刻意写成「没有正常结束」而不是「闪退」：
从任务管理器强杀、系统回收后台进程也会落到同一类。

**用户侧的反馈路径**：设置页 →「复制日志反馈包」→ 粘贴到群里。
反馈包 = 版本 + 平台 + 代理状态 + 最近 400 行日志 + 加群方式，所以用户即使只发了
这段文字，也自带版本与渠道信息。

> 已知取舍：不新增 FFI 导出符号（那要同步改 README / CHECKLIST / CI 的 12 个符号清单），
> 所以 Go 日志靠**轮询**落盘 —— 硬 abort 时最后约 2s 的行可能来不及写。

## 注意事项

1. **源码与平台文件分离**：`android/`、`ios/` 不提交，CI 用 `flutter create` 现场生成再覆写。
2. **仅 arm64**：`--target-platform android-arm64`。
3. **包名变更**：`xyz.moonchan.twitterpic`（旧 `com.example.*` 的版本要先卸载再装）。
4. **明文流量**：`http://127.0.0.1:<port>` 依赖 manifest 里的 `usesCleartextTraffic="true"`，
   Android 9+ 缺它会被系统静默拒绝（表现为"暂无内容"）。
5. **Flutter 3.44.3 / JDK 17 / NDK r27** 锁定。
6. **DoH 固定** `https://moonchan.xyz/doh`。
7. **不支持 iOS**。

## 更新日志

### 未发布（`v0.5.1` 之后）
- **媒体 URL 一律 origin**，删除 `name=` 尺寸档位：`MediaUrl` 只剩"能不能预取"的判定，
  同一张图只对应一个 canonical URL（见上文「媒体 URL 一律 origin」）
- **日志落盘 + 异常退出提示**：Dart 全局错误捕获（`runZonedGuarded` /
  `FlutterError.onError` / `PlatformDispatcher.onError`）、Go 日志 2s 轮询增量落盘、
  Go 侧 stderr tee；上次没正常结束时下次启动提示加群反馈并一键复制日志包
- 设置页新增「日志与反馈」区（复制日志包 / 加群 / 异常结束记录），日志弹窗可复制
- 视频：**seek 失败与播放器报错不再静默** —— `_seekTo` 接住 `PlatformException`
  并写日志，卡片侧转成可见错误态 + 重试，`_retryInit` 补上旧 controller 的 dispose
- 视频：**修「经常加载失败」** —— 播放器池限制同时存活的 ExoPlayer 数（`max = 2`），
  避免十几张卡片各占一个硬件解码器报 `MediaCodecVideoRenderer error`；
  加载看门狗（15s）、失败自动重试一次、代理端口出现自动重试、错误卡片带「重试/详情」
- 视频：代理未就绪不再静默退回直连 URL（墙内必死），改为明确提示
- 代理：客户端要了 `Range` 却收到 `200` 全量时**显式记一条日志**（拖动进度条后
  长时间卡住的那条路径，以前日志里只有一条正常的 200，查不出来）

### v0.5.1
- 修复收藏夹里看不到收藏的内容（纵向 `ListView` 嵌套纵向 `ListView`，内层拿到无界高度）
- 修复 `_FavTile` 缺 `super.key`（analyze 报 `undefined_named_parameter`）
- 重写 README 与 CHECKLIST，新增 `doc/architecture.md`、`doc/troubleshooting.md`

### v0.5.0
- 媒体（图片/头像/视频）统一经本机 ECH 代理 → `video-cf.twimg.com`；API/JSON 直连
- 代理改为**纯 HTTP**（此前 TLS 模式导致所有请求 `400`，即"从来没成功访问过"）
- 代理支持 `Range`/206、转发 query、`Accept-Encoding: identity`，并记录上游状态码与字节数
- 修复 API 路径拼接缺斜杠导致 `metadata/tags/emojis` 全部 403
  （症状：详情页"暂无内容"、头像全空、标签/emoji 空）
- 修复媒体卡片在无界高度里没有确定高度 → 整片 media 空白
- 图片**逐块解码**（下到哪显示到哪）；列表按显示尺寸取 `name=` 缩略图档位
  （该档位已于 v0.5.1 之后移除，改进方向见上文「媒体 URL 一律 origin」）
- 图片全屏支持左右/上下滑动翻页 + 双击放大
- 修复全屏视频黑屏（`FittedBox` + `Texture`）与鬼影（同一 controller 渲染两次）
- 诊断面板扩到 10 项，含 ECH 转发记录

### v0.2.8
- 视频流式下载 → 原地播放 + 封面抽帧；批量下载进度；播放控制栏自动淡出；全屏播放

### v0.2.3
- 修复收藏夹导出剪贴板为空；GitHub Actions 自动构建
