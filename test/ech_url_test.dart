// test/ech_url_test.dart
// EchUrl 单元测试：验证 URL 重写逻辑

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/utils/ech_url.dart';

void main() {
  group('EchUrl.rewrite', () {
    test('rewrites pbs.twimg.com URL', () {
      final input = 'https://pbs.twimg.com/media/photo.jpg?token=abc';
      final result = EchUrl.rewrite(input, 12345);
      expect(result, equals('http://127.0.0.1:12345/pbs.twimg.com/media/photo.jpg?token=abc'));
    });

    test('rewrites video-cf.twimg.com URL', () {
      final input = 'https://video-cf.twimg.com/ttv/video.mp4';
      final result = EchUrl.rewrite(input, 12345);
      expect(result, equals('http://127.0.0.1:12345/video-cf.twimg.com/ttv/video.mp4'));
    });

    test('rewrites abs.twimg.com URL', () {
      final input = 'https://abs.twimg.com/profile_images/avatar.jpg';
      final result = EchUrl.rewrite(input, 12345);
      expect(result, equals('http://127.0.0.1:12345/abs.twimg.com/profile_images/avatar.jpg'));
    });

    test('rewrites URL with query string', () {
      final input = 'https://pbs.twimg.com/media/photo.jpg?name=value&x=1';
      final result = EchUrl.rewrite(input, 12345);
      expect(result, equals('http://127.0.0.1:12345/pbs.twimg.com/media/photo.jpg?name=value&x=1'));
    });

    test('rewrites URL with custom host', () {
      final input = 'https://pbs.twimg.com/media/photo.jpg';
      final result = EchUrl.rewrite(input, 12345, host: '192.168.1.100');
      expect(result, equals('http://192.168.1.100:12345/pbs.twimg.com/media/photo.jpg'));
    });
  });

  group('EchUrl.isProxyUrl', () {
    test('returns true for localhost URL', () {
      expect(EchUrl.isProxyUrl('http://127.0.0.1:12345/pbs.twimg.com/photo.jpg'), isTrue);
    });

    test('returns true for localhost URL', () {
      expect(EchUrl.isProxyUrl('http://localhost:12345/pbs.twimg.com/photo.jpg'), isTrue);
    });

    test('returns false for regular URL', () {
      expect(EchUrl.isProxyUrl('https://pbs.twimg.com/photo.jpg'), isFalse);
    });

    test('returns false for https localhost URL', () {
      expect(EchUrl.isProxyUrl('https://127.0.0.1:12345/photo.jpg'), isFalse);
    });
  });

  group('EchUrl.extractTarget', () {
    test('extracts target from proxy URL', () {
      final proxyUrl = 'http://127.0.0.1:12345/pbs.twimg.com/media/photo.jpg?token=abc';
      final target = EchUrl.extractTarget(proxyUrl);
      expect(target, equals('https://pbs.twimg.com/media/photo.jpg?token=abc'));
    });

    test('extracts target without query', () {
      final proxyUrl = 'http://127.0.0.1:12345/pbs.twimg.com/media/photo.jpg';
      final target = EchUrl.extractTarget(proxyUrl);
      expect(target, equals('https://pbs.twimg.com/media/photo.jpg'));
    });
  });

  group('EchUrl.rewriteToUri', () {
    test('returns Uri object', () {
      final input = 'https://pbs.twimg.com/media/photo.jpg';
      final result = EchUrl.rewriteToUri(input, 12345);
      expect(result, isA<Uri>());
      expect(result.host, equals('127.0.0.1'));
      expect(result.port, equals(12345));
    });
  });
}
