// doh_resolver.dart
// DoH 域名解析：把 moonchan.xyz 解析成可直接拨号的目标 IP。
//
// 分工：
//   - DoH 域名 (kDohHost) → 硬编码，服务的固有配置
//   - DoH 目标 IP        → 运行时解析，禁止硬编码
//
// SetDoHConfig(host, bootstrapIP) 的语义是「直拨 bootstrapIP 连 https://<host>/doh，
// 绕过 DNS」，所以这里必须解析出 moonchan.xyz 的真实 IP（Cloudflare），
// 传入 127.0.0.1 之类的占位值会让 DoH 请求打到本机 443 端口，必然超时。
//
// 解析链：系统 DNS → 腾讯 DNS → 阿里 DNS。
// 国内网络下系统 DNS 可能被污染/不可用，所以保留两级 HTTP DNS 兜底。
// 兜底入口必须是固定 IP（RFC 9460 DoH bootstrap），见 _kTencentDnsIp 注释。
//
// 26.09 修复的两件事：
//   1. 腾讯兜底原来走 http:// —— 域名明文上链，MITM 能看见也能改写。改 https。
//   2. badCertificateCallback 原来无脑返回 true（接受任意证书）—— 那等于把
//      DoH 又降级回明文。现在改成校验证书确实属于预期的 DNS 服务域名，
//      见 _certLooksLike。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// DoH 域名。与 Go 侧 `cloudflare_ech.SetDoHConfig(kDohHost, ip)` 对齐。
const kDohHost = 'moonchan.xyz';

/// HTTP DNS 兜底入口。
///
/// 注意：这两个 IP 是 DNS 服务器本身，不是 [kDohHost] 的解析结果。
/// 按 RFC 9460 的 DoH bootstrap 模式，兜底入口必须是固定 IP —— 兜底只在
/// 系统 DNS 失败时触发，届时域名形式的入口（dns.alidns.com / doh.pub）也
/// 无法解析，兜底会失效。故此处必须固定，与 8.8.8.8 / 9.9.9.9 同类。
const _kTencentDnsIp = '119.29.29.29';
const _kAliDnsIp = '223.5.5.5';

/// 各兜底入口在 TLS 里实际出示的证书所属服务域名。
/// 拨的是固定 IP，但证书签给的是域名 —— Dart 的 HttpClient 会把 URL host
///（也就是那个 IP）拿去比对证书，必然不匹配，所以才需要下面的回调。
const _kTencentCertHost = 'doh.pub';
const _kAliCertHost = 'dns.alidns.com';

/// 单次兜底请求的总预算。原来完全没有超时：DNS 侧挂起时冷启动永久卡死，
/// 而且 main.dart 的 5 次重试救不了"单次请求挂起"。
const _kPerResolverTimeout = Duration(seconds: 10);

/// 鲁棒解析域名，依次尝试系统 DNS 和两级 HTTP DNS，全部失败时抛异常。
Future<String> resolveDomainRobustly(String domain) async {
  try {
    final result = await InternetAddress.lookup(domain);
    if (result.isNotEmpty) return result.first.address;
  } catch (e) {
    print('System DNS failed: $e');
  }

  for (final entry in [
    _DohEntry(url: 'https://$_kTencentDnsIp/d?dn=$domain', certHost: _kTencentCertHost),
    _DohEntry(url: 'https://$_kAliDnsIp/resolve?name=$domain&type=1', certHost: _kAliCertHost),
  ]) {
    try {
      final ip = await _resolveViaDoH(entry.url, entry.certHost);
      if (ip != null) return ip;
    } catch (e) {
      print('HTTP DNS failed: ${entry.url} -> $e');
    }
  }

  throw Exception('failed to resolve $domain');
}

class _DohEntry {
  const _DohEntry({required this.url, required this.certHost});
  final String url;
  final String certHost;
}

/// 走一次 HTTP DNS，成功返回 IPv4 字符串，失败/拿不到 A 记录返回 null。
Future<String?> _resolveViaDoH(String url, String expectedCertHost) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 5);
  // 见文件头注释第 2 条。
  client.badCertificateCallback =
      (cert, host, port) => _certLooksLike(cert, expectedCertHost);

  // HttpClient 没有请求级超时，只有 connectionTimeout。这里用定时器强关
  // client：force close 会让在途请求以错误结束，await 抛错后走外层 catch。
  final deadline = Timer(_kPerResolverTimeout, () {
    client.close(force: true);
  });
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('Accept', 'application/dns-json');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200 || body.isEmpty) return null;
    return _firstIPv4FromDnsJson(body);
  } finally {
    deadline.cancel();
    client.close(force: true);
  }
}

/// 解析标准 DNS-JSON，返回第一条 A 记录的 IP。
///
/// 腾讯和阿里返回的都是同一套格式：
/// `{"Status":0,"Answer":[{"type":1,"data":"1.2.3.4"}, ...], ...}`
///
/// 旧实现腾讯分支做的是 `body.split(';').first` —— 返回体是 JSON，split 出来
/// 整串含 '.'，于是**把整个 JSON 当 IP 返回**。Go 侧拿到一段垃圾去拨号，
/// ECH 初始化必然失败。统一按 JSON 解析。
String? _firstIPv4FromDnsJson(String body) {
  Object? parsed;
  try {
    parsed = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (parsed is! Map) return null;

  final answer = parsed['Answer'];
  if (answer is! List) return null;
  for (final ans in answer) {
    if (ans is! Map) continue;
    // 有的实现 type 是数字 1，有的是字符串 "1"。
    if (ans['type'] == 1 || ans['type'] == '1') {
      final ip = ans['data'].toString().trim();
      if (_isIPv4(ip)) return ip;
    }
  }
  return null;
}

bool _isIPv4(String s) =>
    s.contains('.') && !s.contains(':') && InternetAddress.tryParse(s) != null;

/// 校验证书确实属于预期的 DNS 服务域名。
///
/// 之所以不能直接依赖 Dart 的默认校验：拨的是固定 IP，TLS 里 URL host 是 IP，
/// 和证书的 CN/SAN 对不上，默认校验必然失败。但"必然失败"不等于"接受一切" ——
/// 这里换成"证书名字必须匹配预期服务域名"，保住名字校验这一层。
///
/// 注意 Dart 的 X509Certificate 不暴露 SAN，只能看 subject 里的 CN。
/// `*.doh.pub` 这类通配符也要接受。
bool _certLooksLike(X509Certificate cert, String expected) {
  final subject = cert.subject.principalName;
  final m = RegExp(r'(?:^|,)\s*CN=([^,]+)').firstMatch(subject);
  final cn = (m?.group(1) ?? cert.commonName).trim();
  return cn == expected || cn == '*.$expected';
}
