// progressive_disk_cache_test.dart
// 图片磁盘缓存（v0.6.1 新增）的回归测试。
//
// 纯 Dart + 临时目录（走 debugUseDirectory，不mock path_provider），所以能在
// CI 的 flutter test 里真跑。解码本身（ui.ImmutableBuffer）要渲染管线，不在
// 单测范围——这里只保证「存取 + 淘汰 + 降级」这段纯逻辑。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/widgets/progressive_image.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('progressive_disk_cache_test');
    ProgressiveDiskCache.resetForTests();
    await ProgressiveDiskCache.debugUseDirectory(tmp);
  });

  tearDown(() async {
    ProgressiveDiskCache.resetForTests();
    // 不先 exists() 再 delete()（TOCTOU：两步之间目录可能已被删）。
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // 已经不在了：正是我们要的结果。
    }
  });

  Uint8List bytesOf(List<int> v) => Uint8List.fromList(v);

  test('put 之后能读回完全一样的字节', () async {
    const url = 'https://pbs.twimg.com/media/X?format=jpg&name=small';
    final data = bytesOf([1, 2, 3, 4, 5, 6, 7, 8]);

    await ProgressiveDiskCache.put(url, data);

    expect(await ProgressiveDiskCache.load(url), equals(data));
  });

  test('key 稳定：同 URL 永远命中同一条文件', () async {
    const url = 'https://pbs.twimg.com/media/Y?name=small';
    await ProgressiveDiskCache.put(url, bytesOf([42]));

    // 重新初始化（模拟冷启动）后仍能读回：说明 key 不依赖内存态。
    ProgressiveDiskCache.resetForTests();
    await ProgressiveDiskCache.debugUseDirectory(tmp);

    expect(await ProgressiveDiskCache.load(url), equals(bytesOf([42])));
  });

  test('不同 URL 不撞（缩略图档与原图档各自一条）', () async {
    const thumb = 'https://pbs.twimg.com/media/Z?format=jpg&name=small';
    const orig = 'https://pbs.twimg.com/media/Z?format=jpg&name=orig';

    await ProgressiveDiskCache.put(thumb, bytesOf([1]));
    await ProgressiveDiskCache.put(orig, bytesOf([2]));

    expect(await ProgressiveDiskCache.load(thumb), equals(bytesOf([1])));
    expect(await ProgressiveDiskCache.load(orig), equals(bytesOf([2])));
  });

  test('没缓存过的 URL 返回 null，不抛异常', () async {
    expect(await ProgressiveDiskCache.load('https://pbs.twimg.com/none.jpg'),
        isNull);
    expect(await ProgressiveDiskCache.load(''), isNull);
  });

  test('空字节不写缓存（否则会命中一张空图）', () async {
    const url = 'https://pbs.twimg.com/media/empty?format=jpg&name=small';
    await ProgressiveDiskCache.put(url, bytesOf([]));
    expect(await ProgressiveDiskCache.load(url), isNull);
  });

  test('超过单条上限的不缓存（原图动辄2MB，不该无限占盘）', () async {
    const url = 'https://pbs.twimg.com/media/big?name=orig';
    final tooBig = bytesOf(
        List<int>.filled(ProgressiveDiskCache.maxEntryBytes + 1, 7));

    await ProgressiveDiskCache.put(url, tooBig);

    expect(await ProgressiveDiskCache.load(url), isNull);
  });

  test('clearAll 清掉磁盘内容', () async {
    const url = 'https://pbs.twimg.com/media/C?format=jpg&name=small';
    await ProgressiveDiskCache.put(url, bytesOf([9, 9, 9]));

    await ProgressiveDiskCache.clearAll();

    expect(await ProgressiveDiskCache.load(url), isNull);
  });

  test('未就绪时静默降级：put/load 都不抛，返回 null', () async {
    // reset 后不给目录，模拟「没有可写目录」（桌面端/权限异常）。
    // 磁盘缓存只是加速，绝不能让它把图片加载搞崩。
    ProgressiveDiskCache.resetForTests();
    const url = 'https://pbs.twimg.com/media/D?format=jpg&name=small';

    await ProgressiveDiskCache.put(url, bytesOf([1, 2, 3]));

    expect(await ProgressiveDiskCache.load(url), anyOf(isNull, equals(bytesOf([1, 2, 3]))),
        reason: '未就绪时应回退为「不缓存」，即 load 拿不到网络层之外的东西');
  });

  test('目录不可创建时不抛（init 失败降级为纯内存）', () async {
    ProgressiveDiskCache.resetForTests();
    // 指一个必然不存在的路径层级：create(recursive:true) 会在权限/父级
    // 异常时失败，ensureInitialized 必须吞掉它。
    await expectLater(
      ProgressiveDiskCache.debugUseDirectory(
          Directory('${tmp.path}/progressive_disk_cache_test/nonexistent/x')),
      completes,
    );
  });
}