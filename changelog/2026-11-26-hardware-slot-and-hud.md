# 2026-11-26 硬解槽位跟随正在播放的播放器、HUD 可重复唤起、默认档位与文案收敛

## 变更摘要

1. **硬解槽位 = 正在播放的那一张（`VideoDecoderPool.claimPlayback` / `request(urgent:)`）**
   - 现场：第一个视频硬解正常，打开第二个变成软解 —— 第一个播放器还活着，硬解实例被它占着；Media3 在 `prepare()` 阶段抢不到硬件 AVC 实例就**静默回退软解**。
   - `request(urgent: true)`（用户点封面/点重试）不再"挤掉一张"而是**清场**（`_evictAllExcept`）：哪怕槽位没满，也收走所有其它持槽者。非 urgent 的自动抓封面路径语义不变（只挤"看不见且没在播"的，防抖动）。
   - 新增 `claimPlayback`：开始播放时把槽位记到自己名下并让其它持槽者退场；暂停时**不**抢（避免无谓重连）。`markPlaying` 删除。
   - 新增 `waitForHandoff()` + `kDecoderHandoffSettle = 260ms`：`dispose()` → native `release()` 是异步的，接手方必须等硬解真正落地再 `initialize()`，否则同样回退软解。
   - 让位时卡片刻下 `_resumePosition`，重新播放时 `seekTo` 回原位 —— 解码器必须真的释放，controller 只能重建，但用户不该被迫从头看。
   - 于是：播 A（硬解）→ 播 B（清场，B 硬解）→ 回播 A（再清场，A 回到原位置且仍是硬解）。

2. **播放器 HUD 可重复唤起（卡片侧 + 全屏页）**
   - 根因：`VideoPlayer` 渲染的是 `Texture`，`RenderTexture` 不参与命中测试（`hitTestSelf` 为 false）。原代码把手势 `GestureDetector`（默认 `deferToChild`）套在 `VideoPlayer` 外面，点击等于点在空气上 —— HUD 第一次自动收起后再也点不出来。全屏页还多点了一条：点上下黑边同样无反应。
   - 修法：手势层独立 `Positioned.fill` + `behavior: HitTestBehavior.opaque`（全屏页盖住整屏含黑边）；控制栏/顶栏整块也 `opaque` 并 `onTap: _showControlsTemporarily`，点栏内空白处不再收起 HUD，顺带重置 3 秒计时。

3. **默认档位唯一：`standard`（auto，硬解优先）**
   - 首次启动、`clearAll`、未知值、以及 v0.7.x 旧键（`software_decode` / `single_decoder` / `software_platform_view` / `local_file`）**全部回退 `standard`**。旧键语义与现在的 `prefer_software` 并不等价，且实测软解掉帧、部分视频放不出，继续映射成软解档等于让升级上来的用户永久停在最差档位。
   - 新增 `VideoCompatMode.standard.isDefault` 唯一性断言。

4. **设置页说明压到一行**
   - `VideoCompatModeProps.description` 全部改写为 ≤ 20 字、无换行；`ListTile.subtitle` 加 `maxLines: 1 + ellipsis`，窄屏不折行。
   - 段落式说明（斜切/绿纹的长解释、外部播放器两行长文案、Gay 模式、清除日志）同步压成一行。

5. **诊断增强**：`VideoCompatChannel.getLastDecoderSummary()` 现在直接标出「硬解 / 软解」（`isSoftwareDecoderName`，仅影响日志），反馈包里"第二个视频到底走的哪路"一眼可辨。

6. **单测**
   - `test/video_decoder_pool_test.dart`：清场语义（含"有空位也清场"）、`claimPlayback` 让位/幂等/`release` 清标记、`waitForHandoff` 的等待与零开销分支。
   - `test/video_compat_mode_test.dart`：旧键一律回退 `standard`、默认档唯一性、说明 ≤ 20 字且单行、软解名识别。
