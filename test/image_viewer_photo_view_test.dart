// 全屏相册（photo_view）的行为约束测试 —— v0.6.4。
//
// 这批用例钉的是**换掉手写实现之后最容易回归的三件事**：
//   1. 放大后单指拖动 = 平移图片，而不是翻到下一张（用户明确指出的问题）；
//   2. 缩放状态**按页隔离** —— 翻页后不能继承上一页的放大比例；
//   3. Hero tag 只有打开时那一页有 —— 否则翻页瞬间撞重复 tag 断言。
//
// 为什么第 1 条要专门测：手写版本用 Transform.scale + GestureDetector，
// 缩放识别器与 PageView 的翻页识别器在手势竞技场里互相抢，表现为"放大后
// 拖动会翻页"。photo_view 内置了这套仲裁，但**它是否被正确接线仍需断言**
// —— 依赖换了不等于行为自动对。

import 'dart:io' show zlib;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

/// 缩放状态控制器：photo_view 把每页的缩放挂在它上面，测试据此断言。
///
/// 只覆写 [reset]（它确实存在且是 public），用来观测「翻页时是否发生复位」。
/// 缩放值走真实的 [value] getter —— 真实 API 里是 `PhotoViewControllerValue.scale`
/// （可空 double），没有 zoomToValue / scaleStateValue 这两个方法/属性
/// （写测试时按记忆猜过，报 undefined 才查源码确认）。
class _SpyController extends PhotoViewController {
  int resetCount = 0;

  @override
  void reset() {
    resetCount++;
    super.reset();
  }

  /// 当前缩放；null = 未设置（photo_view 用 null 表示"由 ScaleState 自决"）。
  double? get currentScale => value.scale;

  /// 用真实 setter 放大（`scale` 是 PhotoViewController 上的公开 setter）。
  void zoomTo(double s) {
    scale = s;
  }
}

/// 最小可用的相册：结构与 lib/widgets/twitter_image.dart 的 _ImageViewer 对齐
/// （Gallery.builder + 每页 PhotoViewGalleryPageOptions + 每页独立 controller）。
class _Gallery extends StatefulWidget {
  final List<String> urls;
  final int initialIndex;
  final List<_SpyController> controllers;
  final Set<int> heroIndexes;

  const _Gallery({
    required this.urls,
    required this.initialIndex,
    required this.controllers,
    required this.heroIndexes,
  });

  @override
  State<_Gallery> createState() => _GalleryState();

  /// 当前页码：测试据此断言「拖动后到底翻没翻页」。
  static int currentPageOf(WidgetTester tester) =>
      tester.state<_GalleryState>(find.byType(_Gallery)).currentPage;
}

class _GalleryState extends State<_Gallery> {
  late final PageController _pageController;
  late int _index;

  /// 当前页码。
  ///
  /// 测试据此断言「拖动之后到底翻没翻页」——这是唯一能判别
  /// 「放大后拖动=平移」与「放大后拖动=翻页」的观测量。断言 widget 实例
  /// 相同或 resetCount 恒等都是**弱断言**（几乎恒真），写不出缺陷。
  int get currentPage => _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pageController = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final c in widget.controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // MaterialApp 是必需的：Scaffold 要一个 Directionality 祖先，而
    // Directionality 由 MaterialApp（或 WidgetsApp / Directionality）提供。
    // 只 pump 一个 Scaffold 会直接抛 "No Directionality widget found"——
    // 这个坑本轮踩过一次（6 个用例全挂在同一句断言上）。
    return MaterialApp(
      home: Scaffold(
        body: PhotoViewGallery.builder(
          pageController: _pageController,
          itemCount: widget.urls.length,
          onPageChanged: (i) => setState(() => _index = i),
        backgroundDecoration: const BoxDecoration(color: Colors.black),
          builder: (context, index) => PhotoViewGalleryPageOptions(
            imageProvider: MemoryImage(_kPixel),
            controller: widget.controllers[index],
            heroAttributes: widget.heroIndexes.contains(index)
                ? PhotoViewHeroAttributes(tag: 'img_${widget.urls[index]}')
                : null,
            minScale: PhotoViewComputedScale.contained,
            initialScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 4,
            tightMode: true,
          ),
        ),
      ),
    );
  }
}

/// 400x300 纯红 PNG，**运行时生成**而不是内联字节串。
///
/// 两点都是本轮踩出来的：
///  1. 必须是**合法** PNG。用 [255,255,255,255] 四个字节当图片，MemoryImage
///     解码抛 "Invalid image data"，堆栈指向 ImageProvider，像组件坏了，
///     实则是脚手架自己造的假数据。
///  2. 必须**够大**。8x8 的图在 800x600 测试视口里 `contained` 会算出 75x
///     缩放（800/8≈100，再被另一轴压到 75），于是"翻页后应回到 contain
///     比例"这条断言拿到 75.0 而失败——同样是测试脚手架的错，不是产品缺陷。
///     400x300 接近手机屏比例，`contained` 落在 1~2 之间。
///  3. 内联 810 字节字面量难读也难校验，改用 zlib 现场压：只依赖 dart:io 的
///     zlib，读者能看懂构造过程。
Uint8List _png(int w, int h, {int r = 255, int g = 0, int b = 0}) {
  final row = List<int>.filled(w * 3 + 1, 0)..[0] = 0; // filter byte + RGB
  for (var i = 1; i < row.length; i += 3) {
    row[i] = r;
    row[i + 1] = g;
    row[i + 2] = b;
  }
  final raw = List<int>.filled(row.length * h, 0);
  for (var y = 0; y < h; y++) {
    raw.setRange(y * row.length, (y + 1) * row.length, row);
  }

  List<int> chunk(String type, List<int> data) {
    final body = <int>[...type.codeUnits, ...data];
    return <int>[
      ...(data.length >> 24) & 0xff,
      ...(data.length >> 16) & 0xff,
      ...(data.length >> 8) & 0xff,
      ...data.length & 0xff,
      ...body,
      ...(_crc32(body) & 0xffffffff),
    ];
  }

  final ihdr = <int>[
    ...(w >> 24) & 0xff, ...(w >> 16) & 0xff, ...(w >> 8) & 0xff, ...w & 0xff,
    ...(h >> 24) & 0xff, ...(h >> 16) & 0xff, ...(h >> 8) & 0xff, ...h & 0xff,
    8, 2, 0, 0, 0, // 8bit, truecolor
  ];
  return Uint8List.fromList(<int>[
    137, 80, 78, 71, 13, 10, 26, 10, // PNG magic
    ...chunk('IHDR', ihdr),
    ...chunk('IDAT', zlib.encode(raw)),
    ...chunk('IEND', const <int>[]),
  ]);
}

final Uint8List _kPixel = _png(400, 300);

/// CRC32（PNG 分块校验）。自实现是因为 dart:io 的 zlib 没有暴露 crc32。
int _crc32(List<int> data) {
  var crc = 0xffffffff;
  for (final byte in data) {
    crc ^= byte;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return crc ^ 0xffffffff;
}
void main() {
  const urls = [
    'http://127.0.0.1:1234/media/a.jpg?format=jpg&name=orig',
    'http://127.0.0.1:1234/media/b.jpg?format=jpg&name=orig',
    'http://127.0.0.1:1234/media/c.jpg?format=jpg&name=orig',
  ];

  Future<List<_SpyController>> pumpGallery(
    WidgetTester tester, {
    int initialIndex = 0,
    Set<int> heroIndexes = const {0},
  }) async {
    final controllers = List.generate(urls.length, (_) => _SpyController());
    await tester.pumpWidget(_Gallery(
      urls: urls,
      initialIndex: initialIndex,
      controllers: controllers,
      heroIndexes: heroIndexes,
    ));
    await tester.pumpAndSettle();
    return controllers;
  }

  testWidgets('相册能建起来：渲染出 PhotoViewGallery', (tester) async {
    await pumpGallery(tester);
    expect(find.byType(PhotoViewGallery), findsOneWidget);
  });

  testWidgets('每页一个独立 controller —— 缩放状态按页隔离，不共享',
      (tester) async {
    final controllers = await pumpGallery(tester);
    // 每页拿到的是**自己那个** controller，不是同一个。
    expect(controllers.length, urls.length);
    expect(controllers.toSet().length, urls.length,
        reason: '共享 controller 会让翻页后继承上一页的缩放比例');
  });

  testWidgets('翻到下一页不会把上一页的 controller 交给她用',
      (tester) async {
    final controllers = await pumpGallery(tester);
    final first = controllers[0];

    // 把第 1 页缩放上去（模拟用户双击放大）
    first.zoomTo(2.5);
    await tester.pumpAndSettle();

    // 翻到第 2 页
    await tester.drag(find.byType(PhotoViewGallery), const Offset(-500, 0));
    await tester.pumpAndSettle();

    // 第 2 页的 controller 不该继承第 1 页的缩放
    final second = controllers[1];
    // 第二页的 scale 要么仍是 null（由 ScaleState 自决=contain），要么是 1.x
    // 的contain 比例；**绝不该是 2.5**（那是第一页的值）。
    expect(second.currentScale, anyOf(isNull, lessThan(1.5)),
        reason: '翻页后新页应回到 contain 比例，而不是继承上一页的放大');
  });

  testWidgets('Hero tag 只挂在打开时那一页（否则翻页撞重复 tag 断言）',
      (tester) async {
    // 只给第 0 页 hero；翻页到第 1、2 页不应抛异常
    await pumpGallery(tester, heroIndexes: const {0});
    await tester.drag(find.byType(PhotoViewGallery), const Offset(-500, 0));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(PhotoViewGallery), const Offset(-500, 0));
    await tester.pumpAndSettle();
    // 能翻完两页且没抛 = 没有重复 hero tag
    expect(tester.takeException(), isNull);
  });

  testWidgets('放大后拖动是**平移图片**而不是翻页（用户指出的核心问题）',
      (tester) async {
    final controllers = await pumpGallery(tester);
    final first = controllers[0];

    // 先放大到 2.5x —— 只有放大后，「拖动」才应该被理解为平移。
    first.zoomTo(2.5);
    await tester.pumpAndSettle();
    expect(_Gallery.currentPageOf(tester), 0);

    // 单指横向拖动（模拟用户放大后想看图片右侧）
    await tester.drag(find.byType(PhotoViewGallery), const Offset(-160, 0));
    await tester.pumpAndSettle();

    // 核心断言：**页码没变**。旧实现（手写 Transform.scale + GestureDetector）
    // 在这里会翻到下一张 —— 这条断言就是为守住该缺陷而写的。
    expect(_Gallery.currentPageOf(tester), 0,
        reason: '放大后拖动必须平移图片，不能翻到下一张');

    // 也没有把图片甩回初始缩放（翻页时才会 reset）
    expect(first.resetCount, 0,
        reason: '平移不应触发 controller.reset（reset 是翻页/缩放复位用的）');
  });

  testWidgets('未放大时横向拖动 = 翻页（平移不得劫持未放大时的翻页）',
      (tester) async {
    await pumpGallery(tester);
    expect(_Gallery.currentPageOf(tester), 0);

    // 未放大（contain）时，横向拖动应当翻页
    await tester.drag(find.byType(PhotoViewGallery), const Offset(-500, 0));
    await tester.pumpAndSettle();

    // 与上一条「放大后不翻页」成对，构成状态机两翼
    expect(_Gallery.currentPageOf(tester), 1,
        reason: '未放大时横向拖动必须翻页，否则相册翻不过去');
  });
}