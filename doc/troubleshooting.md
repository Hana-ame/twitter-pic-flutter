# 排查手册：症状 → 根因 → 怎么确认

按"现象"查。每条都是本项目真实踩过并已修复的坑，附**如何确认**（不靠猜）。
诊断面板的用法见 README「自查」。

---

## 通用确认顺序

0. **闪退 / 进程直接消失**：先取日志，再谈推理。设置页 →「复制日志反馈包」；
   或者看应用支持目录的 `logs/`（`app.log`、`session.json`、`incidents.json`）。
   上次没正常结束的话，App 下次启动会自己弹提示。详见文末「闪退的证据链」。
1. 设置页 →「运行全部通道测试」→「复制」。看哪几项 FAIL：
   - `1` FAIL → 连不上后端（API 直连通道）
   - `2b` FAIL 但 `2` PASS → **Dio/解析层**问题，不是网络
   - `4` FAIL → 本机代理没起来
   - `6/7/8` FAIL 而 `4` PASS → 媒体通道（URL 改写或上游拒绝）
   - `9` FAIL → Range 没通，视频必挂
2. 设置页 →「调试日志」：确认请求**去了哪个上游**、**拿到什么状态码**。
3. 只有这两步都看完再改代码。

---

## 案例 1：详情页永远"暂无内容"、头像全空、标签/emoji 也是空的

**症状**：用户列表能出 25 个用户（API 通），但点进任何用户都没有内容；诊断里
`1 PASS`、`2 PASS`、`6/7/8/9 PASS`，只有 `2b FAIL: HTTP 403`。

**根因**：Dio 拼接 `baseUrl` 和相对 path 时**不会补斜杠**：

```
baseUrl 'https://x.moonchan.xyz/api/twitter' + path 'alice.json.gz'
  = https://x.moonchan.xyz/api/twitteralice.json.gz     ← 少了 /
```

后端是 gin，这个路径匹配不到任何路由 → 落到 `NoRoute`，而 `NoRoute` 在
`STATIC_ROOT` 未设置时直接 `AbortWithStatus(403)`（`server/main.go:59`）。于是
`getMetaData`/`getTags`/`getEmojis`/`getRanking` 全部 403。`getUserList` 因为用了
`'/'` 一直正常，所以列表能出、详情永远空。

**确认**：`2b` 的输出会打印 Dio **实际请求的 URL**（诊断里专门加的）；也可以直接
`curl -i "https://x.moonchan.xyz/api/twitter/<user>.json.gz?t=<日期>"` 对比。

**修法**：所有相对 path 补前导 `/`，并加 `onRequest` 拦截器统一归一化；
`test/api_url_test.dart` 用假适配器逐接口断言绝对路径，防止回归。

---

## 案例 2：看得到头像，看不到任何 media（卡片空白）

**症状**：详情页头像、用户列表都正常，但媒体区域一片空白（或只有极细的小块）。

**根因**：媒体卡片的 item 挂在 `ListView.builder` 下，**父级高度无界**；而 `TwitterImage`
用 `Stack(fit: StackFit.expand)` 自适应：expand 把父级约束（`height = ∞`）当紧约束
传给子级，`Image` 在首帧解码前返回 `Size(width, ∞)` → 整条 item 高度无穷 → 渲染失败，
一张图都画不出来。头像走的是固定 `SizedBox`，所以只有头像正常。

这个 bug 藏了很久：`metadata` 403 期间 timeline 恒为空，`_MediaCard` 从来没被构建过
（案例 1 修好后它才暴露）。

**修法**：`AspectRatio` 先占位（未知比例时 3:4），解码出真实宽高比后贴合；
`TwitterVideo` 的 loading/error 同样套 16:9 定高。

---

## 案例 3：视频全屏黑屏

**症状**：卡片里视频正常播放，点全屏按钮后整片黑（控制栏可见）。

**根因**（从框架源码逐层核过）：

1. `video_player` 的 Android 实现 `buildViewWithOptions` 返回 `Texture(textureId:)`；
2. Flutter `rendering/texture.dart`：`TextureBox` 是 `sizedByParent => true`，
   `computeDryLayout` 直接 `return constraints.biggest;`
3. Flutter `rendering/proxy_box.dart` 的 `RenderFittedBox.performLayout`：
   `child!.layout(const BoxConstraints(), parentUsesSize: true)` —— **无界约束**。

三者相撞：`constraints.biggest` = `Size(w, ∞)` → 尺寸无穷 → 该层渲染失败 → 黑屏。
（debug 下就是经典的 "BoxConstraints forces an infinite height"。）

**修法**：`Center`（先松约束）+ `AspectRatio`（按视频比例算有限尺寸）+ `VideoPlayer`。
`RenderAspectRatio.performLayout` 是 `child?.layout(BoxConstraints.tight(size))`，
给出的正是 `TextureBox` 唯一能接受的紧且有限的尺寸。

**确认**：全屏控制栏里有一行灰色状态字（`1920x1080 init play buf`）。

---

## 案例 4：视频鬼影 / 全屏点不动

**根因**：卡片和全屏页**同时**挂着 `VideoPlayer(同一个 controller)`，同一个 texture
被渲染两次：一次显示成鬼影/花屏，另一个（全屏那侧）往往直接是黑的。

**修法**：进全屏时把卡片侧换成纯黑占位（`_fullscreenOpen` 标志），同一时刻只有一个
`VideoPlayer` 在渲染。

---

## 案例 5：视频控制栏出现"两根加载条"

**根因**：缓冲进度是**独立的一根** `LinearProgressIndicator`，和滑块并排自然成了两根。

**修法**：合成一根条三态 —— 白色=已播放、半透明白=已缓冲、透明=未缓冲；缓冲量画在
滑块轨道底下（`SliderTheme` 的 `inactiveTrackColor` 设为透明露出底下的缓冲条）。
卡片与全屏共用 `_SliderWithBuffer`。

---

## 案例 6：所有媒体请求 400 `Client sent an HTTP request to an HTTPS server`

**症状**：代理"运行中"、`init=true`，但**从来没成功取到过任何媒体**。

**根因**：Dart 侧永远写 `http://127.0.0.1:<port>`，而代理当时会去拉证书并改用
`tls.NewListener` 开 HTTPS 监听。明文请求打到 TLS 端口，Go 标准库直接回
`400 Client sent an HTTP request to an HTTPS server.`

**修法**：代理只做明文 HTTP，彻底删掉证书下载与 TLS 分支。**不要**为了"更安全"
再加回 TLS —— 播放器和 `Image` 都不会用自签 HTTPS。

**确认**：`curl -i "http://127.0.0.1:<port>/favicon.ico"`（诊断第 4 项）应为 200。

---

## 案例 7：视频永远停在"加载中"

**根因**（两个都真实发生过）：

- 代理**没透传 `Range`** → 上游回整包 200，ExoPlayer 拿不到文件尾的 `moov`；
- 代理没强制 `Accept-Encoding: identity` → Go transport 自动 gzip，顺手删掉
  `Content-Length`，播放器估不出长度与分段。

**修法**：透传 `Range`、回 `206` + `Content-Range` + `Accept-Ranges: bytes`、
强制 `identity`。**确认**：诊断第 9 项必须 `206`（只认 206，200 不算过）。

---

## 案例 8：图片/视频 404，但同一张图在浏览器里能打开

**根因**：代理拼上游 URL 时丢了 query（`?format=jpg&name=orig`），
或者把原始域名留在了 path 里（变成 `video-cf.twimg.com/pbs.twimg.com/media/...`）。

**修法**：`withQuery()` 转发 `r.URL.RawQuery`；`EchUrl.rewrite` 只保留 path + query。
**确认**：调试日志里的上游 URL 与原始 URL 逐字符对比。

---

## 案例 9：启动偶发闪退（概率性）

**根因**：cgo 导出函数里 panic 会**直接 abort 整个进程**。当时的触发点：
`logBuffer = nil` 没持锁而 `logWriter.Write` 正在追加（撕裂 slice header →
`ECHGetLog` 越界）、`atomic.Value` 上未检查的 `v.(string)` 断言、
`ECHInit` 的子 goroutine 与 `Serve()` 的连接 goroutine 无 recover。

**修法**：所有导出 `defer guardPanic()` + 具名返回值；缓冲清空持锁；断言用
comma-ok；每个 goroutine 各自 recover。

---

## 案例 10：下载/滚动时整片白屏

**根因**：线上图片 URL 是 `name=orig`（最重的一档，单张几百 KB~几 MB），而
`ListView.builder` 默认 `cacheExtent` 只有 250 逻辑像素（一张卡片就 ~450px），
往下滑时下一张**还没构建**；已滚过的图又很快被默认 100MB 的 `ImageCache` 挤掉。

**修法**（当时）：列表按显示尺寸取 `name=` 缩略图档位（`medium` ≈ `orig` 的 46~49%）、
`cacheExtent: 1800`、进页面预热 6 张 + 续载预热 4 张、`ImageCache` 放宽到 160MB/1500 张。

**现状**：档位已全部移除（一律 origin，见 README「媒体 URL 一律 origin」）。补偿只剩三条 ——
`cacheExtent: 1800`、进页面/续载预热、`ImageCache` 160MB/1500 张。**这个案例因此没有真正关闭**：
白屏若再次出现，先查这三条有没有被改动，不要靠重新引入 `name=` 档位来救。

**确认**：调试日志里的上游 URL 应始终带 `name=orig`；白屏时要看的是"请求有没有发出去"
（缺 `→` = 预取没到位），而不是"字节数够不够小"。

---

## 案例 11：诊断"全绿"但功能是坏的

**根因**：早期 `_passed()` 只看结果是否以"失败"开头，HTTP 404/502 也会标成绿色 ✓。

**修法**：`_passed()` 解析 `HTTP <code>` 判 2xx/3xx；"预期失败"的用例（第 5 项）
用 `expectFail` 反转。**结论：诊断项必须能被判假**，否则它只是在制造安心感。

## 案例 12：拖进度条后长时间卡住 / 黑屏（不是闪退）

**症状**：视频能正常播，一拖进度条就卡住或变黑，久等不回，只能退出重进。
（注意区分：进程**真的没了**是另一类问题，见文末「闪退的证据链」。）

**根因（两种，日志里能分辨）**：

1. **上游没吃下 `Range`，回了 200 全量**。ExoPlayer 的 `DefaultHttpDataSource`
   在"要了分段却收到 200"时会从头读、把目标位置之前的字节**全部丢弃** ——
   墙内这条链路慢，等于白下几 MB 到几十 MB，表现就是原地卡住、像是死了。
   诊断第 9 项必须 `206`（`200` 不算过）；日志里现在会显式出现：
   `! Range 未生效：请求 "bytes=1234567-" ，上游回 200 全量`
2. **seek 本身失败**。Android 上 seek 失败会变成 `PlatformException`（插件的
   pigeon handler 把 `Throwable` 包成错误回给 Dart）。以前 `_seekTo` 既不 await
   也不 catch —— **失败被静默吞掉**，界面上什么都不显示，日志里也没有。

**修法**：`_seekTo`（卡片）与 `_seek`（全屏）都接住异常并写日志；播放器自身的错误
（`VideoPlayerValue.hasError`）不再只躺在 value 里 —— 卡片侧转成可见错误态 + 现成的
重试入口，全屏侧记一条日志；`_retryInit` 补上旧 controller 的 `dispose`
（否则每重试一次就泄漏一个还在解码、还占着 texture 的播放器）。

**确认**：拖动出问题后，「复制日志反馈包」里应当能看到 `seekTo` / `player` 开头的
`Dart 错误`，或者上面那条 `! Range 未生效`。**两条都没有**才说明问题在原生层
（解码器 / 纹理 / OOM），那就要 logcat 与 tombstone，App 内拿不到。

**还没修的（已知）**：`_isDragging` 只在 `onChangeEnd` 清除，手势被取消（拖动中列表
开始滚动、widget 被回收）时会一直停在"拖动中"，时间标签就不再更新；拖动期间显示的
时间也不是手指位置，而是 `position + duration/2`。纯显示问题，不影响播放。

---

## 案例 15：卡片显示了封面，但点它没反应（点不动、不能播）

**症状**：滚动一阵之后，视频卡片显示着封面，**点上去毫无反应**（既不转圈也不播）。
"再也不能点播"的体感就是这么来的。

**根因（纯调度 bug，与解码器/网络无关）**：抢槽位的规则写成了"只允许挤掉
**看不见**且没在播的卡片"。而用户**正看着屏幕**时，占着那两个槽位的恰恰就是屏幕上
正在被抓封面的卡片 —— 于是点封面 → 进排队 → `_pickVictim` 找不到"看不见的"牺牲者
→ 直接 return → 什么也没发生。整个过程会持续到封面流水线跑完，用户看到的就是
"点了没用"。

**修法**：区分"自动请求"和"用户点播"（`_PlayerPool.request(urgent: true)`）：
- 点播请求排在所有自动请求之前（`_pickWaiter` 先找 urgent）；
- 点播可以挤掉**任何非播放**的卡片（`_pickUrgentVictim`：看不见+有封面 > 有封面 >
  没在播 > 最后才动正在播的）；
- 点封面**自动开始播放**（`_retryInit(autoPlay: true)`），并在初始化期间于封面上
  转圈给出反馈 —— 否则"点了没反应"的观感与真没反应无法区分。

**确认**：点封面后应立即出现转圈 → 随后开始播放；若仍无反应，看日志里有没有
`video.init` 报错（那就是另一类问题了）。

**同一症状的另外两个成因（都已修，引以为戒）**：

1. **点播后抓封面把正在起播的播放器还回去了**：没有封面时点封面 → 初始化成功 →
   `controller.play()` → 抓封面在下一帧（~16ms）就完成，此刻 `value.isPlaying`
   还没翻转 → `_becomePosterOnly` 判定"没在播"把播放器交还 → 起播当场死掉。
   修法：`_userInitiated`，用户点播过的卡片不交还（被池子挤掉时重置）。
2. **排队中的卡片整块不可点**：卡片在等槽位（转圈）时没有点击处理，用户点它同样
   "没反应"。修法：`_PlayerPool.isWaiting()` 为真时加载卡片可点 = 优先加载；
   **已经在初始化中的不响应点击**（否则被反复打断、白白重下）。

---

## 案例 13（Windows，疑似 · 未在真机确认）：拖进度条后闪退

> 状态：**静态分析结论，没有真机复现**。之所以先记下来，是因为它只在 Windows
> 产物上成立，而 Windows 那条通道平时没人测（Android 报告无法验证它）。

**触发链**（源码：`video_player_win` 3.2.2，pub.dev 上的最新版，未修复）：

1. `MyPlayer::Seek()`（`my_grabber_player.cpp:395`）在**暂停态**才置
   `m_seekingToPts = ms * 10000` 并 `SetEvent(m_playingEvent)` —— 也就是把视频线程
   从 `WaitForSingleObject` 里叫醒，并让它保持热路径。
2. 该标记只在"找到与目标 PTS 相差 <100ms 的帧"时才清回 -1（`:350-360`）。没找到就
   **一直 ≥ 0**：视频线程再也不休眠，`THREAD_PRIORITY_HIGHEST` 以 VBlank 频率空转
   （`waitForVBlank` 60Hz）。顺带：那里的 `continue` 位于 `do{...}while(false)` 里，
   等于直接跳出，"loop until next frame found" 其实没循环。
3. `Shutdown()`（`:439`，dispose 的唯一入口）里 `SetEvent` 之后直接
   `m_pEngine.reset()` / `m_pTexture.reset()`；而线程侧 `updateFrame()`（`:313`）
   **既不拿 `m_mutex`**（全文件只有 `Shutdown` 用锁）**也不判空**，直接
   `m_pEngine->OnVideoStreamTick(...)`。线程里那两处 `if (m_isShutdown) break;`
   非原子、也不在锁内 —— 检查通过之后另一线程就能把 engine 释放掉 →
   **空指针调用 / use-after-free → 访问违例 → 进程当场消失**。

**为什么和"拖进度条"绑在一起**：`Seek()` 是唯一会把暂停态线程唤成热路径的用户操作。
静止时线程阻塞着，`Shutdown` 的 `SetEvent` 之后它醒来会立刻看到 `m_isShutdown` 而退出，
基本安全；scrubbing 期间这个窗口是打开的。**而我们 App 的 dispose 很积极**
（`twitter_video.dart` 的 `dispose` 与 `didUpdateWidget`，加上 `cacheExtent: 1800`，
卡片滚出一屏就回收），所以"拖完立刻滚动/返回"就能撞上。

**可验证的判别性预测**（不需要调试器）：

- **播放中**拖不应该触发（`Seek()` 只在 `!m_isPlaying` 时置 scrubbing 标记）；
- 拖完之后 **CPU 占用不回落**（线程再也没睡），任务管理器可见；
- 复现脚本：暂停 → 拖进度条 → 1~2 秒内让卡片滚出屏幕或返回上一页。

**顺带**：`my_http_bytestream.cpp:70` 把 `QWORD startPosition` 强转成 `int` 拼
`Range: bytes=%d-`，超过 2 GiB 的偏移会截断成错值（每次 Windows seek 都走这里）。

**修法方向**：上游无修复版 → 需要 fork（本仓已有 fork `video_thumbnail` 的先例）：
`updateFrame()` 首行加 `if (!m_pEngine || m_isShutdown) return E_FAIL;`；
给 `m_seekingToPts` 加超时兜底；`Shutdown()` 在 `m_pEngine.reset()` **之前**等线程退出，
而不是只 `SetEvent`。

## 案例 14：视频加载失败，报 `MediaCodecVideoRenderer error`（解码器不够用）

**症状**：视频经常"加载失败"，有的能播有的不能，同一个视频重进有时又好了。
报错原文（用户实测，可直接对号入座）：

```
经 ECH 代理加载失败：PlatformException(VideoError, Video player had error v.i:
MediaCodecVideoRenderer error, index=0, format=Format(1, null, video/mp4, video/avc,
avc1.640020, 1891376, und, [1280, 720, 60.0, ...]), format_supported=YES, null, null)
```

**先看清楚这不是网络问题**：`Format(...)` 已经把编码/分辨率/帧率都解析出来了
（720p60、H.264 High、1.9Mbps），而且 `format_supported=YES` —— 数据取到了、
格式也支持。报错来自 **MediaCodec**，即拿不到空闲的**硬件解码器**。

**根因**：Android 的 AVC 硬解实例是稀缺资源（常见只有 2~4 个，720p60 High profile
往往只吃得下 2 个）。而详情页 `cacheExtent` 是 1800px、卡片高约 200px，一次能构建
十几张卡片；**每张 `TwitterVideo` 在 initState 里就 `initialize()`** —— 哪怕它在
屏幕外、也没人按播放（卡片不自动播放，它只是为了显示一张静帧）。十几路
`initialize()` 必然撞上解码器上限。

**修法**：`_PlayerPool`（`twitter_video.dart`）给**同时存活**的播放器设上限
（`max = 2`）。超出时回收最久未用的那个，被回收的卡片回到「点按加载视频」**待机态**
（不是错误态 —— 主动让位不是失败，落成错误会让用户看到满屏"加载失败"，其实点一下就
能播）。另外：

- 手动重试前先 `freeAllExcept(this)` 腾位 —— 不腾位的话重试必然以同样的错误再失败，
  用户只会得出"重试没用"；
- `_initSeq` 序号 + `_scheduleInit()` 合并，防止"端口变化时 `portNotifier` 与
  `didUpdateWidget` 各触发一次初始化"同时留下两个解码器。

**确认**：错误卡片上**原样**显示这条报错（重试按钮在它上面），长按可选中复制；
日志里对应 `video.init` 开头的 `Dart 错误`（含完整 Format 与 `分类:` 一行）。
若 `format_supported=YES` 却反复报同一个错、且换视频也一样，说明是**该编码在本机
不可用**（不是不够用），此时重试无用，只能换视频或在别的机器上试。

**注意**：`video_player` 插件用 `new ExoPlayer.Builder(context)` 建播放器，**没有**
`setEnableDecoderFallback(true)`，而 media3 默认 `enableDecoderFallback = false` ——
所以硬解失败时**不会**自动退到软解，这一层救不了，只能靠我们控制并发数。

---

## 排查"媒体到底走没走 ECH"

不要靠推理，看调试日志：

```
→ https://video-cf.twimg.com/media/xxx?format=jpg&name=orig (from 127.0.0.1:34567)
← 200 https://video-cf.twimg.com/media/xxx?format=jpg&name=orig (371715 B)
```

- 上游是 `video-cf.twimg.com` → 走了 ECH；
- `← 200/206` → 取到了；`← 404/403` → 路径或 query 有问题；
- 只有 `→` 没有 `←` → 上游卡住（ECH 握手慢或分段没读完）。
- 诊断第 10 项会把这一轮的各类型条数、成功数直接汇总出来。

**冷启动注意**：新进程里第一次 ECH 请求要 7~11s（先 DoH 取 ECH 配置），之后
0.4~1.5s。所以 App 启动即拉起代理；若在代理未就绪时进画廊，第一批图会慢。

---

## 闪退的证据链（进程级崩溃怎么留痕）

「闪退」= 进程没了，不是 Dart 异常。Dart 层在 release 下抛错只会打日志/灰屏，
**能杀进程的只有四类**：Go 侧 abort（cgo）、播放器/解码器原生崩溃、OOM 被系统杀、
以及 Windows 上第三方插件的访问违例。四类的共同点是：**内存里的东西全丢**。

所以证据必须提前落盘（`lib/services/log_service.dart`）：

| 手段 | 拿到什么 | 局限 |
| --- | --- | --- |
| `logs/app.log` | Dart 错误 + Go 日志（2s 增量） | 硬 abort 时最后 ~2s 的 Go 行可能丢 |
| Go 侧 stderr tee | 被 abort 前的最后几行、`PANIC ...` + 栈 | Android 上 stderr 未必进 logcat，以文件为准 |
| `session.json` | 是否正常收尾 | 强杀/系统回收也判为"没正常结束"，不能等同于闪退 |
| 设置页诊断第 10 项 | 媒体经没经过 ECH、各状态码条数 | 不覆盖崩溃本身 |

**两个必须知道的事实**（别指望 `guardPanic` 兜住一切）：

1. `recover()` **抓不到 Go 的 `fatal error`**（concurrent map write、OOM 等）——
   这类直接 abort，`guardPanic` 不参与。
2. **不是所有 goroutine 都有 recover**。本项目自己的 goroutine 都包了，但依赖库里的
   没有：`cloudflare_ech.InitDefault()` 起的 `refreshLoop`（wintools `pkg/ech/client.go`）
   就没有 recover，它里面 panic 一样会带走进程。案例 9 里"每个 goroutine 各自 recover"
   的说法只对本仓代码成立。

**排查顺序**：先看 `logs/app.log` 尾部有没有 `PANIC`/`Dart 错误`；再看是不是 OOM
（Android 看 logcat 的 `lowmemorykiller` / `ActivityManager`）；都没有则怀疑原生层
（Android tombstone、Windows 事件查看器的应用日志）。
