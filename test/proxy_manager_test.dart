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

    test('native 库未加载时 getLogs 返回诊断行，不抛异常也不返回空列表', () {
      final manager = ProxyManager();
      // 不能抛：直接解引用 _logCount! 会报 "Null check operator used on a
      // null value"，把真正的 "Native library not found" 掩盖掉。
      expect(() => manager.getLogs(), returnsNormally);

      // 也不能返回空列表：空列表会让 pollGoLogs 直接 return、什么都不落盘，
      // 「库根本没起来」这条排查「代理连不上」最关键的线索就凭空消失了。
      final logs = manager.getLogs();
      expect(logs, isNotEmpty);
      expect(logs.single, contains('native library not loaded'));
    });
  });
}
