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
// 解析链：系统 DNS → 腾讯 DNS（固定 IP）→ 阿里 DNS（固定 IP）→ 腾讯 DNS（域名形式）。
// 国内网络下系统 DNS 可能被污染/不可用，所以保留两级 HTTP DNS 兜底。
// 兜底入口必须是固定 IP（RFC 9460 DoH bootstrap），见 _kTencentDnsIp 注释。
//
// 26.09 修复的四件事：
//   1. 腾讯兜底原来走 http:// —— 域名明文上链，MITM 能看见也能改写。改 https。
//   2. badCertificateCallback 原来无脑返回 true（接受任意证书）—— 那等于把
//      DoH 又降级回明文。现在改成校验证书确实属于预期的 DNS 服务域名，
//      见 _certLooksLike。
//   3. 腾讯分支原来 body.split(';') 取 first —— 返回体是 JSON，整串含 '.'，
//      于是把整个 JSON 当 IP 返回，Go 侧拿垃圾去拨号必然失败。统一按 JSON 解析。
//   4. 通配 CN 匹配写死成 `*.$expected` —— 实测阿里证书 CN 是 `*.alidns.com`
//      （覆盖 dns.alidns.com），我们却要求 `*.dns.alidns.com`，于是阿里那条
//      兜底**永远失败**。改成按"恰好一层子域"的通配语义匹配，见 _wildcardMatches。
//      顺带发现阿里证书的 SAN 里直接含 `IP Address:223.5.5.5`，Dart 默认校验
//      就能过，回调是多余的，已删。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'host_match.dart';

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

/// 腾讯兜底入口在 TLS 里实际出示的证书所属服务域名。
///
/// 拨的是固定 IP，但证书签给的是域名 —— Dart 的 HttpClient 会把 URL host
///（也就是那个 IP）拿去比对证书，必然不匹配，所以才需要下面的回调。
///
/// 阿里那条入口**不需要**这个：实测（`openssl s_client -connect 223.5.5.5:443`）
/// 它的证书 SAN 里直接含 `IP Address:223.5.5.5`，Dart 默认校验器拿 URL host
/// 的 IP 去比 SAN 的 iPAddress 条目就能通过，加回调纯属多余。
/// 实测 CN 是 `*.alidns.com`（通配），若误配成 `dns.alidns.com` 会匹配失败
/// —— 别照着域名硬填 certHost，先确认证书的 SAN。
///
/// 腾讯节点从可观测的环境不可达，证书未确认，故保留回调走 CN 校验。
const _kTencentCertHost = 'doh.pub';

/// 单次兜底请求的总预算。原来完全没有超时：DNS 侧挂起时冷启动永久卡死，
/// 而且 main.dart 的 5 次重试救不了"单次请求挂起"。
const _kPerResolverTimeout = Duration(seconds: 10);

/// 一条 DNS 入口。[certHost] 为 null 表示走 Dart 默认的严格证书校验。
class _DohEntry {
  const _DohEntry({required this.url, this.certHost});
  final String url;
  final String? certHost;
}

/// 鲁棒解析域名，依次尝试系统 DNS 和多条 HTTP DNS，全部失败时抛异常。
Future<String> resolveDomainRobustly(String domain) async {
  try {
    final result = await InternetAddress.lookup(domain);
    if (result.isNotEmpty) return result.first.address;
  } catch (e) {
    print('System DNS failed: $e');
  }

  final entries = [
    // 前两条走固定 IP bootstrap：系统 DNS 挂掉时域名形式的入口也解不出来。
    _DohEntry(url: 'https://$_kTencentDnsIp/d?dn=$domain', certHost: _kTencentCertHost),
    _DohEntry(url: 'https://$_kAliDnsIp/resolve?name=$domain&type=1'),
    // 第三条走域名形式 + 严格校验：对冲腾讯那条 _certLooksLike 匹配失败的可能
    // （腾讯节点从可观测的环境不可达，证书未知；现代证书普遍只把主机名放 SAN、
    // 不写 CN，见 _certLooksLike 注释），也让"系统 DNS 可用但 moonchan.xyz
    // 被污染"的场景多一条路。系统 DNS 真挂了时这条会自己解不出来，静默跳过。
    _DohEntry(url: 'https://doh.pub/d?dn=$domain'),
  ];

  for (final entry in entries) {
    try {
      final ip = await _resolveViaDoH(entry.url, entry.certHost);
      if (ip != null) return ip;
    } catch (e) {
      print('HTTP DNS failed: ${entry.url} -> $e');
    }
  }

  throw Exception('failed to resolve $domain');
}

/// 走一次 HTTP DNS，成功返回 IPv4 字符串，失败/拿不到 A 记录返回 null。
Future<String?> _resolveViaDoH(String url, String? expectedCertHost) async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 5);
  // 见文件头注释第 2 条。expectedCertHost 为 null 时保持默认严格校验。
  if (expectedCertHost != null) {
    client.badCertificateCallback =
        (cert, host, port) => _certLooksLike(cert, expectedCertHost);
  }

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
/// 之所以还需要回调而不是直接依赖默认校验：拨的是固定 IP，TLS 里 URL host
/// 是 IP，和证书上的域名对不上，默认校验必然失败。但"必然失败"不等于"接受一切"
/// —— 这里换成"证书名字必须匹配预期服务域名"，保住名字校验这一层。
///
/// **已知局限（重要）**：现代证书按 RFC 9525 把主机名放在 SAN 扩展里，CN 已被
/// 标注为 MUST NOT 用于服务标识。而 [X509Certificate] 的 API 只有
/// `subject` / `issuer` 两个 String（`commonName`、`fingerprint`、SAN 访问器
/// 这些都不存在，别猜），Dart 标准库**读不到 SAN**。所以下面只能比对 CN：
///   - 目标证书写了 CN → 能正确校验
///   - 目标证书是 SAN-only → 匹配失败，这条兜底静默失效，落到下一条域名形式入口
/// 想彻底修好要么自己解析 [X509Certificate.der] 里的 SAN 扩展（ASN.1，无本地
/// 编译器不可冒险），要么改用 SPKI 钉扎（需要预先收集公钥指纹，且轮转即失效）。
/// 两条都超出了当前约束，这里如实记录而不是假装解决了。
///
/// [X509Certificate.subject] 是 DistinguishedName 串，格式在不同系统上有差异：
/// 可能是 RFC 2253 的 `CN=doh.pub,O=...`，也可能是 `O=..., CN = doh.pub`
///（属性顺序反转、等号带空格）。所以下面按"任意位置出现 CN=值"来取，
/// 值取到逗号或换行前为止。
bool _certLooksLike(X509Certificate cert, String expected) {
  final subject = cert.subject;
  final m = RegExp(r'CN\s*=\s*([^,\r\n]+)', caseSensitive: false)
      .firstMatch(subject);
  final raw = m?.group(1);
  final cn = raw == null ? '' : raw.trim().replaceAll('"', '');
  if (cn.isEmpty) return false;
  return cnMatchesHost(cn, expected);
}
