import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/native_ech/https_rr.dart';

void main() {
  group('parseSvcParams（RFC 9460 presentation 格式）', () {
    test('基础：alpn 带引号、ech 无引号', () {
      final p = parseSvcParams(
          r'1 . alpn="h2,h3" ipv6hint=2606:4700::1 ech=QUJDREVGRw==');
      expect(p['alpn'], 'h2,h3');
      expect(p['ipv6hint'], '2606:4700::1');
      expect(p['ech'], 'QUJDREVGRw==');
    });

    test('ech 参数带引号', () {
      final p = parseSvcParams(r'1 . alpn="h3" ech="QUJDRA=="');
      expect(p['ech'], 'QUJDRA==');
    });

    test('值内转义 \; 与 \\, 不截断', () {
      final p = parseSvcParams(r'1 . key=a\;b\,c');
      expect(p['key'], 'a;b,c');
    });

    test('无 SvcParams（仅 priority+target）返回空映射', () {
      expect(parseSvcParams('2 .').isEmpty, isTrue);
    });

    test('大小写归一化', () {
      final p = parseSvcParams('1 . ECH=QUJD');
      expect(p['ech'], 'QUJD');
    });
  });

  group('extractEchFromHttpsRr', () {
    test('ech 存在 → 返回 base64 解码字节', () {
      // base64("HELLO-ECH") = "SEVMTE8tRUNI"
      final bytes = extractEchFromHttpsRr(
          r'1 cloudflare-ech.com alpn="h2,h3" ech=SEVMTE8tRUNI')!;
      expect(utf8.decode(bytes), 'HELLO-ECH');
    });

    test('ech 缺失 → null（被 DNS 过滤的场景）', () {
      expect(extractEchFromHttpsRr(r'1 . alpn="h2,h3"'), isNull);
    });

    test('ech 为空值 → null', () {
      expect(extractEchFromHttpsRr('1 . ech='), isNull);
    });

    test('非法 base64 → null 不抛异常', () {
      expect(extractEchFromHttpsRr('1 . ech=!!!not-base64!!!'), isNull);
    });
  });

  group('HttpsRrEchFetcher.extractEchFromAnswer', () {
    test('从 DoH JSON 提取 type65 的 ech', () {
      const body = '''
{
  "Status": 0,
  "Answer": [
    {"name":"x.com","type":1,"TTL":300,"data":"104.16.0.1"},
    {"name":"x.com","type":65,"TTL":300,
     "data":"1 . alpn=\\"h2,h3\\" ech=SEVMTE8tRUNI"}
  ]
}''';
      final bytes = HttpsRrEchFetcher.extractEchFromAnswer(body)!;
      expect(utf8.decode(bytes), 'HELLO-ECH');
    });

    test('Answer 里没有 ech → null；坏 JSON → null', () {
      expect(HttpsRrEchFetcher.extractEchFromAnswer(
          '{"Answer":[{"type":65,"data":"1 . alpn=h2"}]}'), isNull);
      expect(HttpsRrEchFetcher.extractEchFromAnswer('not-json'), isNull);
    });

    test('真实 Cloudflare 样例结构（字段顺序/多余字段容忍）', () {
      const body = '''
{"Status":0,"TC":false,"RD":true,"RA":true,"AD":false,"CD":false,
 "Question":[{"name":"example.com","type":65}],
 "Answer":[
   {"name":"example.com","type":65,"TTL":1800,
    "data":"1 . alpn=\\"h3,h2\\" no-default-alpn ipv6hint=\\"2606:4700::6810:1\\" ech=\\"aGVsbG8=\\""}
 ]}''';
      expect(utf8.decode(HttpsRrEchFetcher.extractEchFromAnswer(body)!), 'hello');
    });
  });
}
