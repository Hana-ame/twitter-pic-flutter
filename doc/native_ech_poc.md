# Native ECH PoC — BoringSSL FFI 方案设计

> 分支：`feat/native-ech-poc`（不进 main；PoC 通过才谈合并）
> 前提事实：`dart:io` 至今没有公开 ECH API（BoringSSL 在引擎里有实现，但 Dart 层零暴露）。
> 所以"原生"只能自己带：把 BoringSSL 编译成 `.so/.dll` 随 App 分发，dart:ffi 直调。

## 与现状（Go c-shared）的对比

| 维度 | Go ech-shared（现行） | BoringSSL FFI（本 PoC） |
|---|---|---|
| 运行时 | 整个 Go runtime 打进 .so（体积大） | 纯 C 库，无运行时 |
| 流式 | 自定义 handle + ECHRead 轮询 | `SSL_read` 天然分块 ↔ Dart `Socket` Stream 泵 |
| 内存 | Go↔Dart 拷贝/序列化 | BIO 直接读写 Dart 缓冲 |
| 可控性 | 改协议行为要动 Go 仓库 | 全在 App 仓内，FFI 层自持 |
| 成本 | 已真机验证 ✅ | 握手/证书校验/CA 根全要自己做 ⚠️ |

## 架构

```
Dart                                          native (libboringssl.so / boringssl.dll)
────────────────────────────────────────      ────────────────────────────────────────
EchSocket (implements Stream<List<int>>)
   │
   ├─ Socket.connect(host, 443)               ← 明文 TCP，流式读写在 Dart 侧
   │    ↑ pump                                ← 双向搬运
   ├─ MemoryBIO r/w  ──(ffi)──►  SSL_set_bio / SSL_connect / SSL_read / SSL_write
   │
   └─ SSL_CTX_set1_ech_config_list(echBytes)  ← ECHConfigList 来自 DoH HTTPS(type 65) 记录
      SSL_set_tlsext_host_name(realHost)      // 内层 SNI = 真域名；
                                              // 外层 SNI 自动用 ECHConfig 的 public_name
```

要点：
- **外层 SNI 不用手填**——按 draft-ietf-tls-esni，客户端把真域名放进 inner CH，
  outer SNI 取 ECHConfig 的 public_name（如 cloudflare-ech.com）。BoringSSL 自动处理。
- **流式免费获得**：握手与数据都是"非阻塞引擎 + 外部泵"模型，`Socket` 的
  stream 事件驱动 BIO 水位，天然支持视频分块下载，不需要现在 ECHRead 那套轮询。
- **HTTP/1.1 手写**（GET、Range、Content-Length/chunked 解析）；先不做 h2。

## 已完成（纯 Dart，可单测）

- [x] `lib/native_ech/https_rr.dart` — DoH(JSON) 查 HTTPS RR + SVCB presentation 格式解析 +
      `ech=` 参数提取 → ECHConfigList 字节
- [x] `test/https_rr_test.dart` — 解析器 fixtures

## 待做（需要能联网的环境，按里程碑推进）

- [ ] **M1 绑定层落地**：`boringssl_bindings.dart` 中每个符号签名对照
      boringssl 头文件核实（当前为骨架，标注 TODO），CI 编译通过为准。
      注意点：证书校验用 `SSL_set1_host`/X509_VERIFY_PARAM 还是手工校验、
      CA 根来源（Android `/system/etc/security/cacerts`；Windows 无系统 bundle，
      建议 CI 打包 Mozilla CA 列表）。
- [ ] **M2 握手打通**：EchSocket 完成 TCP⇄BIO 泵 + ECH 握手，
      对 cloudflare-ech.com 前置验证 `SSL_ech_accepted() == 1`。
- [ ] **M3 HTTP/1.1 + 流式下载**：替换 `fetchToFileAsync` 一条路径，
      视频边下边写盘，内存恒定。
- [ ] **M4 决策门**：真机对比 Go 版（成功率/耗时/包体/ECH 接受率），
      数据说话再定去留。

## 风险表

| 风险 | 说明 | 缓解 |
|---|---|---|
| DoH 过滤 `ech=` 参数 | 国内公共 DNS 常剥掉 ech param | 多 DoH 端点轮询（moonchan → 1.1.1.1 → 自建）；解析器已容忍缺失 |
| retry_configs | 服务端下发 retry 配置需重试握手 | M2 实现一轮重试 |
| BoringSSL API 变动 | ECH 仍是 draft 演进 | 锁 commit 编译；绑定层集中一个文件 |
| 包体 | BoringSSL 静态链接 ~2-3MB/平台 | shared 库 strip 后评估，Go runtime 本身也 ~几 MB |
| Windows CA | 无统一系统 bundle 目录 | 打包 Mozilla roots + 定期更新 |

## 决策门（M4 未达标就弃分支）

ECH 接受率 ≥ Go 版 −2%、P95 首字节 ≤ Go 版 ×1.2、崩溃率无回归 —— 三条同时满足才考虑合并。
