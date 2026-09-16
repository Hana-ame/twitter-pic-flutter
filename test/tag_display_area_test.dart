import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:twitter_pic_flutter/widgets/tag_display_area.dart';

Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('TagDisplayArea 高亮标记', () {
    testWidgets('命中高亮集的标签显示星标', (tester) async {
      await tester.pumpWidget(wrap(TagDisplayArea(
        highlights: {'二次元'},
        tags: {'二次元': 1, '自拍': -1},
      )));

      expect(find.byIcon(Icons.star), findsOneWidget);
      expect(find.text('二次元'), findsOneWidget);
      expect(find.text('自拍'), findsOneWidget);
    });

    testWidgets('未命中高亮集则无星标', (tester) async {
      await tester.pumpWidget(wrap(TagDisplayArea(
        highlights: {},
        tags: {'自拍': -1},
      )));

      expect(find.byIcon(Icons.star), findsNothing);
    });

    testWidgets('空标签渲染为空', (tester) async {
      await tester.pumpWidget(wrap(const TagDisplayArea(tags: {})));
      expect(find.text('二次元'), findsNothing);
    });
  });

  group('TagDisplayArea Gay 模式过滤', () {
    testWidgets('默认/关闭 Gay 模式时过滤男同/男性/露屌', (tester) async {
      await tester.pumpWidget(wrap(const TagDisplayArea(
        tags: {'二次元': 1, '男同': 1, '男性': 1, '露屌': 1, '自拍': -1},
        gayMode: false,
      )));

      expect(find.text('二次元'), findsOneWidget);
      expect(find.text('自拍'), findsOneWidget);
      expect(find.text('男同'), findsNothing);
      expect(find.text('男性'), findsNothing);
      expect(find.text('露屌'), findsNothing);
    });

    testWidgets('开启 Gay 模式时正常显示男同/男性/露屌', (tester) async {
      await tester.pumpWidget(wrap(const TagDisplayArea(
        tags: {'二次元': 1, '男同': 1, '男性': 1, '露屌': 1},
        gayMode: true,
      )));

      expect(find.text('二次元'), findsOneWidget);
      expect(find.text('男同'), findsOneWidget);
      expect(find.text('男性'), findsOneWidget);
      expect(find.text('露屌'), findsOneWidget);
    });
  });
}
