# 排查手册：症状 → 根因 → 怎么确认

按"现象"查。每条都是本项目真实踩过并已修复的坑，附**如何确认**（不靠猜）。
诊断面板的用法见 README「自查」。

---

## 通用确认顺序

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
