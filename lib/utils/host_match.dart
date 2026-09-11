// host_match.dart
// 证书 CN 与预期主机名的匹配。
//
// 从 doh_resolver.dart 抽出来单独测：这是 DoH 兜底能不能通的关键一环。
// 实测阿里 DNS 的证书 CN 是 `*.alidns.com`，覆盖 `dns.alidns.com`；
// 早期实现只接受 `*.` + 完整 expected（即 `*.dns.alidns.com`）那种写法，
// 于是把阿里这条兜底**永远判成失败**，等于白配一级。见 doh_resolver.dart
// 文件头的第 4 条修复记录。

/// CN 值与预期主机名是否匹配：支持等号匹配和 RFC 2253 的通配前缀。
///
/// 通配只能出现在最左侧标签，且只覆盖**恰好一层**子域：
///   `*.alidns.com` 匹配 `dns.alidns.com`，
///   但不匹配 `sub.dns.alidns.com`（那需要 `*.dns.alidns.com`）。
///
/// [cn] 是证书里的 CN 值，[host] 是调用方期望的服务域名。
bool cnMatchesHost(String cn, String host) {
  if (cn == host) return true;
  final dot = cn.indexOf('.');
  if (dot < 0) return false;
  if (cn.substring(0, dot) != '*') return false;
  final suffix = cn.substring(dot); // 形如 ".alidns.com"
  if (!host.endsWith(suffix)) return false;
  final label = host.substring(0, host.length - suffix.length);
  return label.isNotEmpty && !label.contains('.');
}
