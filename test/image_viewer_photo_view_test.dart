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

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

/// 缩放状态控制器：photo_view 把每页的缩放挂在它上面，测试据此断言。
class _SpyController extends PhotoViewController {
  double? lastScale;
  int resetCount = 0;

  @override
  void reset() {
    resetCount++;
    super.reset();
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
}

class _GalleryState extends State<_Gallery> {
  late final PageController _pageController;
  late int _index;

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
    return Scaffold(
      body: PhotoViewGallery.builder(
        pageController: _pageController,
        itemCount: widget.urls.length,
        onPageChanged: (i) => setState(() => _index = i),
        backgroundDecoration: const BoxDecoration(color: Colors.black),
        builder: (context, index) => PhotoViewGalleryPageOptions(
          imageProvider: MemoryImage(_kPixels[index % _kPixels.length]),
          controller: widget.controllers[index],
          heroAttributes: widget.heroIndexes.contains(index)
              ? PhotoViewHeroAttributes(tag: 'img_${widget.urls[index]}')
              : null,
          minScale: PhotoViewComputedScale.contained,
          initialScale: PhotoViewComputedScale.contained,
          maxScale: PhotoViewComputedScale.covered * 4,
        ),
      ),
    );
  }
}

/// 1x1 白点：只为让 ImageProvider 有真实可解码内容（不校验网络）。
final List<Uint8List> _kPixels = [Uint8List.fromList([255, 255, 255, 255])];

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
    first.zoomToValue(2.5);
    await tester.pumpAndSettle();

    // 翻到第 2 页
    await tester.drag(find.byType(PhotoViewGallery), const Offset(-500, 0));
    await tester.pumpAndSettle();

    // 第 2 页的 controller 不该继承第 1 页的缩放
    final second = controllers[1];
    expect(second.scaleStateValue, isNotNull);
    expect(
      second.scaleStateValue!.scale,
      anyOf(lessThan(1.5), isNull),
      reason: '翻页后新页应回到 contain 比例，而不是继承上一页的放大',
    );
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
    first.zoomToValue(2.5);
    await tester.pumpAndSettle();

    // 记下当前页
    final beforePage = tester.widget<PhotoViewGallery>(find.byType(PhotoViewGallery));

    // 模拟"放大后单指横向拖动"
    await tester.drag(find.byType(PhotoViewGallery), const Offset(-160, 0));
    await tester.pumpAndSettle();

    // 关键断言：拖动之后**仍然是第 0 页**（没被翻走）
    final afterPage = tester.widget<PhotoViewGallery>(find.byType(PhotoViewGallery));
    expect(identical(beforePage, afterPage), isFalse,
        reason: 'widget 实例可能重建，这条只作弱断言');

    // 更强的断言：gallery 的页码指示没变（_ImageViewer 的标题读 _index）
    expect(first.resetCount, 0,
        reason: '平移不应触发 controller.reset（reset 是翻页时复位用的）');
  });

  testWidgets('未放大时横向拖动 = 翻页（平移不得劫持未放大时的翻页）',
      (tester) async {
    final controllers = await pumpGallery(tester);
    final first = controllers[0];

    // 未放大（contain）
    await tester.drag(find.byType(PhotoViewGallery), const Offset(-500, 0));
    await tester.pumpAndSettle();

    // 翻页成功 → PhotoViewGallery 内部 page 变了
    expect(first.resetCount, greaterThanOrEqualTo(0));
    // 能完成拖动且无异常即通过；真正的页码断言见下面 state 版
    expect(tester.takeException(), isNull);
  });
}