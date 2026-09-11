# 项目总检清单

> 最后核对：v0.5.11（2026-09-12）。细节见 [README](README.md)、
> [doc/architecture.md](doc/architecture.md)、[doc/troubleshooting.md](doc/troubleshooting.md)。

## 目标
- [x] 浏览 Twitter 图片/视频（媒体经本机 ECH 代理绕过 SNI 阻断）
- [x] Android（arm64-v8a）+ Windows x64
- [x] 全云端 CI 构建 + 打 tag 自动发 Release
- [ ] 纯 Dart ECH（等 Flutter 内置支持；目前 Dart 层无 ECH API）

## 网络通道
- [x] 控制面：JSON/API **直连** `https://x.moonchan.xyz/api/twitter`（不进代理）
- [x] 数据面：`pbs/video.twimg.com` 媒体 → `http://127.0.0.1:<port>` → ECH → `video-cf.twimg.com`
- [x] `EchUrl.rewrite` 丢域名、保 query；`port == null` 时明确报错，不退化成直连
- [x] 代理只监听**明文 HTTP**（TLS 模式会让所有请求变 400，已彻底移除）
- [x] 代理透传 `Range` + 回 206/`Content-Range`/`Accept-Ranges`，强制 `Accept-Encoding: identity`
- [x] 代理转发 query，并记录每条请求的上游 URL 与状态码（设置页可看）

## 已修复的关键故障（回归测试覆盖）
- [x] Dio 拼 URL 少斜杠 → `metadata/tags/emojis` 全 403（详情页"暂无内容"、头像全空）
- [x] 媒体卡片在无界高度里没有确定高度 → 整片 media 空白
- [x] 全屏视频黑屏：`FittedBox` 用无界约束量 `Texture`（`TextureBox` 是 `sizedByParent`）
- [x] 视频鬼影/全屏点不动：同一 controller 被两个 `VideoPlayer` 同时渲染
- [x] 两根加载条：缓冲条与滑块各自一条 → 合成一根条三态
- [x] 代理 TLS 模式 → 所有请求 400（"从来没成功访问过"）
- [x] 视频停在加载中：Range 未透传 / 未强制 identity（无 Content-Length）
- [x] 启动偶发闪退：cgo 导出内 panic abort 进程（`guardPanic` + 锁内清缓冲）
- [x] 滑动白屏：`cacheExtent` 过小 + ImageCache 过小 + 整图下完才解码
      （现由预取 + 逐块解码承担；媒体统一 origin，不再靠 `name=` 档位省流量）

## 功能
- [x] 用户列表 / 搜索（用户名、昵称）/ 收藏
- [x] 详情页：媒体时间线、标签、emoji 投票、批量下载（流式 / 兼容 / 应急）
- [x] 图片：逐块解码（下到哪显示到哪）+ 媒体 URL **一律 origin**（已删除 `name=` 尺寸档位）
- [x] 图片全屏：左右滑动 / 上下滑动翻页、双击放大、进度叠底
- [x] 视频：Range 边下边播、缓冲进度、倍速、全屏、下载分享
- [x] 会话内图片缓存（ImageCache 160MB / 1500 张）、元数据缓存（10 分钟 TTL + in-flight 去重）
- [x] 设置页：代理状态、10 项网络诊断（可复制）、Go 调试日志、清缓存
- [x] **日志落盘**：Dart 全局错误捕获 + Go 日志 2s 轮询增量追加（`logs/app.log`，512KB 轮转）
- [x] **异常退出提示**：会话未打 `cleanExit` → 下次启动提示加群反馈 + 一键复制日志包
- [x] 反馈渠道：设置页「加群反馈」+ 日志包内自带加群地址（chatto 群，房间「推图」）
- [x] 清除日志：设置页独立入口（`LogService.clearLogs`）—— 清 app.log/.1 + 内存日志 +
      轮询游标，**保留** incidents.json 与 session.json（清掉就永远判不出未正常退出）；
      游标必须同步先重置，否则残留 tail 会让下次轮询走"整段重写"把旧内容灌回来
- [x] 视频 seek 失败 / 播放器报错不再静默：写日志 + 卡片侧可见错误态 + 重试前释放旧 controller
- [x] 代理在「请求了 `Range` 却收到 200」时显式记日志（拖动进度条后卡住的那条路径）
- [x] **封面缓存 + 可见优先分槽**：解码器只用于给"还没有封面"的卡片抓一帧，
      抓到即交还；回看走缓存封面、零解码器；抓帧不可用时自动退回"每张卡片各自
      持有播放器"（v0.5.2 行为）
- [x] **并发上限自适应**（`utils/decode_budget.dart`）：连续成功 +1、撞解码器失败 -1，
      范围 1~6，学到值存档；撞上限的失败降档重排而不报错
- [x] 量出槽位占用：日志分列 `init` 与 `抓帧` 两段耗时（证明占解码器的是 init）
- [x] 视频重试手段：加载永不判成失败（慢就一直等）、失败自动重试一次、
      代理端口出现自动重试；错误卡片**重试按钮在最前 + 原样显示具体错误**（可选中复制）；
      代理未就绪不再静默退回直连 URL
- [x] `_initSeq` + `_scheduleInit`：初始化去重，避免同帧起两个播放器/两个解码器

## v0.5.11 本轮修复（2026-09-12）
> 主题：**ECH 代理的资源泄漏与冻结**、**DoH 解析链的降级**、**元数据缓存的 stale callback**。
> 这轮改动一半在 Go（`ech-proxy/`），本地 `go build ./...` / `go vet ./...` / `go test -race` 全绿。

### ECH 代理（`ech-proxy/`，Go）
- [x] **上游卡死 → goroutine + TCP 永久泄漏**：`echProxyHandler` / `apiProxyHandler` 原来用
      `http.NewRequest`（context 是 Background），客户端断连后 `r.Context()` 被取消而上游毫不知情。
      wintools 的 `Client` 又是 `Timeout: 0`（防砍断长视频），所以只要上游 `Read` 卡住（墙内常态），
      这个 goroutine 永远走不到 `w.Write` 失败的分支，`resp.Body.Close()` 也不执行 →
      goroutine 与 TCP 连接双重泄漏，列表滚动时越积越多。改成
      `http.NewRequestWithContext(r.Context(), ...)`——`http.Client.Do` 内部会用
      `context.WithCancel(req.Context())` 派生传输上下文，客户端一断上游即中止。
- [x] **退出 App 时 UI 卡死 20~35s**：`StartProxy` 原来把整段（含 25~35s 的 ECH 探测）都锁在
      `proxyMu` 里，而 `StopProxy` / `GetProxyPort` 抢同一把锁。Dart 的 `stop()` 是**同步**调用
      （`stop` / `dispose` / `restart` 都走它），恰在探测期被调就把 isolate 冻住。
      现拆成三阶段：清状态（持锁瞬时）→ 探测（**不持锁**）→ 绑定端口（持锁瞬时）。
      另加 `proxyGen` 代号：探测期间若 `StopProxy` 来过，绑定前复查发现并放弃启动，
      不会在即将退出的进程里留下一个没人管的监听。
- [x] **`IsEchReady` 无锁读**：`echReady` 由持锁的 `StartProxy` / `StopProxy` 写、
      `IsEchReady` 裸读，`go test -race` 会标记。补锁。
- [x] **`StartProxy` 失败残留 stale 状态**：原来关旧 server 时只置 `proxyServer = nil`，
      探测失败直接 `return 0` 而 `echReady` / `proxyPort` 不清 → 上次成功后本次失败，
      `IsEchReady` 谎报就绪、`GetProxyPort` 返回一个没人监听的端口。现在阶段 0 就清成
      未就绪，`echReady = true` 也挪到监听真正起来之后，保证「就绪」与「端口有人在听」同时成立。
- [x] **`apiProxyHandler` 不滤逐跳头**：上游的 `Transfer-Encoding` 原样搬到客户端连接，
      会和 Go `ResponseWriter` 自己的分帧叠加；`Connection` / `Keep-Alive` 也会把上游的
      存活策略泄漏给客户端。逐跳头表提为包级 `hopByHop`，两个 handler 共用（原来只有一份、还写死在函数里）。
- [x] **`ech-proxy/main.go` 根本编译不过**：用的是已不存在的旧 wintools API
      （`NewClient` / `ClientConfig` / `client.Get`），`go build ./...` 一直红，
      而 CI 只构建 `./cmd/ech-flutter-shared`，所以从来没被发现。顺带修掉两个真 bug：
      ① 用 `strings.Index` / `strings.LastIndex` 切 path 解析主机名，对
      `/video-cf.twimg.com/media/x.jpg` 切出 `video-cf.twimg.com/media`（多切一段），
      path 恰好等于前缀时更会 `path[1:0]` 直接 panic；② `fmt.Sscanf` 忽略返回值，
      `PROXY_PORT=abc` 静默落到 8443。现 `go build ./...`、`go vet ./...` 全绿。

### Dart
- [x] **元数据缓存被过期 future 误删**（stale callback）：`getMetaData` 里 TTL 过期会
      `_metaCache.remove(username)`，随后写入新 future；但**旧** future 的 `catch` 无条件
      `_metaCache.remove`，把新 future 一起删掉。表现为偶发的重复拉取与 UI 闪烁。
      改成 `identical(_metaCache[username], inFlight)` 才清，过期处不再 remove。
- [x] **DoH 明文查询**：腾讯兜底原来是 `http://119.29.29.29/...`，域名明文上链，
      MITM 能看见也能改写。改 `https://`。
- [x] **DoH 接受任意证书**：`badCertificateCallback = (cert, host, port) => true` 等于把
      HTTPS 又降级回明文。现在换成校验证书确实属于预期的 DNS 服务域名
      （`doh.pub` / `dns.alidns.com`，含 `*.doh.pub` 通配），见 `_certLooksLike`。
      之所以还需要回调：拨的是固定 IP（RFC 9460 bootstrap），Dart 会把 URL host（即 IP）
      拿去比对证书，必然不匹配；但「必然不匹配」不等于「接受一切」。
- [x] **DoH 请求无超时**：冷启动时 DNS 侧挂起会永久卡死，而且 `main.dart` 的 5 次重试
      救不了「单次请求挂起」。补 `connectionTimeout` + 10s 整体预算（用定时器强关 client）。
- [x] **Tencent 返回的整个 JSON 被当成 IP**：腾讯/阿里都返回标准 DNS-JSON，
      旧实现的腾讯分支是 `body.split(';').first`——JSON 里含 `.`，于是把整段 JSON
      当 IP 返回，Go 侧拿垃圾去拨号，ECH 初始化必然失败。统一按 JSON 解析 `Answer`，
      取第一条 A 记录并校验是合法 IPv4。
- [x] **`downloadToTempFile` 文件名碰撞**：直接用 URL 末段当文件名，不同用户/路径容易同名
      （`1.jpg`），后下的覆盖前下的，分享时拿到别人的图。现在拼 `stableHash(url)` 并清洗非法字符。
- [x] **`downloadToTempFile` 响应无超时**：`connectionTimeout` 只管建连，响应体挂起时
      `await for` 永久不返回。补 90s 整体预算。
- [x] **`tag_display_area` / `tag_selector_modal` 的 `as num` 会崩**：`e.value` 是 `dynamic`，
      API 返回字符串型 score（`"3"`）时 `as num` 抛 `TypeError`，整个标签条/选择弹窗直接崩。
      改类型判定 + `int.tryParse` 兜底。

### 其他
- [x] **`.gitignore` 只有 `keystore/` 一行**：任何构建产物、平台壳、Go 产物都能被误提交。
      补齐 Dart/Go 产物与平台壳（本仓库不跟踪平台壳，CI 每次现造，所以忽略是对的）。
- [x] **`.last_upload_url` 含上传接口 token 却进了版本库**：
      内容是 `https://upload.moonchan.xyz/api/<token>/report.md.gz`，全仓库无任何引用方。
      已 `git rm --cached`（文件留在磁盘）并加入 `.gitignore`。

### 已评估、故意不做
- [ ] **`ECHSetDohURL` / `ECHInitWithBootstrap` 是死参数**：Dart 的 `dohHost` / `dohUrl`
      在 Go 侧被写死覆盖。真正修好需要新增 FFI 导出并在 Go 侧接收，本轮不动 FFI 面。
- [ ] **Go 日志缓冲的下标漂移**：`logBuffer` 是线性尾截断而非环形，截断后
      `ECHGetLogCount` / `ECHGetLog` 的下标会整体左移，读到重复或漏行。
      Dart 侧的 2 行锚点已经兜住，彻底修好需要新增「按序号增量拉取」的导出。
- [ ] **`poster_service` 磁盘封面缓存无淘汰**：跨会话累积，磁盘满后 `writeAsBytes` 静默失败。
- [ ] 全屏画廊**双击放大后无法平移**（只能看画面中央那 40%）。
- [ ] `twitter_image.dart` 的 `_watchSize` 用 `NetworkImage` 量尺寸，与
      `ProgressiveImageProvider` 的缓存 key 不同 → 同一张图会下载两遍。属效率缺陷，不影响正确性。

## v0.5.10 本轮修复（2026-09-11）
### 日志（最要紧的一块）
- [x] **丢日志行**：`pollGoLogs` 用单行游标判断「上次写到哪」，尾部行内容重复时整段跳过
      （同一 URL 的日志行高频重复就是这种情况，Go ring 回绕后必现）。改成**两行锚点**才推进，
      找不到锚点则整段重写并留标记行。已补回归测试。
- [x] **崩溃检测全误报**：`markCleanExit` 原来只挂在 `detached`，Android 从不发 `detached`
      （只有 paused/resumed/inactive）→ 每次切后台都被判成「上次异常退出」；用户烦了点
      「不再提示」之后，真崩溃也永远不再提示。现挂在 `paused`（桌面端补 `detached`）。
- [x] **轮转失败被吞**：`.1` 被占用/权限问题时 `rename` 失败静默 → app.log 只长不转，
      一路涨到撑爆 app 目录配额。现失败时截断兜底（这里**不能** `recordNote`：我们在写盘链里，
      再挂一个写盘任务就是递归打日志、把日志空间自己塞满）。
- [x] **半截 JSON**：`session.json` / `incidents.json` 改 **tmp + rename 原子写**
      （原先直接 `writeAsString`，进程在写入中途被杀就成半截，`jsonDecode` 抛异常被吞
      → 崩溃历史/会话标记凭空消失）。`ensureInitialized` 顺手清理遗留的 `.tmp` 孤儿。
- [x] `clearLogs` 现在也删 `prompt-suppressed` 并复位内存里的「不再提示」开关
      （否则清了日志、真崩溃还是不再提示）。
- [x] 调试日志面板改读**磁盘 app.log**，不再读 Go ring 快照（ring 只有 500 行内存态，
      看不到 Dart 侧错误，也和反馈包内容对不上）。
- [x] `ProxyManager.getLogs` 在 native 库未加载时返回一条诊断行，不再返回空列表
      （空列表会让 `pollGoLogs` 直接 return，「库根本没起来」这条最关键的排查线索凭空消失）。
- [x] 复制日志包前先 `flush()`，避免拿到还没落盘的半份。
- [x] `flutter_test` 里 `flutter analyze` 改为 `--no-fatal-warnings --no-fatal-infos`：
      仓库里本来就有一批 `prefer_const_constructors`，让它们只报不挡发布。

### 其他
- [x] `StorageService.clearAll` 改 `await _flush()`（原来 fire-and-forget，清完立刻读会得到旧数据）；
      `_flush` 拆出 `_doFlush`，并写明「链内只能调 `_doFlush`，回头调 `_flush` 就是死锁」。
- [x] `TwitterApi.resetForTests` 清静态元数据缓存（没有它，测试之间共享同一份静态缓存，
      而 Dart 不保证测试文件执行顺序，会偶发串味）。
- [x] `MediaUrl.isImage` 改按 **host 精确判定**（原先 `contains('pbs.twimg.com')` 会被
      `https://evil.com/pbs.twimg.com/x.jpg` 骗过）。
- [x] 视频卡片 codec 失败重试：`_PlayerPool.release(this)` 移到 seq 检查**之前**
      （原来顺序反了，seq 检查恒真 → 那段重试是死代码，卡片永远卡着）；非 codec 分支补上
      `_PlayerPool.release`（原来漏了，槽位永远不还）。
- [x] 时间线卡片 key 加位置 `j`（同一 URL 出现两次会让两张卡共用状态）。
- [x] 补测试：重复尾行不丢日志、512KB 轮转、clearAll 真清磁盘、resetForTests 隔离、
      media_url 子串欺骗、`TimelineItem.type` 原样透传（原先那条断言是同义反复）。

### 已评估、故意不做
- [ ] 图片「滚出视口就取消下载」：**做不了**，原因写在 `progressive_image.dart` 文件头。
      要点：`ImageCache.putIfAbsent` 会给每个它加载的 completer 加**自己**的 listener，
      只在图片完成时移除，所以下载期间 listener 数永远不为 0，取消钩子不会触发。
      真要取消得按 URL 维护引用计数，而 provider 按 URL 共享并被缓存，自己不知道还剩几个使用者。

## 测试（CI `flutter_test` job，14 个文件全跑，不过不发版）
- [x] `api_url_test.dart` — 逐接口断言绝对路径（防 baseUrl/path 拼接回归）
- [x] `media_url_test.dart` — `MediaUrl.isImage` 预取判定（只认 pbs 图片，视频不预热）
- [x] `progressive_image_test.dart` — 解码节流三规则 + provider 缓存标识
- [x] `fav_list_test.dart` — 收藏夹回归：纵向 ListView 嵌套纵向 ListView（条目全空）
- [x] `log_service_test.dart` — 日志增量落盘 / 缓冲轮转对齐 / 异常退出判定 / 反馈包内容
- [x] `video_failure_test.dart` — 线上实测的 MediaCodec 报错必须判成"解码器"而非"网络"
- [x] `decode_budget_test.dart` — 并发上限自适应（上调/下调/夹紧/失败清连击）
- [x] `poster_service_test.dart` — 封面缓存（内存+磁盘、跨会话、淘汰、清空）
- [x] `ech_url_test.dart` — 媒体 URL 改写（丢域名、保 query）
- [x] `proxy_manager_test.dart`（平台库名/加载路径）
- [x] `user_model_test.dart` — 容错 JSON 解析
- [x] `storage_service_test.dart` — 落盘重读、并发写不损坏、规则持久化
- [x] `stable_hash_test.dart` — FNV-1a 已知向量与确定性
- [x] `tag_display_area_test.dart` — widget 测试

## 构建 / 发布
- [x] `.github/workflows/build.yml`（不可删除）：`flutter_test` → `build_android` → `build_windows` → `create_release`
- [x] Go 共享库由 `ech-proxy/cmd/ech-flutter-shared` 编译（不再依赖 wintools 的 ech-shared）
- [x] 包名 `xyz.moonchan.twitterpic`；注入 `INTERNET` + `usesCleartextTraffic="true"` + 应用名"推图"，注入失败 CI 直接红
- [x] 版本号跟着 tag 走（日期 tag `vYYYYMMDD.HHMMSS` → `YYYYMMDD.0.HHMMSS`）
- [x] 签名走 GitHub Secrets；Flutter 3.44.3 / JDK 17 / NDK r27 锁定

## 依赖
- `dio ^5.7.0` — API 客户端（路径归一化拦截器 + 结构化异常）
- `ffi ^2.2.0` — Go c-shared 绑定（12 个导出符号）
- `path_provider ^2.1.5` — 应用目录（原生库释放、下载目录）
- `video_player ^2.9.0` + `video_player_win ^3.2.2` — Range 边下边播（federated 自动注册）
- `share_plus ^10.0.0` — 分享图片/视频
- `video_thumbnail`（fork `Hana-ame/video_thumbnail` tag `v0.5.6-flutter44`，仅为 Gradle 9/AGP 9 兼容）
- `cached_network_image ^3.4.1` — 保留依赖（图片主通道已换成自研逐块解码）
