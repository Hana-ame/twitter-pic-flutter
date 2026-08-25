import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/native_ech/ech_http_client.dart';

void main() {
  group('HttpResponseHead.tryParse', () {
    test('完整头解析：状态行/大小写归一/头长', () {
      const raw = 'HTTP/1.1 200 OK\r\n'
          'Content-Type: video/mp4\r\n'
          'CONTENT-LENGTH: 1024\r\n'
          '\r\nBODY...';
      final h = HttpResponseHead.tryParse(ascii.encode(raw))!;
      expect(h.statusCode, 200);
      expect(h.reasonPhrase, 'OK');
      expect(h.headers['content-type'], 'video/mp4');
      expect(h.headers['content-length'], '1024');
      expect(h.contentLength, 1024);
      expect(h.headerByteLength, raw.indexOf('BODY'));
      expect(h.isChunked, isFalse);
    });

    test('缓冲不足 → null（等下一个网络包）', () {
      expect(HttpResponseHead.tryParse(ascii.encode('HTTP/1.1 200 OK\r\n')),
          isNull);
    });

    test('chunked 标记', () {
      final h = HttpResponseHead.tryParse(
          ascii.encode('HTTP/1.1 206 Partial Content\r\n'
              'Transfer-Encoding: chunked\r\n\r\n'))!;
      expect(h.statusCode, 206);
      expect(h.isChunked, isTrue);
    });

    test('畸形状态行 → null', () {
      expect(HttpResponseHead.tryParse(ascii.encode('NOT HTTP\r\n\r\n')),
          isNull);
    });
  });

  group('ChunkedDecoder', () {
    Uint8List decodeAll(List<List<int>> pushes) {
      final out = BytesBuilder2();
      final d = ChunkedDecoder(out.add2);
      for (final p in pushes) {
        d.push(p);
      }
      return out.take();
    }

    test('单包完整 chunk', () {
      // "hello" = 5 字节
      expect(decodeAll([ascii.encode('5\r\nhello\r\n0\r\n\r\n')]),
          utf8.encode('hello'));
    });

    test('跨包拆分：size 行、数据、CRLF 各在不同 push', () {
      final got = decodeAll([
        ascii.encode('5\r\nhe'),
        ascii.encode('llo'),
        ascii.encode('\r\n3\r\nabc'),
        ascii.encode('\r\n'),
        ascii.encode('0\r\n\r\n'),
      ]);
      expect(got, utf8.encode('helloabc'));
    });

    test('带扩展的 size 行 "1f;ext=..."', () {
      final got = decodeAll([ascii.encode('b;foo=bar\r\n0123456789a\r\n0\r\n\r\n')]);
      expect(got.length, 11);
    });

    test('坏 size 行抛 FormatException', () {
      final out = BytesBuilder2();
      final d = ChunkedDecoder(out.add2);
      expect(() => d.push(ascii.encode('zz\r\n')), throwsFormatException);
    });

    test('done 后再 push 被忽略', () {
      final got = decodeAll([
        ascii.encode('0\r\n\r\n'),
        ascii.encode('5\r\nhello\r\n'), // 应被忽略
      ]);
      expect(got, isEmpty);
    });
  });

  group('buildRequest', () {
    test('请求行/Host/额外头/空行结尾', () {
      final req = ascii.decode(EchHttpClient.buildRequest(
        'video-cf.twimg.com',
        '/video/a.mp4',
        extraHeaders: {'Range': 'bytes=0-1023'},
      ));
      expect(req.startsWith('GET /video/a.mp4 HTTP/1.1\r\n'), isTrue);
      expect(req.contains('Host: video-cf.twimg.com\r\n'), isTrue);
      expect(req.contains('Range: bytes=0-1023\r\n'), isTrue);
      expect(req.endsWith('\r\n\r\n'), isTrue);
    });
  });
}

/// 测试用收集器。
class BytesBuilder2 {
  final _out = BytesBuilder();

  void add2(List<int> chunk) => _out.add(chunk);

  Uint8List take() => _out.toBytes();
}
