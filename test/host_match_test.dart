import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/utils/host_match.dart';

void main() {
  group('cnMatchesHost（DoH 兜底的证书名校验）', () {
    test('等号匹配：CN 与预期主机名完全相同', () {
      expect(cnMatchesHost('doh.pub', 'doh.pub'), isTrue);
    });

    test('通配前缀匹配一层子域：阿里 DNS 的真实证书形态', () {
      // openssl s_client -connect 223.5.5.5:443 实测：CN = *.alidns.com
      expect(cnMatchesHost('*.alidns.com', 'dns.alidns.com'), isTrue);
    });

    test('通配**不**穿透多层子域：通配只覆盖恰好一层', () {
      expect(cnMatchesHost('*.alidns.com', 'sub.dns.alidns.com'), isFalse);
    });

    test('通配后需要至少一层子域：裸后缀不匹配', () {
      expect(cnMatchesHost('*.alidns.com', 'alidns.com'), isFalse);
    });

    test('历史 bug 回归：不再要求 `*.` + 完整 expected', () {
      // 早期实现只接受 `*.dns.alidns.com`，把阿里的 `*.alidns.com` 判成失败，
      // 等于白配一整级兜底。这条断言锁住那个修复。
      expect(cnMatchesHost('*.dns.alidns.com', 'dns.alidns.com'), isTrue);
    });

    test('通配位置不对或整体不同就不匹配', () {
      expect(cnMatchesHost('alidns.com.*', 'dns.alidns.com'), isFalse);
      expect(cnMatchesHost('*.alidns.com', 'dns.alidns.cn'), isFalse);
      expect(cnMatchesHost('example.org', 'doh.pub'), isFalse);
    });

    test('CN 里没有点号的通配直接判失败', () {
      expect(cnMatchesHost('*', 'dns.alidns.com'), isFalse);
      expect(cnMatchesHost('*.', 'dns.alidns.com'), isFalse);
    });

    test('大小写敏感：证书名按原样比对，不做归一化', () {
      // RFC 9525 说主机名比较应大小写不敏感，但这里只做保守的严格比对：
      // 匹配失败的最坏后果是这条兜底静默失效、落到下一条入口，
      // 而不是放过一张错证书。所以宁可偏严。
      expect(cnMatchesHost('DNS.Alidns.com', 'dns.alidns.com'), isFalse);
    });

    test('空值与无意义输入', () {
      expect(cnMatchesHost('', 'dns.alidns.com'), isFalse);
      expect(cnMatchesHost('*.alidns.com', ''), isFalse);
    });
  });
}
