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

/// 鲁棒解析域名，依次尝试系统 DNS 和两级 HTTP DNS，全部失败时抛异常。
Future<String> resolveDomainRobustly(String domain) async {
  try {
    final result = await InternetAddress.lookup(domain);
    if (result.isNotEmpty) return result.first.address;
  } catch (e) {
    print('System DNS failed: $e');
  }

  final dohUrls = [
    'http://$_kTencentDnsIp/d?dn=$domain',
    'https://$_kAliDnsIp/resolve?name=$domain&type=1',
  ];

  for (final url in dohUrls) {
    final client = HttpClient();
    try {
      client.badCertificateCallback = (cert, host, port) => true;
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set('Accept', 'application/dns-json');
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode == 200 && body.isNotEmpty) {
        if (url.contains(_kTencentDnsIp)) {
          final ips = body.split(';');
          if (ips.isNotEmpty && ips.first.contains('.')) return ips.first;
        }
        if (url.contains(_kAliDnsIp)) {
          final json = jsonDecode(body);
          if (json['Status'] == 0 && json['Answer'] != null) {
            for (final ans in json['Answer']) {
              if (ans['type'] == 1) return ans['data'].toString();
            }
          }
        }
      }
    } catch (e) {
      print('HTTP DNS failed: $url -> $e');
    } finally {
      client.close();
    }
  }

  throw Exception('failed to resolve $domain');
}
