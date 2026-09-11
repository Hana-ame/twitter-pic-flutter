# 项目总检清单

> 最后核对：v0.5.1（2026-09-11，含其后一个未发布的 origin 重构）。细节见 [README](README.md)、
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
