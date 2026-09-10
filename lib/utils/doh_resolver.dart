// doh_resolver.dart
// DoH 域名解析：把 moonchan.xyz 解析成可直接拨号的目标 IP。
//
// SetDoHConfig(host, bootstrapIP) 的语义是「直拨 bootstrapIP 连 https://<host>/doh，
// 绕过 DNS」，所以这里必须解析出 moonchan.xyz 的真实 IP（Cloudflare），
// 传入 127.0.0.1 之类的占位值会让 DoH 请求打到本机 443 端口，必然超时。
//
// 解析链：系统 DNS → 腾讯 DNS (119.29.29.29) → 阿里 DNS (223.5.5.5)。
// 国内网络下系统 DNS 可能被污染/不可用，所以保留两级 HTTP DNS 兜底。

import 'dart:convert';
import 'dart:io';

/// DoH 域名。与 Go 侧 `cloudflare_ech.SetDoHConfig(kDohHost, ip)` 对齐。
const kDohHost = 'moonchan.xyz';

/// 鲁棒解析域名，依次尝试系统 DNS 和两级 HTTP DNS，全部失败时抛异常。
Future<String> resolveDomainRobustly(String domain) async {
  try {
    final result = await InternetAddress.lookup(domain);
    if (result.isNotEmpty) return result.first.address;
  } catch (e) {
    print('System DNS failed: $e');
  }

  final dohUrls = [
    'http://119.29.29.29/d?dn=$domain',
    'https://223.5.5.5/resolve?name=$domain&type=1',
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
        if (url.contains('119.29.29.29')) {
          final ips = body.split(';');
          if (ips.isNotEmpty && ips.first.contains('.')) return ips.first;
        }
        if (url.contains('223.5.5.5')) {
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
