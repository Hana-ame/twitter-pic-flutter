// poster_service_test.dart
// 视频封面缓存的回归测试。
//
// 纯 Dart + 临时目录（PathProviderPlatform 都不用 mock，走 debugUseDirectory），
// 所以能在 CI 的 flutter test 里真跑。抓帧本身（RepaintBoundary.toImage）需要
// 真机/渲染，不在单测范围。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/services/poster_service.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('poster_service_test');
    PosterService.resetForTests();
    await PosterService.debugUseDirectory(tmp);
  });

  tearDown(() async {
    PosterService.resetForTests();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Uint8List bytesOf(List<int> v) => Uint8List.fromList(v);

  test('put 之后内存与磁盘都能读到', () async {
    const url = 'https://video.twimg.com/a.mp4?tag=29';
    final data = bytesOf([1, 2, 3, 4, 5]);

    await PosterService.put(url, data);

    expect(PosterService.memory(url), equals(data));
    expect(await PosterService.load(url), equals(data));

    final f = File('${PosterService.directoryPath}/${PosterService.keyFor(url)}.jpg');
    expect(await f.exists(), isTrue);
    expect(await f.readAsBytes(), equals(data));
  });

  test('清掉内存后仍能从磁盘读回（跨会话可缓存）', () async {
    const url = 'https://video.twimg.com/b.mp4';
    await PosterService.put(url, bytesOf([9, 8, 7]));

    // 模拟重启：清内存态（磁盘保留）
    PosterService.resetForTests();
    await PosterService.debugUseDirectory(tmp);
    expect(PosterService.memory(url), isNull);

    expect(await PosterService.load(url), equals(bytesOf([9, 8, 7])));
    // 回填内存，第二次不再碰磁盘
    expect(PosterService.memory(url), isNotNull);
  });

  test('没缓存过的 URL 返回 null，不抛异常', () async {
    expect(await PosterService.load('https://video.twimg.com/none.mp4'), isNull);
    expect(PosterService.memory(''), isNull);
  });

  test('空字节不写缓存（否则卡片会显示一张空图）', () async {
    await PosterService.put('https://video.twimg.com/empty.mp4', bytesOf([]));
    expect(await PosterService.load('https://video.twimg.com/empty.mp4'), isNull);
  });

  test('key 稳定且不同 URL 不撞', () {
    const a = 'https://video.twimg.com/a.mp4?tag=29';
    const b = 'https://video.twimg.com/b.mp4?tag=29';
    expect(PosterService.keyFor(a), PosterService.keyFor(a));
    expect(PosterService.keyFor(a), isNot(PosterService.keyFor(b)));
    // FNV-1a 64 位 → 16 位十六进制
    expect(PosterService.keyFor(a).length, 16);
  });

  test('内存缓存超上限时淘汰最早的，但磁盘仍在', () async {
    // 用一个很小的上限来验证淘汰，而不是真的塞满 60 条
    final urls = <String>[
      for (var i = 0; i < PosterService.maxMemoryEntries + 3; i++)
        'https://video.twimg.com/v$i.mp4',
    ];
    for (final u in urls) {
      await PosterService.put(u, bytesOf([1, 2, 3]));
    }

    // 最早的两条被挤出内存
    expect(PosterService.memory(urls[0]), isNull);
    expect(PosterService.memory(urls[1]), isNull);
    // 但磁盘还有 → load 仍能拿到
    expect(await PosterService.load(urls[0]), isNotNull);
    // 最近的一条在内存里
    expect(PosterService.memory(urls.last), isNotNull);
  });

  test('clearAll 清掉磁盘与内存', () async {
    const url = 'https://video.twimg.com/c.mp4';
    await PosterService.put(url, bytesOf([5, 5, 5]));

    await PosterService.clearAll();

    expect(PosterService.memory(url), isNull);
    expect(await PosterService.load(url), isNull);
  });
}
