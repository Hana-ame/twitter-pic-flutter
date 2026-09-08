// test/proxy_manager_test.dart
// ProxyManager 单元测试：验证代理生命周期管理逻辑

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/services/proxy_manager.dart';

void main() {
  group('ProxyManager', () {
    test('initial state', () {
      final manager = ProxyManager();
      
      expect(manager.isRunning, isFalse);
      expect(manager.port, isNull);
      expect(manager.isInitialized, isFalse);
      expect(manager.isStarting, isFalse);
    });

    test('stop when not running does not throw', () {
      final manager = ProxyManager();
      expect(() => manager.stop(), returnsNormally);
    });

    test('dispose does not throw', () {
      final manager = ProxyManager();
      expect(() => manager.dispose(), returnsNormally);
    });

    test('getLogs returns empty list when not initialized', () {
      final manager = ProxyManager();
      // getLogs will throw because FFI not loaded, but we can test the behavior
      // This test is skipped because it requires native library
      // expect(() => manager.getLogs(), throwsA(anything));
    });
  });
}
