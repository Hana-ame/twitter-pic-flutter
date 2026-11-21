# 待办优化记录（Optimization Backlog）

本文档记录已识别但**暂缓实施**的优化项，供后续迭代按优先级落地。

---

## 1. `StorageService` 结构化内存缓存与写盘防抖（已记录，暂不修改）

- **涉及位置**：`lib/services/storage_service.dart`（`_readMap`、`isFav`、`isBlocked`、`getBlockTags`、`getGayTags`、`blockTagHits`、`shouldHideUser`、`kGayTags`、`_write` / `_flush`）
- **现状与原因**：
  1. `_memory` 目前仅缓存原始 JSON 字符串。列表页每次执行 `_refreshVisible()` 过滤时，`shouldHideUser()` 会对每个用户依次调用 `isBlocked()` → `getBlockMap()`、`blockTagHits()` → `getBlockTags()`、`matchesGayMode()` → `kGayTags`（内部重复调用 `getGayTags()` 做正则清洗并生成 `Set`）。当列表包含 200+ 用户时，单次刷新会在 UI 线程同步触发 600+ 次 `jsonDecode`。
  2. 每次 `_write()` 会直接触发整份 `storage.json` 的序列化与临时文件原子重命名落盘，连续快速操作（如批量收藏/屏蔽或连续开关选项）时没有合并防抖。
- **建议改动方向（后续实施）**：
  - 在 `StorageService` 内部维护反序列化后的结构化只读/懒加载视图缓存（如 `Set<String>` 形式的 `favSet`、`blockSet`、`blockTagsSet`、`gayTagsSet`），在对应写方法及 `resetForTests()` / `clearAll()` 时同步失效或更新缓存。
  - 为常规 `_write()` 触发的 `_flush()` 引入短窗口防抖（例如 150–300ms），同时保持 `clearAll()`、`debugFlushPending()` 与应用切后台时的立即落盘语义不变，确保全部 24+ 处现有测试隔离契约继续通过。
- **预期收益**：
  - 列表过滤、搜索结果刷新、收藏/屏蔽状态读取降至 O(1) 内存查找，消除大列表下切换标签或开关 Gay 模式时的主线程掉帧。
  - 连续写入时显著减少无效的磁盘 I/O 与临时文件重命名次数。
